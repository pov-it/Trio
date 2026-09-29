import Foundation

extension AIInsights {
    /// A FoodFinder meal saved from the bolus calculator: the links to Trio's carb and bolus rows, what the
    /// calculator proposed against what was given, and the loop state around the meal.
    ///
    /// Stored by `MealEventStore` outside Trio's Core Data model, with its own retention, so the history
    /// outlives Trio's 90-day purge. Glucose values are mg/dL and insulin is in units throughout.
    struct MealEvent: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        /// When the bolus calculator saved the meal.
        var recordedAt: Date
        /// Date of the saved carb entry: the meal time confirmed in the bolus calculator.
        var mealTime: Date
        var mealSlot: MealSlot?
        var meal: MealEventMeal
        var nutrition: MealEventNutrition
        var carbLink: MealEventCarbLink
        var calculator: MealEventCalculator
        var bolus: MealEventBolus
        /// Loop state at the meal time, or at the save time for a meal logged ahead.
        var loop: MealEventLoopSnapshot?
        /// First loop run after the meal and its bolus were saved: the first prediction that includes them.
        var firstLoopAfter: MealEventDetermination?
        /// Glucose around the meal, kept once the whole curve is in the past so it outlives Trio's glucose purge.
        var curve: MealEventCurve? = nil
        /// What happened after the meal, computed together with `curve`.
        var outcome: MealOutcome? = nil
    }

    struct MealEventMeal: Codable, Equatable, Sendable {
        /// The same for every time this meal is eaten: derived from `mealKey`, not from one analysis.
        var mealID: UUID
        /// Normalized meal name (or ingredient names), the notion of "same meal" used by frequent meals.
        var mealKey: String
        var name: String
        /// `FoodAnalysisResult.id` of the analysis that was sent to the bolus calculator.
        var foodResultID: UUID?
        /// `FoodAnalysisResult.timestamp`.
        var analysisAt: Date?
        /// `FoodAnalysisResult.FoodSource` raw value.
        var source: String?
        /// `FoodFinderPhotoEngine` raw value for meal photos.
        var photoEngine: String?
    }

    struct MealEventNutrition: Codable, Equatable, Sendable {
        /// Grams as saved in the bolus calculator, which may differ from FoodFinder's totals.
        var carbs: Double
        var fat: Double
        var protein: Double
        /// Fat-protein units of the saved fat and protein: (9 × fat + 4 × protein) / 100 kcal.
        var fpu: Double
        var fiber: Double?
        var kcal: Double?
        var foodFinderCarbs: Double?
        var foodFinderFat: Double?
        var foodFinderProtein: Double?
        /// FoodFinder's carb uncertainty band as fractions of its carb estimate.
        var carbLowerRatio: Double?
        var carbUpperRatio: Double?

        static func fpu(fat: Double, protein: Double) -> Double {
            (fat * 9 + protein * 4) / 100
        }
    }

    struct MealEventCarbLink: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case pending
            case linked
            case notFound
            /// The linked carb entry no longer exists in Trio.
            case deleted
        }

        enum Method: String, Codable, Sendable {
            /// The fat/protein id generated for this meal when it was saved.
            case fpuID
            /// The exact carb entry date and carbs.
            case date
        }

        var status: Status
        var method: Method?
        /// `CarbEntryStored.id` of the meal's own carb entry.
        var carbEntryIDs: [UUID]
        /// `CarbEntryStored.fpuID` shared by the meal entry and its Warsaw equivalents.
        var fpuID: UUID?
        /// `CarbEntryStored.id`s of the Warsaw fat/protein equivalents.
        var fpuEntryIDs: [UUID]
        var fpuCarbs: Double?
        var fpuFrom: Date?
        var fpuUntil: Date?

        mutating func apply(_ match: MealEventCarbMatch) {
            status = .linked
            method = match.method
            carbEntryIDs = match.carbEntryIDs
            fpuEntryIDs = match.fpuEntryIDs
            fpuCarbs = match.fpuCarbs
            fpuFrom = match.fpuFrom
            fpuUntil = match.fpuUntil
        }
    }

    /// The carb rows Trio stored for a meal.
    struct MealEventCarbMatch: Equatable, Sendable {
        var method: MealEventCarbLink.Method
        var carbEntryIDs: [UUID]
        var fpuEntryIDs: [UUID]
        var fpuCarbs: Double?
        var fpuFrom: Date?
        var fpuUntil: Date?
    }

    /// The bolus calculator at the moment the meal was saved.
    struct MealEventCalculator: Codable, Equatable, Sendable {
        enum AmountSource: String, Codable, Sendable {
            /// No insulin was entered.
            case none
            /// The entered amount equals the recommendation.
            case recommendation
            case edited
        }

        /// Full calculator result before the bolus fraction and meal factors.
        var wholeUnits: Double
        /// After the bolus fraction, the fatty-meal factor and any super bolus.
        var factoredUnits: Double
        /// The recommendation after Max Bolus, Max IOB and rounding.
        var recommendedUnits: Double
        var fraction: Double
        var usedFattyMealFactor: Bool
        var fattyMealFactor: Double?
        var usedSuperBolus: Bool
        var superBolusUnits: Double?
        /// FoodFinder suggested the reduced (fatty-meal) bolus for this meal.
        var reducedBolusSuggested: Bool?
        /// The amount in the bolus field when the meal was saved.
        var enteredUnits: Double
        var amountSource: AmountSource
        var isExternalInsulin: Bool
        var currentBG: Double?
        var deltaBG: Double?
        var iob: Double?
        var cob: Double?
        var target: Double?
        var isf: Double?
        var carbRatio: Double?
        var minPredBG: Double?
        var eventualBG: Double?
        var targetDifferenceUnits: Double?
        var iobReductionUnits: Double?
        var cobUnits: Double?
        var fifteenMinuteUnits: Double?

        static func amountSource(entered: Double, recommended: Double) -> AmountSource {
            guard entered > 0 else { return .none }
            return abs(entered - recommended) < 0.005 ? .recommendation : .edited
        }
    }

    struct MealEventBolus: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            /// No insulin was given from the bolus calculator.
            case none
            /// Waiting for the pump history row of the requested bolus.
            case pending
            case linked
            /// The pump reported an error and no bolus row has appeared.
            case enactFailed
            /// No matching pump history row appeared.
            case notFound
        }

        enum Kind: String, Codable, Sendable {
            case pump
            case external
        }

        var status: Status
        var kind: Kind?
        var requestedUnits: Double?
        /// When the pump bolus was sent, or the time an external dose was logged for.
        var requestedAt: Date?
        /// When the pump accepted the bolus command.
        var enactedAt: Date?
        var records: [MealEventBolusRecord]
        /// Summed `amountUnits` of `records`; the delivered amount once `isDeliveryFinal`.
        var deliveredUnits: Double?
        var isDeliveryFinal: Bool
        /// Meal time minus the first bolus row, in minutes: positive when the bolus came first.
        var preBolusMinutes: Double?

        static let none = MealEventBolus(
            status: .none,
            kind: nil,
            requestedUnits: nil,
            requestedAt: nil,
            enactedAt: nil,
            records: [],
            deliveredUnits: nil,
            isDeliveryFinal: false,
            preBolusMinutes: nil
        )
    }

    struct MealEventBolusRecord: Codable, Equatable, Sendable {
        /// `PumpEventStored.id`.
        var pumpEventID: String
        var timestamp: Date
        var programmedUnits: Double?
        /// `BolusStored.amount`; the programmed amount until the pump reports the dose as finished.
        var amountUnits: Double?
        var isFinal: Bool
        var isExternal: Bool
    }

    /// A bolus row inserted, changed or deleted in Trio's pump history.
    struct MealEventBolusObservation: Equatable, Sendable {
        enum Change: String, Sendable {
            case inserted
            case updated
            case deleted
        }

        var change: Change
        var pumpEventID: String
        var timestamp: Date
        var programmedUnits: Double?
        var amountUnits: Double?
        var isMutable: Bool
        var isExternal: Bool
        var isSMB: Bool

        static func deleted(_ pumpEventID: String) -> MealEventBolusObservation {
            MealEventBolusObservation(
                change: .deleted,
                pumpEventID: pumpEventID,
                timestamp: .distantPast,
                programmedUnits: nil,
                amountUnits: nil,
                isMutable: false,
                isExternal: false,
                isSMB: false
            )
        }
    }

    struct MealEventLoopSnapshot: Codable, Equatable, Sendable {
        /// The time the snapshot describes.
        var reference: Date
        var glucose: MealEventGlucose?
        /// Latest loop run at or before `reference`.
        var determination: MealEventDetermination?
        var tempBasal: MealEventTempBasal?
        var override: MealEventOverride?
        var tempTarget: MealEventTempTarget?
        /// `DosingMode` raw value.
        var dosingMode: String?
    }

    struct MealEventGlucose: Codable, Equatable, Sendable {
        static let deltaTolerance: TimeInterval = 3 * 60

        var mgdl: Int
        var date: Date
        var direction: String?
        /// Change from the reading about 5, 15 and 30 minutes earlier to this one.
        var delta5: Int?
        var delta15: Int?
        var delta30: Int?

        /// Uses the latest reading at or before `reference`; `direction` belongs to that reading.
        static func make(readings: [PostMealGlucoseReading], direction: String?, at reference: Date) -> MealEventGlucose? {
            let sorted = readings.filter { $0.date <= reference && $0.mgdl > 0 }.sorted { $0.date < $1.date }
            guard let latest = sorted.last else { return nil }

            func delta(minutes: Double) -> Int? {
                let target = latest.date.addingTimeInterval(-minutes * 60)
                let earlier = sorted.dropLast().min {
                    abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
                }
                guard let earlier, abs(earlier.date.timeIntervalSince(target)) <= deltaTolerance else { return nil }
                return latest.mgdl - earlier.mgdl
            }

            return MealEventGlucose(
                mgdl: latest.mgdl,
                date: latest.date,
                direction: direction,
                delta5: delta(minutes: 5),
                delta15: delta(minutes: 15),
                delta30: delta(minutes: 30)
            )
        }
    }

    /// One oref loop run (`OrefDetermination`).
    struct MealEventDetermination: Codable, Equatable, Sendable {
        var date: Date
        var glucose: Double?
        var iob: Double?
        var cob: Double?
        var sensitivityRatio: Double?
        var eventualBG: Double?
        var minPredBG: Double?
        var insulinReq: Double?
        var isf: Double?
        var carbRatio: Double?
        var target: Double?
        /// Suggested temp basal rate (U/h) and duration.
        var rate: Double?
        var durationMinutes: Double?
        var smbUnits: Double?
        var scheduledBasal: Double?
        var enacted: Bool?
        var predictions: MealEventPredictions?
    }

    /// Predicted glucose curves, downsampled because Trio keeps its forecasts for two days only.
    struct MealEventPredictions: Codable, Equatable, Sendable {
        static let stepMinutes = 15
        static let horizonMinutes = 240
        static let sourceStepMinutes = 5

        /// Minutes between points; the first point is at the loop run.
        var stepMinutes: Int
        var iob: [Int]?
        var cob: [Int]?
        var uam: [Int]?
        var zt: [Int]?

        /// Downsamples oref's 5-minute curves to `stepMinutes` up to `horizonMinutes`.
        static func downsampled(iob: [Int]?, cob: [Int]?, uam: [Int]?, zt: [Int]?) -> MealEventPredictions? {
            let step = stepMinutes / sourceStepMinutes
            let maxCount = horizonMinutes / stepMinutes + 1

            func sample(_ values: [Int]?) -> [Int]? {
                guard let values, !values.isEmpty else { return nil }
                let indices = Swift.stride(from: 0, to: values.count, by: step).prefix(maxCount)
                return indices.map { values[$0] }
            }

            let curves = MealEventPredictions(
                stepMinutes: stepMinutes,
                iob: sample(iob),
                cob: sample(cob),
                uam: sample(uam),
                zt: sample(zt)
            )
            guard curves.iob != nil || curves.cob != nil || curves.uam != nil || curves.zt != nil else { return nil }
            return curves
        }
    }

    struct MealEventTempBasal: Codable, Equatable, Sendable {
        var rate: Double
        var startedAt: Date
        var durationMinutes: Int
    }

    struct MealEventOverride: Codable, Equatable, Sendable {
        var name: String?
        var percentage: Double
        var targetMgdl: Double?
        var smbIsOff: Bool
        var startedAt: Date?
        var durationMinutes: Double?
        var isIndefinite: Bool
    }

    struct MealEventTempTarget: Codable, Equatable, Sendable {
        var name: String?
        var targetMgdl: Double?
        var startedAt: Date?
        var durationMinutes: Double?
    }

    /// Everything known when the bolus calculator saves a FoodFinder meal.
    struct MealEventDraft: Equatable, Sendable {
        var id: UUID
        var recordedAt: Date
        var mealTime: Date
        var mealSlot: MealSlot?
        var meal: MealEventMeal
        var nutrition: MealEventNutrition
        /// The fat/protein id passed with the carb entry, when the meal has fat or protein.
        var fpuID: UUID?
        var calculator: MealEventCalculator
        var dosingMode: String?
    }
}

