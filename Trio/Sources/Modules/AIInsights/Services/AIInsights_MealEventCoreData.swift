import CoreData
import Foundation

extension AIInsights.MealEventRecorder {
    static let shared: AIInsights.MealEventRecorder = {
        let recorder = AIInsights.MealEventRecorder(
            store: .applicationSupport(),
            dataSource: CoreDataMealEventDataSource(),
            log: { message in debug(.storage, message) }
        )
        Task { await recorder.start() }
        return recorder
    }()
}

/// Reads Trio's Core Data store for `AIInsights.MealEventRecorder`, each lookup on its own background context.
struct CoreDataMealEventDataSource: MealEventDataSource {
    static let carbDateTolerance: TimeInterval = 1
    static let glucoseLookback: TimeInterval = 45 * 60
    static let determinationLookback: TimeInterval = 30 * 60
    static let tempBasalLookback: TimeInterval = 24 * 60 * 60

    func carbMatch(fpuID: UUID?, mealTime: Date, carbs: Double, excluding: Set<UUID>) async -> AIInsights.MealEventCarbMatch? {
        let match: AIInsights.MealEventCarbMatch?? = await read("carbMatch") { context in
            if let fpuID {
                return try Self.carbMatch(fpuID: fpuID, excluding: excluding, in: context)
            }
            return try Self.carbMatch(mealTime: mealTime, carbs: carbs, excluding: excluding, in: context)
        }
        return match ?? nil
    }

    func loopSnapshot(at reference: Date) async -> AIInsights.MealEventLoopSnapshot? {
        await read("loopSnapshot") { context in
            AIInsights.MealEventLoopSnapshot(
                reference: reference,
                glucose: try Self.glucose(at: reference, in: context),
                determination: try Self.determination(
                    NSPredicate(
                        format: "deliverAt <= %@ AND deliverAt >= %@",
                        reference as NSDate,
                        reference.addingTimeInterval(-Self.determinationLookback) as NSDate
                    ),
                    latest: true,
                    in: context
                ),
                tempBasal: try Self.tempBasal(at: reference, in: context),
                override: try Self.override(at: reference, in: context),
                tempTarget: try Self.tempTarget(at: reference, in: context),
                dosingMode: nil
            )
        }
    }

    func firstDetermination(after date: Date, until limit: Date) async -> AIInsights.MealEventDetermination? {
        let determination: AIInsights.MealEventDetermination?? = await read("firstDetermination") { context in
            try Self.determination(
                NSPredicate(format: "deliverAt > %@ AND deliverAt <= %@", date as NSDate, limit as NSDate),
                latest: false,
                in: context
            )
        }
        return determination ?? nil
    }

    func bolusRows(pumpEventIDs: [String]) async -> [AIInsights.MealEventBolusObservation]? {
        await read("bolusRows") { context in
            let request = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
            request.predicate = NSPredicate(format: "id IN %@", pumpEventIDs as NSArray)
            request.relationshipKeyPathsForPrefetching = ["bolus"]
            return try context.fetch(request).compactMap { AIInsights.MealEventBolusObservation(.updated, $0) }
        }
    }

    func existingCarbEntryIDs(among ids: [UUID]) async -> Set<UUID>? {
        await read("existingCarbEntryIDs") { context in
            let request = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
            request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
            return Set(try context.fetch(request).compactMap(\.id))
        }
    }

