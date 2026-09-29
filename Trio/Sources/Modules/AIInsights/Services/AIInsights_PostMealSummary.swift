import Foundation

/// One stored glucose reading, in mg/dL, for a post-meal window.
struct PostMealGlucoseReading: Equatable {
    var mgdl: Int
    var date: Date
}

/// A logged carb row used only to find Warsaw fat/protein equivalents for a meal.
struct PostMealCarbEntry: Equatable {
    var date: Date
    var carbs: Double
    var isFPU: Bool
    var fpuID: String?
}

/// Glucose bounds for a FoodFinder post-meal summary.
///
/// FoodFinder reports against the consensus CGM target range of 70–180 mg/dL
/// (`standard`) rather than the home-chart limits, so the numbers read the same way
/// as published time-in-range targets. Below range is under `lowMgdl`, above range is
/// over `highMgdl`, and both limits themselves count as in range.
struct FoodFinderPostMealLimits: Equatable {
    var lowMgdl: Int
    var highMgdl: Int

    static let fallbackLowMgdl = 70
    static let fallbackHighMgdl = 180
    static let standard = FoodFinderPostMealLimits(lowMgdl: fallbackLowMgdl, highMgdl: fallbackHighMgdl)

    /// Repairs a missing or inverted pair. The fallback is 70 and 180 mg/dL.
    static func resolved(lowMgdl: Int, highMgdl: Int) -> FoodFinderPostMealLimits {
        let low = lowMgdl > 0 ? lowMgdl : fallbackLowMgdl
        let high = highMgdl > low ? highMgdl : max(low + 1, fallbackHighMgdl)
        return FoodFinderPostMealLimits(lowMgdl: low, highMgdl: high)
    }
}

/// One time a meal was eaten.
struct FoodFinderPostMealOccurrence: Equatable {
    var mealTime: Date
    var carbs: Double?
    /// Warsaw fat/protein id recorded with the meal. When nil, a meal timed from the
    /// FoodFinder analysis falls back to matching carb rows logged near `mealTime`.
    var fpuID: String?
}

/// Time-weighted glucose exposure for one meal inside one window.
///
/// Each reading stands for the time up to halfway to a neighbour at most `maxBridgedGap`
/// away. A 1-minute and a 5-minute CGM therefore weigh an hour the same. Across a longer
/// gap, or without a neighbour, a reading covers `edgeHalfSpan` on that side and the rest
/// of the gap counts as no data.
struct PostMealGlucoseExposure: Equatable {
    var coveredSeconds: TimeInterval = 0
    var belowSeconds: TimeInterval = 0
    var inRangeSeconds: TimeInterval = 0
    var aboveSeconds: TimeInterval = 0
    /// Readings timestamped inside the window.
    var readingCount = 0
    var hasLowReading = false
    var hasHighReading = false

    static let maxBridgedGap: TimeInterval = 15 * 60
    /// Half a 5-minute CGM interval.
    static let edgeHalfSpan: TimeInterval = 2.5 * 60
    static let maxHalfSpan: TimeInterval = maxBridgedGap / 2

    var hasGlucose: Bool { coveredSeconds > 0 || readingCount > 0 }
    var hadLow: Bool { belowSeconds > 0 || hasLowReading }
    var hadHigh: Bool { aboveSeconds > 0 || hasHighReading }

