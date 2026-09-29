import Foundation
import Testing

@testable import Trio

@Suite("FoodFinder post-meal windows") struct PostMealSummaryTests {
    let meal = Date(timeIntervalSince1970: 1_700_000_000)
    let limits = FoodFinderPostMealLimits(lowMgdl: 70, highMgdl: 180)

    private func readings(_ mgdl: Int, minutes: StrideThrough<Int>, after start: Date? = nil) -> [PostMealGlucoseReading] {
        let origin = start ?? meal
        return minutes.map { PostMealGlucoseReading(mgdl: mgdl, date: origin.addingTimeInterval(Double($0) * 60)) }
    }

    @Test("Steady readings every 5 minutes cover the whole 0–2 h window")
    func steadyReadingsCoverWindow() {
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: readings(120, minutes: stride(from: 0, through: 120, by: 5)),
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.basis == .analysisTime)
        #expect(summary.occurrenceCount == 1)
        #expect(summary.zeroToTwoHours.startHour == 0)
        #expect(summary.zeroToTwoHours.endHour == 2)
        #expect(summary.zeroToTwoHours.occurrenceCount == 1)
        #expect(summary.zeroToTwoHours.readingCount == 25)
        #expect(summary.zeroToTwoHours.timeInRangePercent == 100)
        #expect(summary.zeroToTwoHours.timeBelowRangePercent == 0)
        #expect(summary.zeroToTwoHours.timeAboveRangePercent == 0)
        #expect(summary.zeroToTwoHours.isComplete)
        #expect(!summary.zeroToTwoHours.hadHypo)
        #expect(!summary.zeroToTwoHours.hadHyper)
        #expect(summary.twoToFourHours.startHour == 2)
        #expect(summary.twoToFourHours.endHour == 4)
    }

    @Test("Time in range is weighted by time, not by the number of readings")
    func denseReadingsDoNotOutweighSparseOnes() {
        // One hour of 1-minute readings high, then one hour of 5-minute readings in range.
        // Counting readings would give 18 % in range; by time it is half.
        let high = readings(200, minutes: stride(from: 0, through: 59, by: 1))
        let inRange = readings(120, minutes: stride(from: 60, through: 120, by: 5))
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: inRange + high,
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.zeroToTwoHours.readingCount == 73)
        #expect(summary.zeroToTwoHours.timeInRangePercent == 50)
        #expect(summary.zeroToTwoHours.timeAboveRangePercent == 50)
        #expect(summary.zeroToTwoHours.timeBelowRangePercent == 0)
        #expect(summary.zeroToTwoHours.hadHyper)
        #expect(summary.zeroToTwoHours.highOccurrenceCount == 1)
    }

    @Test("Gaps longer than 15 minutes count as no data")
    func longGapsAreNotBridged() {
        // 250 at 0, 5, 10 min covers 12.5 min; 120 from 60 to 120 min covers 62.5 min.
        let early = readings(250, minutes: stride(from: 0, through: 10, by: 5))
        let late = readings(120, minutes: stride(from: 60, through: 120, by: 5))
        let window = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: early + late,
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        ).zeroToTwoHours

        #expect(window.timeInRangePercent == 83)
        #expect(window.timeAboveRangePercent == 17)

        let exposure = PostMealGlucoseExposure.measure(
            early + late,
            from: meal,
            to: meal.addingTimeInterval(2 * 60 * 60),
            limits: limits
        )
        #expect(exposure.coveredSeconds == 75 * 60)
        #expect(exposure.aboveSeconds == 12.5 * 60)
        #expect(exposure.inRangeSeconds == 62.5 * 60)
        #expect(exposure.belowSeconds == 0)

        let bridged = PostMealGlucoseExposure.measure(
            readings(120, minutes: stride(from: 0, through: 120, by: 15)),
            from: meal,
            to: meal.addingTimeInterval(2 * 60 * 60),
            limits: limits
        )
        #expect(bridged.coveredSeconds == 120 * 60)
    }

    @Test("Loading only the glucose spans gives the same windows as loading everything")
    func glucoseMarginKeepsEdgeWeights() {
        // 15-minute gaps straddle the meal and the 4 h end, so the neighbours that bridge
        // them sit just inside the loading margin.
        let values = [60, 120, 200, 150, 250, 90]
        let all = stride(from: -180, through: 420, by: 5)
            .filter { !(-8 ... 3).contains($0) && !(118 ... 124).contains($0) && !(236 ... 248).contains($0) }
            .enumerated()
            .map { index, minute in
                PostMealGlucoseReading(mgdl: values[index % values.count], date: meal.addingTimeInterval(Double(minute) * 60))
            }
        let occurrence = FoodFinderPostMealOccurrence(mealTime: meal, carbs: nil, fpuID: nil)
        let now = meal.addingTimeInterval(7 * 60 * 60)
        let intervals = FoodFinderPostMealSummary.glucoseIntervals(for: [occurrence], now: now)
        let loaded = all.filter { reading in intervals.contains { $0.contains(reading.date) } }
        #expect(loaded.count < all.count)

        let full = FoodFinderPostMealSummary.make(occurrences: [occurrence], basis: .loggedMeals, readings: all, now: now)
        let partial = FoodFinderPostMealSummary.make(occurrences: [occurrence], basis: .loggedMeals, readings: loaded, now: now)
        #expect(full == partial)
        #expect(full.zeroToTwoHours.timeInRangePercent != nil)
    }

    @Test("Glucose spans are merged, cut off at now, and skip meals in the future")
    func glucoseIntervalsMerge() {
        let margin = FoodFinderPostMealSummary.glucoseMargin
        let occurrences = [
            FoodFinderPostMealOccurrence(mealTime: meal.addingTimeInterval(3 * 60 * 60), carbs: nil, fpuID: nil),
            FoodFinderPostMealOccurrence(mealTime: meal, carbs: nil, fpuID: nil),
            FoodFinderPostMealOccurrence(mealTime: meal.addingTimeInterval(24 * 60 * 60), carbs: nil, fpuID: nil),
            FoodFinderPostMealOccurrence(mealTime: meal.addingTimeInterval(40 * 60 * 60), carbs: nil, fpuID: nil)
        ]
        let now = meal.addingTimeInterval(26 * 60 * 60)
        let intervals = FoodFinderPostMealSummary.glucoseIntervals(for: occurrences, now: now)

        #expect(intervals == [
            DateInterval(start: meal.addingTimeInterval(-margin), end: meal.addingTimeInterval(7 * 60 * 60 + margin)),
            DateInterval(start: meal.addingTimeInterval(24 * 60 * 60 - margin), end: now)
        ])
        #expect(FoodFinderPostMealSummary.glucoseIntervals(for: [], now: now).isEmpty)
    }

    @Test("Readings exactly at the low and high limits stay in range")
    func boundaryReadingsStayInRange() {
        let all = readings(70, minutes: stride(from: 0, through: 25, by: 5))
            + readings(180, minutes: stride(from: 30, through: 55, by: 5))
            + readings(69, minutes: stride(from: 60, through: 85, by: 5))
            + readings(181, minutes: stride(from: 90, through: 120, by: 5))
        let window = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: all,
            limits: limits,
            now: meal.addingTimeInterval(3 * 60 * 60)
        ).zeroToTwoHours

        #expect(window.timeInRangePercent == 48)
        #expect(window.timeBelowRangePercent == 25)
        #expect(window.timeAboveRangePercent == 27)
        #expect(window.hadHypo)
        #expect(window.hadHyper)
        #expect(window.lowOccurrenceCount == 1)
        #expect(window.highOccurrenceCount == 1)
    }

    @Test("A window that has not ended yet reports the time so far")
    func openWindowIsIncomplete() {
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: readings(100, minutes: stride(from: 0, through: 40, by: 5)),
            limits: limits,
            now: meal.addingTimeInterval(42 * 60)
        )

        #expect(!summary.zeroToTwoHours.isComplete)
        #expect(summary.zeroToTwoHours.occurrenceCount == 1)
        #expect(summary.zeroToTwoHours.timeInRangePercent == 100)
        #expect(!summary.zeroToTwoHours.hadHypo)
        #expect(!summary.zeroToTwoHours.hadHyper)

        #expect(!summary.twoToFourHours.isComplete)
        #expect(summary.twoToFourHours.occurrenceCount == 0)
        #expect(summary.twoToFourHours.timeInRangePercent == nil)

        let exposure = PostMealGlucoseExposure.measure(
            readings(100, minutes: stride(from: 0, through: 40, by: 5)),
            from: meal,
            to: meal.addingTimeInterval(42 * 60),
            limits: limits
        )
        #expect(exposure.coveredSeconds == 42 * 60)
    }

    @Test("Windows are pooled by time over every logged occurrence")
    func occurrencesArePooled() {
        let secondMeal = meal.addingTimeInterval(24 * 60 * 60)
        let first = readings(120, minutes: stride(from: 0, through: 120, by: 5))
        let second = readings(250, minutes: stride(from: 0, through: 55, by: 5), after: secondMeal)
            + readings(120, minutes: stride(from: 60, through: 120, by: 5), after: secondMeal)
        let summary = FoodFinderPostMealSummary.make(
            occurrences: [
                FoodFinderPostMealOccurrence(mealTime: meal, carbs: 40, fpuID: nil),
                FoodFinderPostMealOccurrence(mealTime: secondMeal, carbs: 40, fpuID: nil)
            ],
            basis: .loggedMeals,
            readings: second + first,
            limits: limits,
            now: secondMeal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.basis == .loggedMeals)
        #expect(summary.occurrenceCount == 2)
        #expect(summary.latestMealTime == secondMeal)
        #expect(summary.zeroToTwoHours.occurrenceCount == 2)
        #expect(summary.zeroToTwoHours.highOccurrenceCount == 1)
        #expect(summary.zeroToTwoHours.lowOccurrenceCount == 0)
        #expect(summary.zeroToTwoHours.timeInRangePercent == 76)
        #expect(summary.zeroToTwoHours.timeAboveRangePercent == 24)
        #expect(summary.zeroToTwoHours.isComplete)
    }

    @Test("A meal still inside its window keeps the pooled window open")
    func pooledWindowOpenWhileAnyMealIsRecent() {
        let recentMeal = meal.addingTimeInterval(24 * 60 * 60)
        let summary = FoodFinderPostMealSummary.make(
            occurrences: [
                FoodFinderPostMealOccurrence(mealTime: meal, carbs: nil, fpuID: nil),
                FoodFinderPostMealOccurrence(mealTime: recentMeal, carbs: nil, fpuID: nil)
            ],
            basis: .loggedMeals,
            readings: readings(120, minutes: stride(from: 0, through: 240, by: 5)),
            limits: limits,
            now: recentMeal.addingTimeInterval(30 * 60)
        )

        #expect(!summary.zeroToTwoHours.isComplete)
        #expect(summary.zeroToTwoHours.occurrenceCount == 1)
        #expect(summary.twoToFourHours.occurrenceCount == 1)
        #expect(!summary.twoToFourHours.isComplete)
    }

    @Test("The 2–4 h window is measured separately from the first two hours")
    func laterWindowIsSeparate() {
        let all = readings(120, minutes: stride(from: 0, through: 120, by: 5))
            + readings(250, minutes: stride(from: 125, through: 240, by: 5))
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: all,
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.zeroToTwoHours.timeInRangePercent == 100)
        #expect(!summary.zeroToTwoHours.hadHyper)
        #expect(summary.twoToFourHours.timeInRangePercent == 2)
        #expect(summary.twoToFourHours.timeAboveRangePercent == 98)
        #expect(summary.twoToFourHours.hadHyper)
        #expect(summary.twoToFourHours.isComplete)
    }

    @Test("Missing or inverted limits fall back to 70 and 180")
    func fallbackLimits() {
        let missing = FoodFinderPostMealLimits.resolved(lowMgdl: 0, highMgdl: 0)
        #expect(missing == FoodFinderPostMealLimits(lowMgdl: 70, highMgdl: 180))
        #expect(FoodFinderPostMealLimits.standard == FoodFinderPostMealLimits(lowMgdl: 70, highMgdl: 180))

        let inverted = FoodFinderPostMealLimits.resolved(lowMgdl: 200, highMgdl: 100)
        #expect(inverted.lowMgdl == 200)
        #expect(inverted.highMgdl == 201)
        #expect(inverted.highMgdl != 270)
    }

    @Test("The default limits are the 70–180 mg/dL consensus range")
    func defaultLimitsAreStandard() {
        let summary = FoodFinderPostMealSummary.make(mealTime: meal, readings: [], now: meal)
        #expect(summary.limits == .standard)
    }

    @Test("An empty window reports no time in range")
    func emptyWindow() {
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: [],
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.occurrenceCount == 1)
        #expect(summary.zeroToTwoHours.occurrenceCount == 0)
        #expect(summary.zeroToTwoHours.readingCount == 0)
        #expect(summary.zeroToTwoHours.timeInRangePercent == nil)
        #expect(summary.zeroToTwoHours.isComplete)
        #expect(!summary.zeroToTwoHours.hadHypo)
        #expect(!summary.zeroToTwoHours.hadHyper)
        #expect(summary.fpu == nil)
    }

    @Test("Warsaw equivalents are attached only to the matching meal")
    func warsawEquivalentsFollowTheMeal() {
        let anchor = PostMealCarbEntry(date: meal.addingTimeInterval(60), carbs: 40, isFPU: false, fpuID: "meal-1")
        let early = PostMealCarbEntry(date: meal.addingTimeInterval(2 * 60 * 60), carbs: 10, isFPU: true, fpuID: "meal-1")
        let later = PostMealCarbEntry(date: meal.addingTimeInterval(3 * 60 * 60), carbs: 10, isFPU: true, fpuID: "meal-1")
        let inside = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: [],
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60),
            carbEntries: [anchor, early, later],
            mealCarbs: 40
        )
        #expect(inside.fpu == .insideFourHourWindow(until: meal.addingTimeInterval(3 * 60 * 60)))

        let delayed = PostMealCarbEntry(date: meal.addingTimeInterval(5 * 60 * 60), carbs: 8, isFPU: true, fpuID: "meal-1")
        let pastFourHours = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: [],
            limits: limits,
            now: meal.addingTimeInterval(6 * 60 * 60),
            carbEntries: [anchor, delayed],
            mealCarbs: 45
        )
        #expect(pastFourHours.fpu == .afterFourHourWindow(until: meal.addingTimeInterval(5 * 60 * 60)))

        let otherMeal = PostMealCarbEntry(date: meal.addingTimeInterval(30 * 60), carbs: 80, isFPU: false, fpuID: "other")
        let otherFPU = PostMealCarbEntry(date: meal.addingTimeInterval(2 * 60 * 60), carbs: 10, isFPU: true, fpuID: "other")
        let unmatched = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: [],
            limits: limits,
            now: meal,
            carbEntries: [otherMeal, otherFPU],
            mealCarbs: 20
        )
        #expect(unmatched.fpu == nil)
    }

    @Test("A logged meal finds its Warsaw equivalents by the recorded id only")
    func loggedMealUsesRecordedFPUID() {
        let fpuID = "0F8E2B5C-4C1D-4E8B-9A3F-2B7C6D5E4F10"
        let entries = [
            PostMealCarbEntry(date: meal.addingTimeInterval(60), carbs: 40, isFPU: false, fpuID: fpuID),
            PostMealCarbEntry(date: meal.addingTimeInterval(2 * 60 * 60), carbs: 10, isFPU: true, fpuID: fpuID.lowercased()),
            PostMealCarbEntry(date: meal.addingTimeInterval(5 * 60 * 60), carbs: 10, isFPU: true, fpuID: fpuID),
            PostMealCarbEntry(date: meal.addingTimeInterval(7 * 60 * 60), carbs: 10, isFPU: true, fpuID: "other")
        ]
        let logged = FoodFinderPostMealSummary.make(
            occurrences: [FoodFinderPostMealOccurrence(mealTime: meal, carbs: 40, fpuID: fpuID)],
            basis: .loggedMeals,
            readings: [],
            limits: limits,
            now: meal.addingTimeInterval(8 * 60 * 60),
            carbEntries: entries
        )
        #expect(logged.fpu == .afterFourHourWindow(until: meal.addingTimeInterval(5 * 60 * 60)))

        let withoutID = FoodFinderPostMealSummary.make(
            occurrences: [FoodFinderPostMealOccurrence(mealTime: meal, carbs: 40, fpuID: nil)],
            basis: .loggedMeals,
            readings: [],
            limits: limits,
            now: meal.addingTimeInterval(8 * 60 * 60),
            carbEntries: entries
        )
        #expect(withoutID.fpu == nil)
    }
}