extension AIInsights.MealEvent {
    init(draft: AIInsights.MealEventDraft) {
        self.init(
            id: draft.id,
            recordedAt: draft.recordedAt,
            mealTime: draft.mealTime,
            mealSlot: draft.mealSlot,
            meal: draft.meal,
            nutrition: draft.nutrition,
            carbLink: AIInsights.MealEventCarbLink(
                status: .pending,
                method: nil,
                carbEntryIDs: [],
                fpuID: draft.fpuID,
                fpuEntryIDs: [],
                fpuCarbs: nil,
                fpuFrom: nil,
                fpuUntil: nil
            ),
            calculator: draft.calculator,
            bolus: .none,
            loop: nil,
            firstLoopAfter: nil
        )
    }

    /// Earlier times the same meal was saved, newest first. Meals whose carb entry was deleted are left out.
    static func occurrences(
        in events: [AIInsights.MealEvent],
        mealID: UUID,
        foodResultID: UUID?,
        since: Date,
        limit: Int
    ) -> [AIInsights.MealEvent] {
        let matching = events.filter { event in
            guard event.carbLink.status != .deleted, event.mealTime >= since else { return false }
            if event.meal.mealID == mealID { return true }
            guard let foodResultID else { return false }
            return event.meal.foodResultID == foodResultID
        }
        return Array(matching.sorted { $0.mealTime > $1.mealTime }.prefix(max(0, limit)))
    }
}

