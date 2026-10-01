import CoreData
import Foundation

extension AIInsights {
    /// Loads the analyses behind a meal response chart: stored ones as they are, the rest from Trio's Core Data.
    enum MealResponseLoader {
        static let maxMeals = 40
        /// Trio purges glucose and pump history after 90 days, so older meals without a stored analysis are skipped.
        static let recomputeLookback: TimeInterval = 90 * 24 * 60 * 60

        /// Saved meals with one of `mealIDs` or `foodResultIDs`, newest `maxMeals`, oldest first.
        static func analyses(
            mealIDs: Set<UUID>,
            foodResultIDs: Set<UUID>,
            now: Date = Date()
        ) async -> [MealEventAnalysis] {
            let recorder = MealEventRecorder.shared
            recorder.refresh()
            await recorder.waitUntilIdle()
            let events = await recorder.allEvents()
                .filter { event in
                    guard event.carbLink.status != .deleted, event.mealTime <= now else { return false }
                    if mealIDs.contains(event.meal.mealID) { return true }
                    guard let resultID = event.meal.foodResultID else { return false }
                    return foodResultIDs.contains(resultID)
                }
                .sorted { $0.mealTime > $1.mealTime }
                .prefix(maxMeals)

            var analyses: [MealEventAnalysis] = []
            var missing: [MealEvent] = []
            for event in events {
                if let cached = MealOutcomeEngine.cached(event) {
                    analyses.append(cached)
                } else if now.timeIntervalSince(event.mealTime) < recomputeLookback {
                    missing.append(event)
                }
            }

            if !missing.isEmpty {
                let inputs = await CoreDataMealOutcomeDataSource().inputs(for: missing)
                let computed = missing.compactMap { event -> MealEventAnalysis? in
                    guard let eventInputs = inputs[event.id] else { return nil }
                    return MealOutcomeEngine.analyze(event, inputs: eventInputs, now: now)
                }
                // A curve without any glucose is not kept, so it is tried again once glucose is there.
                recorder.storeAnalyses(computed.filter { analysis in analysis.curve.values.contains { $0 != nil } })
                analyses += computed
            }
            return analyses.sorted { $0.event.mealTime < $1.event.mealTime }
        }
    }
}

/// Reads Trio's Core Data rows around saved meals for `AIInsights.MealOutcomeEngine`.
struct CoreDataMealOutcomeDataSource {
    private struct Span: Sendable {
        var id: UUID
        var start: Date
        var end: Date
    }

    /// Inputs per meal event id; empty when the store cannot be read.
    func inputs(for events: [AIInsights.MealEvent]) async -> [UUID: AIInsights.MealOutcomeInputs] {
        let spans = events.map { event in
            Span(
                id: event.id,
                start: event.mealTime.addingTimeInterval(-AIInsights.MealOutcomeEngine.inputsBefore),
                end: event.mealTime.addingTimeInterval(AIInsights.MealOutcomeEngine.inputsAfter)
            )
        }
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "FoodFinderMealOutcomes"
        do {
            return try await context.perform {
                var result: [UUID: AIInsights.MealOutcomeInputs] = [:]
                for span in spans {
                    result[span.id] = try Self.inputs(from: span.start, to: span.end, in: context)
                }
                return result
            }
        } catch {
            debug(.coreData, "FoodFinder meal outcomes: reading inputs failed: \(error)")
            return [:]
        }
    }

    private static func inputs(
        from start: Date,
        to end: Date,
        in context: NSManagedObjectContext
    ) throws -> AIInsights.MealOutcomeInputs {
        let runs = try loopRuns(from: start, to: end, in: context)
        return AIInsights.MealOutcomeInputs(
            readings: try glucose(from: start, to: end, in: context),
            boluses: try boluses(from: start, to: end, in: context),
            tempBasals: try tempBasals(from: start, to: end, in: context),
            scheduledBasals: runs.scheduledBasals,
            carbs: try carbs(from: start, to: end, in: context),
            iob: runs.iob
        )
    }