    /// `readings` must be sorted oldest first. Readings just outside the window still
    /// contribute the part of their span that falls inside it.
    static func measure(
        _ readings: [PostMealGlucoseReading],
        from start: Date,
        to end: Date,
        limits: FoodFinderPostMealLimits
    ) -> PostMealGlucoseExposure {
        var exposure = PostMealGlucoseExposure()
        guard end > start else { return exposure }
        let lastRelevant = end.addingTimeInterval(maxHalfSpan)
        var index = firstIndex(in: readings, notBefore: start.addingTimeInterval(-maxHalfSpan))
        while index < readings.count, readings[index].date <= lastRelevant {
            let reading = readings[index]
            let before = index > 0 ? halfSpan(from: readings[index - 1].date, to: reading.date) : edgeHalfSpan
            let after = index + 1 < readings.count ? halfSpan(from: reading.date, to: readings[index + 1].date) : edgeHalfSpan
            let spanStart = max(start, reading.date.addingTimeInterval(-before))
            let spanEnd = min(end, reading.date.addingTimeInterval(after))
            let seconds = spanEnd.timeIntervalSince(spanStart)
            let isBelow = reading.mgdl < limits.lowMgdl
            let isAbove = reading.mgdl > limits.highMgdl

            if reading.date >= start, reading.date <= end {
                exposure.readingCount += 1
                exposure.hasLowReading = exposure.hasLowReading || isBelow
                exposure.hasHighReading = exposure.hasHighReading || isAbove
            }
            if seconds > 0 {
                exposure.coveredSeconds += seconds
                if isBelow {
                    exposure.belowSeconds += seconds
                } else if isAbove {
                    exposure.aboveSeconds += seconds
                } else {
                    exposure.inRangeSeconds += seconds
                }
            }
            index += 1
        }
        return exposure
    }

    mutating func add(_ other: PostMealGlucoseExposure) {
        coveredSeconds += other.coveredSeconds
        belowSeconds += other.belowSeconds
        inRangeSeconds += other.inRangeSeconds
        aboveSeconds += other.aboveSeconds
        readingCount += other.readingCount
        hasLowReading = hasLowReading || other.hasLowReading
        hasHighReading = hasHighReading || other.hasHighReading
    }

    func percent(of seconds: TimeInterval) -> Int? {
        guard coveredSeconds > 0 else { return nil }
        return Int((seconds / coveredSeconds * 100).rounded())
    }