extension FoodFinderPostMealOccurrence {
    /// A meal saved from the bolus calculator, timed from its carb entry.
    init(event: AIInsights.MealEvent) {
        self.init(mealTime: event.mealTime, carbs: event.nutrition.carbs, fpuID: event.carbLink.fpuID?.uuidString)
    }
}

extension FoodFinderPostMealSummary {
    /// Trio keeps glucose for 90 days, so older saved meals have nothing to show.
    static let savedMealLookbackDays = 90
    static let savedMealLimit = 20

    /// The saved meals to pool, or the FoodFinder analysis itself for a meal never saved from the bolus calculator.
    static func occurrences(
        saved events: [AIInsights.MealEvent],
        analysisTime: Date,
        analysisCarbs: Double?
    ) -> (basis: Basis, occurrences: [FoodFinderPostMealOccurrence]) {
        guard !events.isEmpty else {
            return (.analysisTime, [FoodFinderPostMealOccurrence(mealTime: analysisTime, carbs: analysisCarbs, fpuID: nil)])
        }
        return (.loggedMeals, events.map(FoodFinderPostMealOccurrence.init(event:)))
    }
}

extension AIInsights {
    /// Stable identity of a FoodFinder meal across repeats.
    enum MealEventIdentity {
        private static let namespace = "trio.foodfinder.meal:"