    private static func glucose(
        from start: Date,
        to end: Date,
        in context: NSManagedObjectContext
    ) throws -> [PostMealGlucoseReading] {
        let request = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
        request.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND (isManual == NO OR isManual == nil)",
            start as NSDate,
            end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return try context.fetch(request).compactMap { row -> PostMealGlucoseReading? in
            guard let date = row.date, row.glucose > 0 else { return nil }
            return PostMealGlucoseReading(mgdl: Int(row.glucose), date: date)
        }
    }

    private static func boluses(
        from start: Date,
        to end: Date,
        in context: NSManagedObjectContext
    ) throws -> [AIInsights.MealOutcomeInputs.Bolus] {
        let request = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
        request.predicate = NSPredicate(
            format: "type == %@ AND timestamp >= %@ AND timestamp <= %@",
            PumpEventStored.EventType.bolus.rawValue,
            start as NSDate,
            end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["bolus"]
        return try context.fetch(request).compactMap { event -> AIInsights.MealOutcomeInputs.Bolus? in
            guard let id = event.id, let date = event.timestamp, let bolus = event.bolus else { return nil }
            let units = bolus.amount?.doubleValue ?? bolus.programmedAmount?.doubleValue ?? 0
            return AIInsights.MealOutcomeInputs.Bolus(
                pumpEventID: id,
                date: date,
                units: units,
                isSMB: bolus.isSMB,
                isExternal: bolus.isExternal
            )
        }
    }

    private static func tempBasals(
        from start: Date,
        to end: Date,
        in context: NSManagedObjectContext
    ) throws -> [AIInsights.MealOutcomeInputs.TempBasal] {
        let request = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
        request.predicate = NSPredicate(
            format: "type == %@ AND timestamp >= %@ AND timestamp <= %@",
            PumpEventStored.EventType.tempBasal.rawValue,
            start as NSDate,
            end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["tempBasal"]
        return try context.fetch(request).compactMap { event -> AIInsights.MealOutcomeInputs.TempBasal? in
            guard let tempBasal = event.tempBasal, let rate = tempBasal.rate?.doubleValue,
                  let begin = tempBasal.startDate ?? event.timestamp
            else { return nil }
            let finish = tempBasal.endDate ?? begin.addingTimeInterval(Double(tempBasal.duration) * 60)
            return AIInsights.MealOutcomeInputs.TempBasal(start: begin, end: finish, rate: rate)
        }
    }

    /// Scheduled basal rates and IOB as the loop runs reported them.
    private static func loopRuns(
        from start: Date,
        to end: Date,
        in context: NSManagedObjectContext
    ) throws -> (scheduledBasals: [AIInsights.MealOutcomeInputs.ScheduledBasal], iob: [AIInsights.MealOutcomeInputs.IOB]) {
        let request = NSFetchRequest<OrefDetermination>(entityName: "OrefDetermination")
        request.predicate = NSPredicate(format: "deliverAt >= %@ AND deliverAt <= %@", start as NSDate, end as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
        var scheduledBasals: [AIInsights.MealOutcomeInputs.ScheduledBasal] = []
        var iob: [AIInsights.MealOutcomeInputs.IOB] = []
        for determination in try context.fetch(request) {
            guard let date = determination.deliverAt else { continue }
            if let rate = determination.scheduledBasal?.doubleValue {
                scheduledBasals.append(AIInsights.MealOutcomeInputs.ScheduledBasal(date: date, rate: rate))
            }
            if let units = determination.iob?.doubleValue {
                iob.append(AIInsights.MealOutcomeInputs.IOB(date: date, units: units))
            }
        }
        return (scheduledBasals, iob)
    }

    private static func carbs(
        from start: Date,
        to end: Date,
        in context: NSManagedObjectContext
    ) throws -> [AIInsights.MealOutcomeInputs.Carbs] {
        let request = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
        request.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return try context.fetch(request).compactMap { row -> AIInsights.MealOutcomeInputs.Carbs? in
            guard let date = row.date else { return nil }
            return AIInsights.MealOutcomeInputs.Carbs(id: row.id, date: date, grams: row.carbs, isFPU: row.isFPU)
        }
    }
}