    private func read<T: Sendable>(_ name: String, _ body: @escaping (NSManagedObjectContext) throws -> T) async -> T? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "FoodFinderMealEvents.\(name)"
        do {
            return try await context.perform { try body(context) }
        } catch {
            debug(.coreData, "FoodFinder meal events: \(name) failed: \(error)")
            return nil
        }
    }

    // MARK: - Carbs

    private static func carbMatch(
        fpuID: UUID,
        excluding: Set<UUID>,
        in context: NSManagedObjectContext
    ) throws -> AIInsights.MealEventCarbMatch? {
        let request = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
        request.predicate = NSPredicate(format: "fpuID == %@", fpuID as CVarArg)
        let rows = try context.fetch(request)
        let meal = rows.filter { !$0.isFPU }.compactMap(\.id).filter { !excluding.contains($0) }
        guard !meal.isEmpty else { return nil }
        let equivalents = rows.filter(\.isFPU)
        let dates = equivalents.compactMap(\.date)
        return AIInsights.MealEventCarbMatch(
            method: .fpuID,
            carbEntryIDs: meal,
            fpuEntryIDs: equivalents.compactMap(\.id),
            fpuCarbs: equivalents.isEmpty ? nil : equivalents.map(\.carbs).reduce(0, +),
            fpuFrom: dates.min(),
            fpuUntil: dates.max()
        )
    }

    private static func carbMatch(
        mealTime: Date,
        carbs: Double,
        excluding: Set<UUID>,
        in context: NSManagedObjectContext
    ) throws -> AIInsights.MealEventCarbMatch? {
        let request = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
        request.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND (isFPU == NO OR isFPU == nil)",
            mealTime.addingTimeInterval(-carbDateTolerance) as NSDate,
            mealTime.addingTimeInterval(carbDateTolerance) as NSDate
        )
        let candidates = try context.fetch(request).compactMap { row -> (id: UUID, offset: TimeInterval)? in
            guard let id = row.id, let date = row.date, !excluding.contains(id), abs(row.carbs - carbs) < 0.05 else { return nil }
            return (id, abs(date.timeIntervalSince(mealTime)))
        }
        guard let closest = candidates.min(by: { $0.offset < $1.offset }) else { return nil }
        return AIInsights.MealEventCarbMatch(
            method: .date,
            carbEntryIDs: [closest.id],
            fpuEntryIDs: [],
            fpuCarbs: nil,
            fpuFrom: nil,
            fpuUntil: nil
        )
    }

    // MARK: - Loop state

    private static func glucose(at reference: Date, in context: NSManagedObjectContext) throws -> AIInsights.MealEventGlucose? {
        let request = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
        request.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND (isManual == NO OR isManual == nil)",
            reference.addingTimeInterval(-glucoseLookback) as NSDate,
            reference as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        let rows = try context.fetch(request).filter { $0.date != nil && $0.glucose > 0 }
        let readings = rows.compactMap { row in row.date.map { PostMealGlucoseReading(mgdl: Int(row.glucose), date: $0) } }
        return AIInsights.MealEventGlucose.make(readings: readings, direction: rows.last?.direction, at: reference)
    }

    private static func determination(
        _ predicate: NSPredicate,
        latest: Bool,
        in context: NSManagedObjectContext
    ) throws -> AIInsights.MealEventDetermination? {
        let request = NSFetchRequest<OrefDetermination>(entityName: "OrefDetermination")
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: !latest)]
        request.fetchLimit = 1
        request.relationshipKeyPathsForPrefetching = ["forecasts", "forecasts.forecastValues"]
        return try context.fetch(request).first.flatMap { AIInsights.MealEventDetermination($0) }
    }

    private static func tempBasal(
        at reference: Date,
        in context: NSManagedObjectContext
    ) throws -> AIInsights.MealEventTempBasal? {
        let request = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
        request.predicate = NSPredicate(
            format: "type == %@ AND timestamp <= %@ AND timestamp >= %@",
            PumpEventStored.EventType.tempBasal.rawValue,
            reference as NSDate,
            reference.addingTimeInterval(-tempBasalLookback) as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        request.relationshipKeyPathsForPrefetching = ["tempBasal"]
        guard let event = try context.fetch(request).first, let tempBasal = event.tempBasal, !tempBasal.isScheduledBasal,
              let rate = tempBasal.rate?.doubleValue
        else { return nil }
        let start = tempBasal.startDate ?? event.timestamp ?? reference
        let end = tempBasal.endDate ?? start.addingTimeInterval(Double(tempBasal.duration) * 60)
        guard end > reference else { return nil }
        return AIInsights.MealEventTempBasal(rate: rate, startedAt: start, durationMinutes: Int(tempBasal.duration))
    }

    /// An override is enabled while it runs and gets an `OverrideRunStored` row once it ends.
    private static func override(at reference: Date, in context: NSManagedObjectContext) throws -> AIInsights.MealEventOverride? {
        let enabled = NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
        enabled.predicate = NSPredicate(format: "enabled == YES AND date <= %@", reference as NSDate)
        enabled.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        for row in try context.fetch(enabled) {
            guard let start = row.date,
                  isRunning(start: start, minutes: row.duration?.doubleValue, indefinite: row.indefinite, at: reference)
            else { continue }
            return AIInsights.MealEventOverride(row, name: row.name, target: row.target, startedAt: start)
        }

        let runs = NSFetchRequest<OverrideRunStored>(entityName: "OverrideRunStored")
        runs.predicate = NSPredicate(format: "startDate <= %@ AND endDate > %@", reference as NSDate, reference as NSDate)
        runs.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
        runs.fetchLimit = 1
        guard let run = try context.fetch(runs).first, let row = run.override else { return nil }
        return AIInsights.MealEventOverride(row, name: run.name ?? row.name, target: run.target, startedAt: run.startDate)
    }

    private static func tempTarget(
        at reference: Date,
        in context: NSManagedObjectContext
    ) throws -> AIInsights.MealEventTempTarget? {
        let enabled = NSFetchRequest<TempTargetStored>(entityName: "TempTargetStored")
        enabled.predicate = NSPredicate(format: "enabled == YES AND date <= %@", reference as NSDate)
        enabled.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        for row in try context.fetch(enabled) {
            guard let start = row.date,
                  isRunning(start: start, minutes: row.duration?.doubleValue, indefinite: false, at: reference)
            else { continue }
            return AIInsights.MealEventTempTarget(
                name: row.name,
                targetMgdl: positive(row.target),
                startedAt: start,
                durationMinutes: row.duration?.doubleValue
            )
        }

        let runs = NSFetchRequest<TempTargetRunStored>(entityName: "TempTargetRunStored")
        runs.predicate = NSPredicate(format: "startDate <= %@ AND endDate > %@", reference as NSDate, reference as NSDate)
        runs.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
        runs.fetchLimit = 1
        guard let run = try context.fetch(runs).first else { return nil }
        return AIInsights.MealEventTempTarget(
            name: run.name ?? run.tempTarget?.name,
            targetMgdl: positive(run.target),
            startedAt: run.startDate,
            durationMinutes: run.tempTarget?.duration?.doubleValue
        )
    }

    /// Mirrors how Trio ends adjustments: no positive duration means running until cancelled.
    private static func isRunning(start: Date, minutes: Double?, indefinite: Bool, at reference: Date) -> Bool {
        guard !indefinite, let minutes, minutes > 0 else { return true }
        return start.addingTimeInterval(minutes * 60) > reference
    }

    fileprivate static func positive(_ value: NSDecimalNumber?) -> Double? {
        guard let value = value?.doubleValue, value > 0 else { return nil }
        return value
    }
}