        /// The meal name, else the ingredient names, folded for case, accents, width and spacing. A meal with
        /// neither is keyed by its analysis id, so it only matches itself.
        static func mealKey(mealName: String?, itemNames: [String], resultID: UUID) -> String {
            let named = normalized(mealName ?? "")
            if !named.isEmpty { return named }
            let items = normalized(itemNames.joined(separator: ", "))
            if !items.isEmpty { return items }
            return "result:" + resultID.uuidString.lowercased()
        }

        static func normalized(_ text: String) -> String {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            return folded.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// A name-based UUID (version 8) so the same key gives the same id on every device and install.
        static func mealID(forKey key: String) -> UUID {
            let bytes = Array((namespace + key).utf8)
            let high = fnv1a(bytes, basis: 0xCBF2_9CE4_8422_2325)
            let low = fnv1a(bytes, basis: 0x8422_2325_CBF2_9CE4)
            var uuid = [UInt8](repeating: 0, count: 16)
            for index in 0 ..< 8 {
                let shift = UInt64(56 - 8 * index)
                uuid[index] = UInt8(truncatingIfNeeded: high >> shift)
                uuid[index + 8] = UInt8(truncatingIfNeeded: low >> shift)
            }
            uuid[6] = (uuid[6] & 0x0F) | 0x80
            uuid[8] = (uuid[8] & 0x3F) | 0x80
            return UUID(uuid: (
                uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
                uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]
            ))
        }

