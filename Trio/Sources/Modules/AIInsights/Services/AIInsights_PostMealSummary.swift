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
/// Hypo is a reading below `lowMgdl`. Hyper is a reading above `highMgdl`.
/// Time in range is the share of readings from `lowMgdl` through `highMgdl`.
///
/// These are the user's home-chart limits (`TrioSettings.low` / `TrioSettings.high`),
/// the same numbers the home glucose bobble treats as low and high. They are not
/// the 270 mg/dL default high-alarm threshold, and they are not the tighter
/// 63–140 / 70–140 band used for the TITR/TING percentage on the stats banner.
/// If a limit is missing or inverted, the fallback is 70 and 180 mg/dL, which
/// matches that banner's usual low edge and its fixed 180 mg/dL high.
struct FoodFinderPostMealLimits: Equatable {
    var lowMgdl: Int
    var highMgdl: Int

    static let fallbackLowMgdl = 70
    static let fallbackHighMgdl = 180

    static func resolved(lowMgdl: Int, highMgdl: Int) -> FoodFinderPostMealLimits {
        let low = lowMgdl > 0 ? lowMgdl : fallbackLowMgdl
        let high = highMgdl > low ? highMgdl : max(low + 1, fallbackHighMgdl)
        return FoodFinderPostMealLimits(lowMgdl: low, highMgdl: high)
    }
}

struct FoodFinderPostMealWindow: Equatable {
    var hours: Int
    var readingCount: Int
    var hadHypo: Bool
    var hadHyper: Bool
    /// Rounded percent of readings inside the limits. Nil when the window has no readings.
    var timeInRangePercent: Int?
    /// False while `now` is still inside the window.
    var isComplete: Bool
}

/// Where logged Warsaw fat/protein carb equivalents sit relative to the 4 hour window.
enum FoodFinderPostMealFPU: Equatable {
    case insideFourHourWindow(until: Date)
    case afterFourHourWindow(until: Date)
}

/// Post-meal hypo, hyper, and time in range for 2 hours and 4 hours after a meal.
/// The 4 hour window is there because fat and protein can raise glucose later.
struct FoodFinderPostMealSummary: Equatable {
    var limits: FoodFinderPostMealLimits
    var twoHour: FoodFinderPostMealWindow
    var fourHour: FoodFinderPostMealWindow
    var fpu: FoodFinderPostMealFPU?

    static let twoHourDuration: TimeInterval = 2 * 60 * 60
    static let fourHourDuration: TimeInterval = 4 * 60 * 60
    /// How far from the FoodFinder timestamp a logged carb entry can be and still count as this meal.
    static let carbMatchWindow: TimeInterval = 20 * 60

    static func make(
        mealTime: Date,
        readings: [PostMealGlucoseReading],
        limits: FoodFinderPostMealLimits,
        now: Date,
        carbEntries: [PostMealCarbEntry] = [],
        mealCarbs: Double? = nil
    ) -> FoodFinderPostMealSummary {
        let bounds = FoodFinderPostMealLimits.resolved(lowMgdl: limits.lowMgdl, highMgdl: limits.highMgdl)
        let fpuUntil = matchedFPUEnd(mealTime: mealTime, mealCarbs: mealCarbs, carbEntries: carbEntries)
        let fpu: FoodFinderPostMealFPU? = fpuUntil.map { end in
            end <= mealTime.addingTimeInterval(fourHourDuration)
                ? .insideFourHourWindow(until: end)
                : .afterFourHourWindow(until: end)
        }
        return FoodFinderPostMealSummary(
            limits: bounds,
            twoHour: window(hours: 2, duration: twoHourDuration, mealTime: mealTime, readings: readings, limits: bounds, now: now),
            fourHour: window(hours: 4, duration: fourHourDuration, mealTime: mealTime, readings: readings, limits: bounds, now: now),
            fpu: fpu
        )
    }

    private static func window(
        hours: Int,
        duration: TimeInterval,
        mealTime: Date,
        readings: [PostMealGlucoseReading],
        limits: FoodFinderPostMealLimits,
        now: Date
    ) -> FoodFinderPostMealWindow {
        let end = mealTime.addingTimeInterval(duration)
        let samples = readings.filter { $0.date >= mealTime && $0.date <= end }
        let inRange = samples.filter { $0.mgdl >= limits.lowMgdl && $0.mgdl <= limits.highMgdl }
        let percent: Int? = samples.isEmpty
            ? nil
            : Int((Double(inRange.count) / Double(samples.count) * 100).rounded())
        return FoodFinderPostMealWindow(
            hours: hours,
            readingCount: samples.count,
            hadHypo: samples.contains { $0.mgdl < limits.lowMgdl },
            hadHyper: samples.contains { $0.mgdl > limits.highMgdl },
            timeInRangePercent: percent,
            isComplete: now >= end
        )
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