extension AIInsights {
    /// The manual bolus rows one pump history save inserts, changes or deletes, for `MealEventRecorder`.
    ///
    /// Create it on the context's queue right before `save()` and call `report()` right after the save succeeds:
    /// a row inserted into the context can still be merged into an existing row by the save, and only rows that
    /// survive it are reported. SMB rows are left out, so routine loop activity does not reach the recorder.
    struct MealEventBolusChanges {
        private var rows: [(change: MealEventBolusObservation.Change, event: PumpEventStored)] = []
        private var deletedIDs: [String] = []

        init(before context: NSManagedObjectContext) {
            var seen = Set<NSManagedObjectID>()
            for object in context.insertedObjects {
                guard let event = Self.manualBolusEvent(object), seen.insert(event.objectID).inserted else { continue }
                rows.append((.inserted, event))
            }
            for object in context.updatedObjects {
                guard let event = Self.manualBolusEvent(object), !event.isInserted, seen.insert(event.objectID).inserted
                else { continue }
                rows.append((.updated, event))
            }
            for object in context.deletedObjects {
                guard let event = object as? PumpEventStored, event.type == PumpEventStored.EventType.bolus.rawValue,
                      event.bolus?.isSMB != true, let id = event.id
                else { continue }
                deletedIDs.append(id)
            }
        }