        private static func fnv1a(_ bytes: [UInt8], basis: UInt64) -> UInt64 {
            var hash = basis
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
    }

    /// Links a meal's requested bolus to the pump history row that delivered it.
    ///
    /// A request only claims a manual bolus row that Trio inserts after the request, of the same kind (pump or
    /// external), with a matching programmed amount and a timestamp close to the request. Rows that existed before
    /// are never considered, so there is no guessing over past history.
    enum MealEventLinker {
        /// Pump rows carry the pump's clock, which can run slightly behind the phone.
        static let pumpWindowBefore: TimeInterval = 10 * 60
        static let pumpWindowAfter: TimeInterval = 30 * 60
        static let externalWindow: TimeInterval = 2 * 60
        /// Some pumps report a bolus only when their history is next read.
        static let pendingLifetime: TimeInterval = 6 * 60 * 60

        /// Allows for the pump rounding to its bolus increment.
        static func unitsMatch(requested: Double, observed: Double) -> Bool {
            abs(requested - observed) <= max(0.1, requested * 0.05)
        }

        static func request(_ event: inout MealEvent, units: Double, kind: MealEventBolus.Kind, at date: Date) {
            guard units > 0 else { return }
            event.bolus.kind = kind
            event.bolus.requestedUnits = units
            event.bolus.requestedAt = date
            if event.bolus.records.isEmpty {
                event.bolus.status = .pending
            }
        }

        static func enactFinished(_ event: inout MealEvent, success: Bool, at date: Date) {
            guard event.bolus.kind == .pump else { return }
            if success {
                event.bolus.enactedAt = date
            } else if event.bolus.records.isEmpty {
                event.bolus.status = .enactFailed
            }
        }

        /// Applies one save's worth of pump history changes and returns the ids of the events that changed.
        /// Deletions go first so that a row replacing a purged one can claim the freed request.
        @discardableResult static func apply(
            _ observations: [MealEventBolusObservation],
            to events: inout [MealEvent]
        ) -> Set<UUID> {
            var changed = Set<UUID>()
            for observation in observations where observation.change == .deleted {
                if let id = release(observation.pumpEventID, in: &events) { changed.insert(id) }
            }
            for observation in observations where observation.change == .updated {
                if let id = update(observation, in: &events) { changed.insert(id) }
            }
            let inserted = observations.filter { $0.change == .inserted }.sorted { $0.timestamp < $1.timestamp }
            for observation in inserted {
                if let id = claim(observation, in: &events) { changed.insert(id) }
            }
            return changed
        }

        /// Pending requests without a row after `pendingLifetime` become `notFound`.
        @discardableResult static func expire(_ events: inout [MealEvent], now: Date) -> Set<UUID> {
            var changed = Set<UUID>()
            for index in events.indices {
                let bolus = events[index].bolus
                guard bolus.status == .pending, bolus.records.isEmpty, let requestedAt = bolus.requestedAt,
                      now.timeIntervalSince(requestedAt) > pendingLifetime
                else { continue }
                events[index].bolus.status = .notFound
                changed.insert(events[index].id)
            }
            return changed
        }

