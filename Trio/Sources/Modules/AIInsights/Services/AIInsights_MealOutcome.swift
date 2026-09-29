import Foundation

extension AIInsights {
    /// Glucose around one saved meal on a fixed 5-minute grid, in mg/dL, from an hour before to six hours after.
    ///
    /// Kept in the `MealEvent` once the meal is old enough (`MealOutcomeEngine.finalAfter`), so the curve outlives
    /// Trio's 90-day glucose purge.
    struct MealEventCurve: Codable, Equatable, Sendable {
        static let stepMinutes = 5
        static let firstMinute = -60
        static let lastMinute = 360
        /// A grid point this close to a reading takes that reading.
        static let snapTolerance: TimeInterval = 2.5 * 60
        /// Readings further apart than this are not joined, so a sensor gap stays a gap.
        static let maxInterpolationGap: TimeInterval = 15 * 60

        /// Minutes from the meal time of the first value.
        var startMinute: Int
        var stepMinutes: Int
        /// One value per grid point; nil where there is no glucose or the point is still in the future.
        var values: [Int?]

        var minutes: [Int] { values.indices.map { startMinute + $0 * stepMinutes } }

        func value(atMinute minute: Int) -> Int? {
            guard stepMinutes > 0, minute >= startMinute, (minute - startMinute) % stepMinutes == 0 else { return nil }
            let index = (minute - startMinute) / stepMinutes
            return values.indices.contains(index) ? values[index] : nil
        }

        /// Grid points with glucose from `from` through `through` minutes, in order.
        func points(from: Int, through: Int) -> [MealCurvePoint] {
            values.indices.compactMap { index -> MealCurvePoint? in
                let minute = startMinute + index * stepMinutes
                guard minute >= from, minute <= through, let mgdl = values[index] else { return nil }
                return MealCurvePoint(minute: minute, mgdl: mgdl)
            }
        }

        /// Share of the grid points from `from` through `through` minutes that have glucose.
        func coverage(from: Int, through: Int) -> Double {
            let total = (through - from) / stepMinutes + 1
            guard total > 0 else { return 0 }
            return Double(points(from: from, through: through).count) / Double(total)
        }

        /// Takes the nearest reading within `snapTolerance` of each grid point, else joins the readings on both
        /// sides when they are at most `maxInterpolationGap` apart. Points after `now` stay empty.
        static func make(readings: [PostMealGlucoseReading], mealTime: Date, now: Date) -> MealEventCurve {
            let sorted = readings.filter { $0.mgdl > 0 }.sorted { $0.date < $1.date }
            let count = (lastMinute - firstMinute) / stepMinutes + 1
            var values = [Int?](repeating: nil, count: count)
            for index in 0 ..< count {
                let time = mealTime.addingTimeInterval(TimeInterval(firstMinute + index * stepMinutes) * 60)
                guard time <= now else { break }
                values[index] = value(at: time, in: sorted)
            }
            return MealEventCurve(startMinute: firstMinute, stepMinutes: stepMinutes, values: values)
        }