    private static func halfSpan(from earlier: Date, to later: Date) -> TimeInterval {
        let gap = later.timeIntervalSince(earlier)
        return gap <= maxBridgedGap ? gap / 2 : edgeHalfSpan
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

/// Post-meal glucose for one window after the meal (0–2 h or 2–4 h), pooled over
/// every time the meal was eaten.
struct FoodFinderPostMealWindow: Equatable {
    var startHour: Int
    var endHour: Int
    /// Meals with glucose in this window: the n shown next to the numbers.
    var occurrenceCount: Int
    var readingCount: Int
    /// Meals with any time or reading below or above range in this window.
    var lowOccurrenceCount: Int
    var highOccurrenceCount: Int
    /// Rounded shares of the covered time, pooled over the meals. Nil without glucose.
    var timeInRangePercent: Int?
    var timeBelowRangePercent: Int?
    var timeAboveRangePercent: Int?
    /// False while any of the meals is still inside this window.
    var isComplete: Bool

    var hadHypo: Bool { lowOccurrenceCount > 0 }
    var hadHyper: Bool { highOccurrenceCount > 0 }

    static func pooled(
        startHour: Int,
        endHour: Int,
        occurrences: [FoodFinderPostMealOccurrence],
        readings: [PostMealGlucoseReading],
        limits: FoodFinderPostMealLimits,
        now: Date
    ) -> FoodFinderPostMealWindow {
        var total = PostMealGlucoseExposure()
        var occurrenceCount = 0
        var lowCount = 0
        var highCount = 0
        var isComplete = !occurrences.isEmpty
        for occurrence in occurrences {
            let start = occurrence.mealTime.addingTimeInterval(TimeInterval(startHour) * 3600)
            let end = occurrence.mealTime.addingTimeInterval(TimeInterval(endHour) * 3600)
            if now < end {
                isComplete = false
            }
            let exposure = PostMealGlucoseExposure.measure(readings, from: start, to: min(end, now), limits: limits)
            guard exposure.hasGlucose else { continue }
            occurrenceCount += 1
            if exposure.hadLow {
                lowCount += 1
            }
            if exposure.hadHigh {
                highCount += 1
            }
            total.add(exposure)
        }
        return FoodFinderPostMealWindow(
            startHour: startHour,
            endHour: endHour,
            occurrenceCount: occurrenceCount,
            readingCount: total.readingCount,
            lowOccurrenceCount: lowCount,
            highOccurrenceCount: highCount,
            timeInRangePercent: total.percent(of: total.inRangeSeconds),
            timeBelowRangePercent: total.percent(of: total.belowSeconds),
            timeAboveRangePercent: total.percent(of: total.aboveSeconds),
            isComplete: isComplete
        )
    }
}

/// Where logged Warsaw fat/protein carb equivalents sit relative to the 4 hour window.
enum FoodFinderPostMealFPU: Equatable {
    case insideFourHourWindow(until: Date)
    case afterFourHourWindow(until: Date)
}

/// Time-weighted glucose 0–2 h and 2–4 h after a meal, pooled over the times it was eaten.
/// The 2–4 h window is there because fat and protein can raise glucose later.
struct FoodFinderPostMealSummary: Equatable {
    enum Basis: Equatable {
        /// Times the meal was saved from the bolus calculator (`MealEvent`).
        case loggedMeals
        /// Nothing logged yet, so the meal is timed from the FoodFinder analysis.
        case analysisTime
    }

    var limits: FoodFinderPostMealLimits
    var basis: Basis
    /// Meals the windows are pooled over.
    var occurrenceCount: Int
    var zeroToTwoHours: FoodFinderPostMealWindow
    var twoToFourHours: FoodFinderPostMealWindow
    var latestMealTime: Date?
    /// Warsaw equivalents of the most recent meal.
    var fpu: FoodFinderPostMealFPU?

    var windows: [FoodFinderPostMealWindow] { [zeroToTwoHours, twoToFourHours] }

    static let fourHourDuration: TimeInterval = 4 * 60 * 60
    /// How far from the FoodFinder timestamp a logged carb entry can be and still count as this meal.
    static let carbMatchWindow: TimeInterval = 20 * 60
    /// Glucose to load before and after each meal's 0–4 h span so edge readings keep their weight.
    static let glucoseMargin: TimeInterval = PostMealGlucoseExposure.maxBridgedGap

    /// Glucose spans `make` reads for `occurrences`: each meal's 0–4 h with `glucoseMargin`
    /// on both sides, cut off at `now`, oldest first and merged where they overlap.
    static func glucoseIntervals(for occurrences: [FoodFinderPostMealOccurrence], now: Date) -> [DateInterval] {
        let spans = occurrences
            .map { occurrence -> DateInterval? in
                let start = occurrence.mealTime.addingTimeInterval(-glucoseMargin)
                let end = min(now, occurrence.mealTime.addingTimeInterval(fourHourDuration + glucoseMargin))
                return end > start ? DateInterval(start: start, end: end) : nil
            }
            .compactMap { $0 }
            .sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    static func make(
        occurrences: [FoodFinderPostMealOccurrence],
        basis: Basis,
        readings: [PostMealGlucoseReading],
        limits: FoodFinderPostMealLimits = .standard,
        now: Date,
        carbEntries: [PostMealCarbEntry] = []
    ) -> FoodFinderPostMealSummary {
        let bounds = FoodFinderPostMealLimits.resolved(lowMgdl: limits.lowMgdl, highMgdl: limits.highMgdl)
        let sorted = readings.sorted { $0.date < $1.date }
        let latest = occurrences.max { $0.mealTime < $1.mealTime }
        return FoodFinderPostMealSummary(
            limits: bounds,
            basis: basis,
            occurrenceCount: occurrences.count,
            zeroToTwoHours: .pooled(
                startHour: 0,
                endHour: 2,
                occurrences: occurrences,
                readings: sorted,
                limits: bounds,
                now: now
            ),
            twoToFourHours: .pooled(
                startHour: 2,
                endHour: 4,
                occurrences: occurrences,
                readings: sorted,
                limits: bounds,
                now: now
            ),
            latestMealTime: latest?.mealTime,
            fpu: latest.flatMap { fpuStatus(for: $0, basis: basis, carbEntries: carbEntries) }
        )
    }

    /// A single meal timed from its FoodFinder analysis.
    static func make(
        mealTime: Date,
        readings: [PostMealGlucoseReading],
        limits: FoodFinderPostMealLimits = .standard,
        now: Date,
        carbEntries: [PostMealCarbEntry] = [],
        mealCarbs: Double? = nil
    ) -> FoodFinderPostMealSummary {
        make(
            occurrences: [FoodFinderPostMealOccurrence(mealTime: mealTime, carbs: mealCarbs, fpuID: nil)],
            basis: .analysisTime,
            readings: readings,
            limits: limits,
            now: now,
            carbEntries: carbEntries
        )
    }

    private static func fpuStatus(
        for occurrence: FoodFinderPostMealOccurrence,
        basis: Basis,
        carbEntries: [PostMealCarbEntry]
    ) -> FoodFinderPostMealFPU? {
        let end: Date?
        if let fpuID = occurrence.fpuID {
            end = carbEntries
                .filter { $0.isFPU && $0.fpuID?.caseInsensitiveCompare(fpuID) == .orderedSame }
                .map(\.date)
                .max()
        } else if basis == .analysisTime {
            end = matchedFPUEnd(mealTime: occurrence.mealTime, mealCarbs: occurrence.carbs, carbEntries: carbEntries)
        } else {
            end = nil
        }
        guard let end else { return nil }
        return end <= occurrence.mealTime.addingTimeInterval(fourHourDuration)
            ? .insideFourHourWindow(until: end)
            : .afterFourHourWindow(until: end)
    }

    /// Latest Warsaw equivalent (`isFPU`) sharing an id with a non-FPU carb entry logged near this meal.
    private static func matchedFPUEnd(
        mealTime: Date,
        mealCarbs: Double?,
        carbEntries: [PostMealCarbEntry]
    ) -> Date? {
        let start = mealTime.addingTimeInterval(-carbMatchWindow)
        let end = mealTime.addingTimeInterval(carbMatchWindow)
        let anchors = carbEntries.filter { entry in
            !entry.isFPU && entry.date >= start && entry.date <= end
        }
        guard let anchor = closestAnchor(to: mealTime, carbs: mealCarbs, in: anchors) else { return nil }
        if let mealCarbs, mealCarbs > 0 {
            let tolerance = max(15, mealCarbs * 0.3)
            guard abs(anchor.carbs - mealCarbs) <= tolerance else { return nil }
        }
        guard let fpuID = anchor.fpuID, !fpuID.isEmpty else { return nil }
        return carbEntries
            .filter { $0.isFPU && $0.fpuID == fpuID && $0.date >= mealTime }
            .map(\.date)
            .max()
    }

    private static func closestAnchor(
        to mealTime: Date,
        carbs mealCarbs: Double?,
        in anchors: [PostMealCarbEntry]
    ) -> PostMealCarbEntry? {
        guard let mealCarbs else {
            return anchors.min {
                abs($0.date.timeIntervalSince(mealTime)) < abs($1.date.timeIntervalSince(mealTime))
            }
        }
        return anchors.min { lhs, rhs in
            let leftGap = abs(lhs.carbs - mealCarbs)
            let rightGap = abs(rhs.carbs - mealCarbs)
            if leftGap == rightGap {
                return abs(lhs.date.timeIntervalSince(mealTime)) < abs(rhs.date.timeIntervalSince(mealTime))
            }
            return leftGap < rightGap
        }
    }
}