        static func accepts(_ event: MealEvent, _ observation: MealEventBolusObservation) -> Bool {
            let bolus = event.bolus
            guard observation.change == .inserted, !observation.isSMB, bolus.records.isEmpty else { return false }
            guard bolus.status == .pending || bolus.status == .enactFailed || bolus.status == .notFound else { return false }
            guard let kind = bolus.kind, let requestedAt = bolus.requestedAt, let requestedUnits = bolus.requestedUnits
            else { return false }
            guard observation.isExternal == (kind == .external) else { return false }

            let offset = observation.timestamp.timeIntervalSince(requestedAt)
            let window: ClosedRange<TimeInterval> = kind == .external
                ? -externalWindow ... externalWindow
                : -pumpWindowBefore ... pumpWindowAfter
            guard window.contains(offset) else { return false }
            guard let units = observation.programmedUnits ?? observation.amountUnits else { return false }
            return unitsMatch(requested: requestedUnits, observed: units)
        }

        static func recomputeTotals(_ event: inout MealEvent) {
            var bolus = event.bolus
            bolus.records.sort { $0.timestamp < $1.timestamp }
            if let first = bolus.records.first {
                let amounts = bolus.records.compactMap(\.amountUnits)
                bolus.status = .linked
                bolus.deliveredUnits = amounts.isEmpty ? nil : rounded(amounts.reduce(0, +), places: 3)
                bolus.isDeliveryFinal = bolus.records.allSatisfy(\.isFinal)
                bolus.preBolusMinutes = rounded(event.mealTime.timeIntervalSince(first.timestamp) / 60, places: 1)
            } else {
                bolus.deliveredUnits = nil
                bolus.isDeliveryFinal = false
                bolus.preBolusMinutes = nil
            }
            event.bolus = bolus
        }

        private static func claim(_ observation: MealEventBolusObservation, in events: inout [MealEvent]) -> UUID? {
            let alreadyClaimed = events.contains { event in
                event.bolus.records.contains { $0.pumpEventID == observation.pumpEventID }
            }
            guard !alreadyClaimed else { return nil }

            var best: (index: Int, distance: TimeInterval, requestedAt: Date)?
            for index in events.indices where accepts(events[index], observation) {
                guard let requestedAt = events[index].bolus.requestedAt else { continue }
                let distance = abs(observation.timestamp.timeIntervalSince(requestedAt))
                if let current = best,
                   distance > current.distance || (distance == current.distance && requestedAt <= current.requestedAt)
                {
                    continue
                }
                best = (index, distance, requestedAt)
            }
            guard let index = best?.index else { return nil }

            events[index].bolus.records.append(MealEventBolusRecord(
                pumpEventID: observation.pumpEventID,
                timestamp: observation.timestamp,
                programmedUnits: observation.programmedUnits,
                amountUnits: observation.amountUnits,
                isFinal: !observation.isMutable,
                isExternal: observation.isExternal
            ))
            recomputeTotals(&events[index])
            return events[index].id
        }

        private static func update(_ observation: MealEventBolusObservation, in events: inout [MealEvent]) -> UUID? {
            for index in events.indices {
                guard let recordIndex = events[index].bolus.records.firstIndex(where: {
                    $0.pumpEventID == observation.pumpEventID
                }) else { continue }

                var record = events[index].bolus.records[recordIndex]
                let previous = record
                record.timestamp = observation.timestamp
                record.programmedUnits = observation.programmedUnits ?? record.programmedUnits
                record.amountUnits = observation.amountUnits ?? record.amountUnits
                record.isFinal = record.isFinal || !observation.isMutable
                guard record != previous else { return nil }

                events[index].bolus.records[recordIndex] = record
                recomputeTotals(&events[index])
                return events[index].id
            }
            return nil
        }

        /// A purged row frees its request again, so the row that replaces it can be claimed.
        private static func release(_ pumpEventID: String, in events: inout [MealEvent]) -> UUID? {
            guard let index = events.firstIndex(where: { event in
                event.bolus.records.contains { $0.pumpEventID == pumpEventID }
            }) else { return nil }

            events[index].bolus.records.removeAll { $0.pumpEventID == pumpEventID }
            if events[index].bolus.records.isEmpty {
                events[index].bolus.status = .pending
            }
            recomputeTotals(&events[index])
            return events[index].id
        }

        static func rounded(_ value: Double, places: Int) -> Double {
            let scale = pow(10, Double(places))
            return (value * scale).rounded() / scale
        }
    }
}