        private static func value(at time: Date, in sorted: [PostMealGlucoseReading]) -> Int? {
            let next = firstIndex(in: sorted, notBefore: time)
            let after = next < sorted.count ? sorted[next] : nil
            let before = next > 0 ? sorted[next - 1] : nil

            let nearest = [before, after].compactMap { $0 }.min {
                abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time))
            }
            if let nearest, abs(nearest.date.timeIntervalSince(time)) <= snapTolerance {
                return nearest.mgdl
            }
            guard let before, let after else { return nil }
            let gap = after.date.timeIntervalSince(before.date)
            guard gap > 0, gap <= maxInterpolationGap else { return nil }
            let fraction = time.timeIntervalSince(before.date) / gap
            return Int((Double(before.mgdl) + Double(after.mgdl - before.mgdl) * fraction).rounded())
        }

        private static func firstIndex(in readings: [PostMealGlucoseReading], notBefore date: Date) -> Int {
            var low = 0
            var high = readings.count
            while low < high {
                let middle = (low + high) / 2
                if readings[middle].date < date {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
    }

    struct MealCurvePoint: Equatable, Sendable {
        var minute: Int
        var mgdl: Int
    }

    /// What happened after one saved meal: glucose metrics, the insulin that went in and what may have disturbed it.
    /// Descriptive only; nothing here says what a dose should have been.
    struct MealOutcome: Codable, Equatable, Sendable {
        /// Bumped when the calculation changes, so cached outcomes are recomputed while Trio still has the data.
        static let currentVersion = 1

        var version: Int
        var computedAt: Date
        /// Mean glucose in the 15 minutes up to the meal.
        var baselineMgdl: Double?
        var peakMgdl: Int?
        var peakMinute: Int?
        /// Peak minus baseline.
        var riseMgdl: Double?
        var nadirMgdl: Int?
        var nadirMinute: Int?
        var mean0to4hMgdl: Double?
        /// Incremental area above the baseline over 0–2, 0–3 and 0–4 h, in mg/dL × minutes (trapezoid rule).
        /// Nil when less than `MealOutcomeEngine.minimumCoverage` of that span has glucose.
        var iauc2h: Double?
        var iauc3h: Double?
        var iauc4h: Double?
        /// First time after the peak that glucose is back at or below the baseline, within 6 h.
        var returnToBaselineMinute: Int?
        var windows: [MealOutcomeWindow]
        /// Minutes to the first glucose below 70 mg/dL within 4 h.
        var firstLowMinute: Int?
        /// Any glucose below 54 mg/dL within 4 h.
        var hadVeryLow: Bool
        /// Share of 0–4 h with glucose.
        var coverage0to4h: Double
        var insulin: MealOutcomeInsulin
        /// Carbs logged 15 minutes to 4 hours after the meal that are not part of it.
        var laterCarbs: [MealOutcomeCarbs]
        var flags: MealOutcomeFlags

        var hadLow: Bool { firstLowMinute != nil }
        var hadCorrection: Bool { insulin.correctionUnits > 0 }
        var hadRescueCarbs: Bool { laterCarbs.contains(where: \.isRescue) }

        func window(_ startMinute: Int, _ endMinute: Int) -> MealOutcomeWindow? {
            windows.first { $0.startMinute == startMinute && $0.endMinute == endMinute }
        }
    }

    struct MealOutcomeWindow: Codable, Equatable, Sendable {
        var startMinute: Int
        var endMinute: Int
        var inRangePercent: Int?
        var belowPercent: Int?
        var abovePercent: Int?
    }

    /// Insulin in the four hours after the meal, split by where it came from. oref adds SMBs and temp basals on
    /// top of the meal bolus, so the meal bolus alone is not the insulin the meal got.
    struct MealOutcomeInsulin: Codable, Equatable, Sendable {
        /// The linked meal bolus plus any other manual bolus from 45 minutes before to 30 minutes after the meal.
        var mealBolusUnits: Double
        /// What the bolus calculator recommended when the meal was saved.
        var recommendedUnits: Double?
        var smbUnits: Double
        /// Temp basal insulin above (or, when negative, below) the scheduled basal; nil when the scheduled rate
        /// was unknown for part of the window.
        var tempBasalExtraUnits: Double?
        /// Manual boluses 30 minutes to 4 hours after the meal.
        var correctionUnits: Double
        var correctionMinutes: [Int]

        var totalUnits: Double {
            mealBolusUnits + smbUnits + (tempBasalExtraUnits ?? 0) + correctionUnits
        }
    }

    struct MealOutcomeCarbs: Codable, Equatable, Sendable {
        var minute: Int
        var grams: Double
        /// Logged while glucose was below 90 mg/dL, or within 30 minutes of a low.
        var isRescue: Bool
    }

    /// Things around the meal that make its curve a poor example of the meal itself.
    struct MealOutcomeFlags: Codable, Equatable, Sendable {
        /// Other carbs of at least 10 g in the two hours before the meal.
        var mealBefore: Bool
        /// Other carbs of at least 10 g within three hours after the meal that were not rescue carbs.
        var mealAfter: Bool
        /// Less than `MealOutcomeEngine.minimumCoverage` of 0–4 h has glucose.
        var lowCoverage: Bool
        /// An override or temp target was running at the meal.
        var adjustmentActive: Bool

        /// Kept in the bands and the summary unless the user includes disturbed meals.
        var isUndisturbed: Bool { !mealBefore && !mealAfter && !lowCoverage }
    }

    /// Trio's rows around one meal, as read for `MealOutcomeEngine`.
    struct MealOutcomeInputs: Equatable, Sendable {
        struct Bolus: Equatable, Sendable {
            var pumpEventID: String
            var date: Date
            var units: Double
            var isSMB: Bool
            var isExternal: Bool
        }

        struct TempBasal: Equatable, Sendable {
            var start: Date
            /// Programmed end; the next temp basal can end it earlier.
            var end: Date
            var rate: Double
        }

        /// A scheduled basal rate as a loop run saw it.
        struct ScheduledBasal: Equatable, Sendable {
            var date: Date
            var rate: Double
        }

        struct Carbs: Equatable, Sendable {
            var id: UUID?
            var date: Date
            var grams: Double
            var isFPU: Bool
        }

        var readings: [PostMealGlucoseReading]
        var boluses: [Bolus]
        var tempBasals: [TempBasal]
        var scheduledBasals: [ScheduledBasal]
        var carbs: [Carbs]

        static let empty = MealOutcomeInputs(readings: [], boluses: [], tempBasals: [], scheduledBasals: [], carbs: [])
    }

    /// A saved meal with its curve and outcome.
    struct MealEventAnalysis: Equatable, Identifiable, Sendable {
        var event: MealEvent
        var curve: MealEventCurve
        var outcome: MealOutcome
        /// The whole curve is in the past, so the analysis can be stored and no longer changes.
        var isFinal: Bool

        var id: UUID { event.id }
    }

    enum MealOutcomeEngine {
        static let baselineMinutes = 15
        static let lowMgdl = 70
        static let veryLowMgdl = 54
        static let rescueBelowMgdl = 90
        static let rescueAfterLowMinutes = 30
        static let otherMealGrams = 10.0
        static let minimumCoverage = 0.7
        static let mealBolusWindow = -45 ... 30
        static let correctionWindow = 30 ... 240
        /// When the last curve point is in the past, plus time for late readings to arrive.
        static let finalAfter: TimeInterval = TimeInterval(MealEventCurve.lastMinute + 15) * 60
        /// How far back Trio's rows are read for one meal.
        static let inputsBefore: TimeInterval = 4 * 60 * 60
        static let inputsAfter: TimeInterval = TimeInterval(MealEventCurve.lastMinute + 15) * 60

        static func analyze(
            _ event: MealEvent,
            inputs: MealOutcomeInputs,
            limits: FoodFinderPostMealLimits = .standard,
            now: Date
        ) -> MealEventAnalysis {
            let curve = MealEventCurve.make(readings: inputs.readings, mealTime: event.mealTime, now: now)
            let outcome = Self.outcome(for: event, curve: curve, inputs: inputs, limits: limits, now: now)
            return MealEventAnalysis(
                event: event,
                curve: curve,
                outcome: outcome,
                isFinal: now.timeIntervalSince(event.mealTime) >= finalAfter
            )
        }

        /// The stored curve and outcome, when they were computed by the current version.
        static func cached(_ event: MealEvent) -> MealEventAnalysis? {
            guard let curve = event.curve, let outcome = event.outcome, outcome.version == MealOutcome.currentVersion
            else { return nil }
            return MealEventAnalysis(event: event, curve: curve, outcome: outcome, isFinal: true)
        }

        static func outcome(
            for event: MealEvent,
            curve: MealEventCurve,
            inputs: MealOutcomeInputs,
            limits: FoodFinderPostMealLimits = .standard,
            now: Date
        ) -> MealOutcome {
            let baseline = Self.baseline(curve)
            let fourHours = curve.points(from: 0, through: 240)
            let peak = fourHours.max { $0.mgdl < $1.mgdl }
            let nadir = fourHours.min { $0.mgdl < $1.mgdl }
            let coverage = curve.coverage(from: 0, through: 240)
            let firstLow = fourHours.first { $0.mgdl < lowMgdl }?.minute
            let later = laterCarbs(for: event, inputs: inputs, curve: curve, firstLowMinute: firstLow)
            var rise: Double?
            if let peak, let baseline {
                rise = Double(peak.mgdl) - baseline
            }
            let spans: [(Int, Int)] = [(0, 120), (120, 240), (0, 240)]
            var windows: [MealOutcomeWindow] = []
            for span in spans {
                windows.append(window(
                    for: event,
                    from: span.0,
                    to: span.1,
                    readings: inputs.readings,
                    limits: limits,
                    now: now
                ))
            }
            let before = otherCarbs(for: event, inputs: inputs, from: -120, to: -15)
            let flags = MealOutcomeFlags(
                mealBefore: before.contains { $0.grams >= otherMealGrams },
                mealAfter: later.contains { !$0.isRescue && $0.minute <= 180 && $0.grams >= otherMealGrams },
                lowCoverage: coverage < minimumCoverage,
                adjustmentActive: isAdjustmentActive(event.loop)
            )
            let glucoseValues: [Double] = fourHours.map { Double($0.mgdl) }

            return MealOutcome(
                version: MealOutcome.currentVersion,
                computedAt: now,
                baselineMgdl: baseline,
                peakMgdl: peak?.mgdl,
                peakMinute: peak?.minute,
                riseMgdl: rise,
                nadirMgdl: nadir?.mgdl,
                nadirMinute: nadir?.minute,
                mean0to4hMgdl: mean(glucoseValues),
                iauc2h: incrementalArea(curve, baseline: baseline, through: 120),
                iauc3h: incrementalArea(curve, baseline: baseline, through: 180),
                iauc4h: incrementalArea(curve, baseline: baseline, through: 240),
                returnToBaselineMinute: returnToBaseline(curve, baseline: baseline, peakMinute: peak?.minute),
                windows: windows,
                firstLowMinute: firstLow,
                hadVeryLow: fourHours.contains { $0.mgdl < veryLowMgdl },
                coverage0to4h: coverage,
                insulin: insulin(for: event, inputs: inputs),
                laterCarbs: later,
                flags: flags
            )
        }

        // MARK: - Glucose

        static func baseline(_ curve: MealEventCurve) -> Double? {
            mean(curve.points(from: -baselineMinutes, through: 0).map { Double($0.mgdl) })
        }

        /// Area above `baseline` from the meal through `through` minutes; parts below the baseline count as zero.
        static func incrementalArea(_ curve: MealEventCurve, baseline: Double?, through: Int) -> Double? {
            guard let baseline, curve.coverage(from: 0, through: through) >= minimumCoverage else { return nil }
            let points = curve.points(from: 0, through: through)
            var area = 0.0
            for (left, right) in zip(points, points.dropFirst()) {
                let width = Double(right.minute - left.minute)
                guard width <= MealEventCurve.maxInterpolationGap / 60 else { continue }
                let a = Double(left.mgdl) - baseline
                let b = Double(right.mgdl) - baseline
                if a >= 0, b >= 0 {
                    area += (a + b) / 2 * width
                } else if a > 0 || b > 0 {
                    // Only the triangle above the baseline counts.
                    let above = max(a, b)
                    let crossing = width * above / (abs(a) + abs(b))
                    area += above / 2 * crossing
                }
            }
            return (area * 10).rounded() / 10
        }

        static func returnToBaseline(_ curve: MealEventCurve, baseline: Double?, peakMinute: Int?) -> Int? {
            guard let baseline, let peakMinute else { return nil }
            let after = curve.points(from: peakMinute, through: MealEventCurve.lastMinute)
            return after.first { Double($0.mgdl) <= baseline }?.minute
        }

        static func window(
            for event: MealEvent,
            from startMinute: Int,
            to endMinute: Int,
            readings: [PostMealGlucoseReading],
            limits: FoodFinderPostMealLimits,
            now: Date
        ) -> MealOutcomeWindow {
            let start = event.mealTime.addingTimeInterval(TimeInterval(startMinute) * 60)
            let end = min(now, event.mealTime.addingTimeInterval(TimeInterval(endMinute) * 60))
            let exposure = PostMealGlucoseExposure.measure(
                readings.sorted { $0.date < $1.date },
                from: start,
                to: end,
                limits: limits
            )
            return MealOutcomeWindow(
                startMinute: startMinute,
                endMinute: endMinute,
                inRangePercent: exposure.percent(of: exposure.inRangeSeconds),
                belowPercent: exposure.percent(of: exposure.belowSeconds),
                abovePercent: exposure.percent(of: exposure.aboveSeconds)
            )
        }

        // MARK: - Insulin

        static func insulin(for event: MealEvent, inputs: MealOutcomeInputs) -> MealOutcomeInsulin {
            let linkedIDs = Set(event.bolus.records.map(\.pumpEventID))
            let linkedUnits = event.bolus.deliveredUnits
                ?? event.bolus.records.compactMap { $0.amountUnits ?? $0.programmedUnits }.reduce(0, +)
            var mealBolus = linkedUnits
            var smb = 0.0
            var correction = 0.0
            var correctionMinutes: [Int] = []

            for bolus in inputs.boluses where !linkedIDs.contains(bolus.pumpEventID) && bolus.units > 0 {
                let minute = minutes(from: event.mealTime, to: bolus.date)
                if bolus.isSMB {
                    if minute >= 0, minute <= 240 { smb += bolus.units }
                } else if mealBolusWindow.contains(minute) {
                    mealBolus += bolus.units
                } else if minute > correctionWindow.lowerBound, minute <= correctionWindow.upperBound {
                    correction += bolus.units
                    correctionMinutes.append(minute)
                }
            }

            return MealOutcomeInsulin(
                mealBolusUnits: rounded(mealBolus),
                recommendedUnits: event.calculator.recommendedUnits > 0 ? event.calculator.recommendedUnits : nil,
                smbUnits: rounded(smb),
                tempBasalExtraUnits: tempBasalExtra(
                    from: event.mealTime,
                    to: event.mealTime.addingTimeInterval(4 * 60 * 60),
                    inputs: inputs
                ).map { rounded($0) },
                correctionUnits: rounded(correction),
                correctionMinutes: correctionMinutes.sorted()
            )
        }

        /// Temp basal insulin between `start` and `end` minus what the scheduled basal would have given over the
        /// same time. Time without a temp basal runs at the scheduled rate and adds nothing.
        static func tempBasalExtra(from start: Date, to end: Date, inputs: MealOutcomeInputs) -> Double? {
            let temps = inputs.tempBasals.sorted { $0.start < $1.start }
            let schedule = inputs.scheduledBasals.sorted { $0.date < $1.date }
            var extra = 0.0
            for (index, temp) in temps.enumerated() {
                let programmedEnd = index + 1 < temps.count ? min(temp.end, temps[index + 1].start) : temp.end
                let segmentStart = max(start, temp.start)
                let segmentEnd = min(end, programmedEnd)
                guard segmentEnd > segmentStart else { continue }
                guard let scheduled = scheduledRate(at: segmentStart, in: schedule) else { return nil }
                extra += (temp.rate - scheduled) * segmentEnd.timeIntervalSince(segmentStart) / 3600
            }
            return extra
        }

        /// The rate the latest loop run up to an hour before `date` saw, else the first one after it within an hour.
        static func scheduledRate(at date: Date, in schedule: [MealOutcomeInputs.ScheduledBasal]) -> Double? {
            let hour: TimeInterval = 60 * 60
            if let before = schedule.last(where: { $0.date <= date && date.timeIntervalSince($0.date) <= hour }) {
                return before.rate
            }
            return schedule.first { $0.date > date && $0.date.timeIntervalSince(date) <= hour }?.rate
        }

        // MARK: - Carbs and flags

        static func laterCarbs(
            for event: MealEvent,
            inputs: MealOutcomeInputs,
            curve: MealEventCurve,
            firstLowMinute: Int?
        ) -> [MealOutcomeCarbs] {
            otherCarbs(for: event, inputs: inputs, from: 15, to: 240).map { entry -> MealOutcomeCarbs in
                let glucose = curve.points(from: MealEventCurve.firstMinute, through: entry.minute).last?.mgdl
                let afterLow = firstLowMinute.map { entry.minute >= $0 && entry.minute - $0 <= rescueAfterLowMinutes } ?? false
                let isRescue = (glucose.map { $0 < rescueBelowMgdl } ?? false) || afterLow
                return MealOutcomeCarbs(minute: entry.minute, grams: entry.grams, isRescue: isRescue)
            }
        }

        /// Carb entries that are not this meal or its fat/protein equivalents, from `from` (exclusive) through `to`
        /// minutes after the meal.
        static func otherCarbs(
            for event: MealEvent,
            inputs: MealOutcomeInputs,
            from: Int,
            to: Int
        ) -> [(minute: Int, grams: Double)] {
            let own = Set(event.carbLink.carbEntryIDs + event.carbLink.fpuEntryIDs)
            return inputs.carbs
                .filter { entry in
                    guard !entry.isFPU, entry.grams > 0 else { return false }
                    guard let id = entry.id else { return true }
                    return !own.contains(id)
                }
                .filter { entry in
                    // Without a carb link, the entry at the meal time with the meal's carbs is the meal itself.
                    !(event.carbLink.carbEntryIDs.isEmpty && abs(entry.date.timeIntervalSince(event.mealTime)) < 1
                        && abs(entry.grams - event.nutrition.carbs) < 0.05)
                }
                .map { (minute: minutes(from: event.mealTime, to: $0.date), grams: $0.grams) }
                .filter { $0.minute > from && $0.minute <= to }
                .sorted { $0.minute < $1.minute }
        }

        static func isAdjustmentActive(_ loop: MealEventLoopSnapshot?) -> Bool {
            guard let loop else { return false }
            if let override = loop.override, override.percentage != 100 || override.targetMgdl != nil || override.smbIsOff {
                return true
            }
            return loop.tempTarget != nil
        }

        // MARK: - Helpers

        static func minutes(from start: Date, to date: Date) -> Int {
            Int((date.timeIntervalSince(start) / 60).rounded())
        }

        static func mean(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        static func rounded(_ value: Double) -> Double {
            (value * 1000).rounded() / 1000
        }
    }
}

