import Foundation
import Testing

@testable import Trio

@Suite("FoodFinder post-meal windows") struct PostMealSummaryTests {
    let meal = Date(timeIntervalSince1970: 1_700_000_000)
    let limits = FoodFinderPostMealLimits(lowMgdl: 70, highMgdl: 180)

    @Test("2 hour and 4 hour windows count hypo, hyper, and time in range")
    func windowsSeparateHypoAndLaterHyper() {
        let readings = [
            PostMealGlucoseReading(mgdl: 120, date: meal.addingTimeInterval(30 * 60)),
            PostMealGlucoseReading(mgdl: 60, date: meal.addingTimeInterval(90 * 60)),
            PostMealGlucoseReading(mgdl: 200, date: meal.addingTimeInterval(3 * 60 * 60)),
            PostMealGlucoseReading(mgdl: 110, date: meal.addingTimeInterval(5 * 60 * 60)),
            PostMealGlucoseReading(mgdl: 140, date: meal.addingTimeInterval(-60))
        ]
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: readings,
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.twoHour.readingCount == 2)
        #expect(summary.twoHour.hadHypo)
        #expect(!summary.twoHour.hadHyper)
        #expect(summary.twoHour.timeInRangePercent == 50)
        #expect(summary.twoHour.isComplete)

        #expect(summary.fourHour.readingCount == 3)
        #expect(summary.fourHour.hadHypo)
        #expect(summary.fourHour.hadHyper)
        #expect(summary.fourHour.timeInRangePercent == 33)
        #expect(summary.fourHour.isComplete)
        #expect(summary.limits == limits)
    }

    @Test("A window that has not ended yet stays incomplete")
    func openWindowIsIncomplete() {
        let readings = [
            PostMealGlucoseReading(mgdl: 100, date: meal.addingTimeInterval(20 * 60))
        ]
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: readings,
            limits: limits,
            now: meal.addingTimeInterval(60 * 60)
        )

        #expect(!summary.twoHour.isComplete)
        #expect(!summary.fourHour.isComplete)
        #expect(summary.twoHour.timeInRangePercent == 100)
        #expect(!summary.twoHour.hadHypo)
        #expect(!summary.twoHour.hadHyper)
    }

    @Test("Readings exactly at the low and high limits stay in range")
    func boundaryReadingsStayInRange() {
        let readings = [
            PostMealGlucoseReading(mgdl: 70, date: meal.addingTimeInterval(10 * 60)),
            PostMealGlucoseReading(mgdl: 180, date: meal.addingTimeInterval(20 * 60)),
            PostMealGlucoseReading(mgdl: 69, date: meal.addingTimeInterval(30 * 60)),
            PostMealGlucoseReading(mgdl: 181, date: meal.addingTimeInterval(40 * 60))
        ]
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: readings,
            limits: limits,
            now: meal.addingTimeInterval(3 * 60 * 60)
        )

        #expect(summary.twoHour.hadHypo)
        #expect(summary.twoHour.hadHyper)
        #expect(summary.twoHour.timeInRangePercent == 50)
        #expect(summary.twoHour.readingCount == 4)
    }

    @Test("Missing or inverted limits fall back to 70 and 180")
    func fallbackLimits() {
        let missing = FoodFinderPostMealLimits.resolved(lowMgdl: 0, highMgdl: 0)
        #expect(missing == FoodFinderPostMealLimits(lowMgdl: 70, highMgdl: 180))

        let inverted = FoodFinderPostMealLimits.resolved(lowMgdl: 200, highMgdl: 100)
        #expect(inverted.lowMgdl == 200)
        #expect(inverted.highMgdl == 201)
        #expect(inverted.highMgdl != 270)
    }

    @Test("An empty window reports no time in range")
    func emptyWindow() {
        let summary = FoodFinderPostMealSummary.make(
            mealTime: meal,
            readings: [],
            limits: limits,
            now: meal.addingTimeInterval(5 * 60 * 60)
        )

        #expect(summary.twoHour.readingCount == 0)
        #expect(summary.twoHour.timeInRangePercent == nil)
        #expect(!summary.twoHour.hadHypo)
        #expect(!summary.twoHour.hadHyper)
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
}