        func report() {
            let current = rows.compactMap { change, event -> MealEventBolusObservation? in
                guard event.managedObjectContext != nil else { return nil }
                return MealEventBolusObservation(change, event)
            }
            let observations = deletedIDs.map { MealEventBolusObservation.deleted($0) } + current
            guard !observations.isEmpty else { return }
            MealEventRecorder.shared.observe(observations)
        }

        private static func manualBolusEvent(_ object: NSManagedObject) -> PumpEventStored? {
            guard let event = (object as? PumpEventStored) ?? (object as? BolusStored)?.pumpEvent,
                  event.type == PumpEventStored.EventType.bolus.rawValue,
                  event.bolus?.isSMB == false
            else { return nil }
            return event
        }
    }
}

private extension AIInsights.MealEventBolusObservation {
    init?(_ change: Change, _ event: PumpEventStored) {
        guard let id = event.id, let bolus = event.bolus else { return nil }
        self.init(
            change: change,
            pumpEventID: id,
            timestamp: event.timestamp ?? .distantPast,
            programmedUnits: bolus.programmedAmount?.doubleValue,
            amountUnits: bolus.amount?.doubleValue,
            isMutable: event.isMutable,
            isExternal: bolus.isExternal,
            isSMB: bolus.isSMB
        )
    }
}

private extension AIInsights.MealEventDetermination {
    init?(_ stored: OrefDetermination) {
        guard let date = stored.deliverAt ?? stored.timestamp else { return nil }
        let forecasts = stored.forecasts ?? []
        func curve(_ type: String) -> [Int]? {
            forecasts.first { $0.type == type }?.forecastValuesArray.map { Int($0.value) }
        }
        self.init(
            date: date,
            glucose: stored.glucose?.doubleValue,
            iob: stored.iob?.doubleValue,
            cob: Double(stored.cob),
            sensitivityRatio: stored.sensitivityRatio?.doubleValue,
            eventualBG: stored.eventualBG?.doubleValue,
            minPredBG: stored.minPredBGFromReason.map { Double($0) },
            insulinReq: stored.insulinReq?.doubleValue,
            isf: stored.insulinSensitivity?.doubleValue,
            carbRatio: stored.carbRatio?.doubleValue,
            target: stored.currentTarget?.doubleValue,
            rate: stored.rate?.doubleValue,
            durationMinutes: stored.duration?.doubleValue,
            smbUnits: stored.smbToDeliver?.doubleValue,
            scheduledBasal: stored.scheduledBasal?.doubleValue,
            enacted: stored.enacted,
            predictions: AIInsights.MealEventPredictions.downsampled(
                iob: curve("iob"),
                cob: curve("cob"),
                uam: curve("uam"),
                zt: curve("zt")
            )
        )
    }
}

private extension AIInsights.MealEventOverride {
    init(_ row: OverrideStored, name: String?, target: NSDecimalNumber?, startedAt: Date?) {
        self.init(
            name: name,
            percentage: row.percentage,
            targetMgdl: CoreDataMealEventDataSource.positive(target) ?? CoreDataMealEventDataSource.positive(row.target),
            smbIsOff: row.smbIsOff,
            startedAt: startedAt,
            durationMinutes: row.indefinite ? nil : row.duration?.doubleValue,
            isIndefinite: row.indefinite
        )
    }
}
