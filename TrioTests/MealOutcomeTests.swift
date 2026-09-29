import Foundation
import Testing

@testable import Trio

private typealias Engine = AIInsights.MealOutcomeEngine
private typealias Inputs = AIInsights.MealOutcomeInputs
private typealias Summary = AIInsights.MealResponseSummary

private let mealTime = Date(timeIntervalSince1970: 1_790_000_000)
/// Late enough that every curve point is in the past.
private let later = mealTime.addingTimeInterval(8 * 60 * 60)

private func at(_ minutes: Double, from date: Date = mealTime) -> Date {
    date.addingTimeInterval(minutes * 60)
}

/// Readings every `step` minutes from `from` through `through`, valued by `glucose(minute)`.
private func readings(
    from: Int = -60,
    through: Int = 360,
    step: Int = 5,
    mealTime origin: Date = mealTime,
    _ glucose: (Int) -> Int
) -> [PostMealGlucoseReading] {
    Swift.stride(from: from, through: through, by: step).map { minute in
        PostMealGlucoseReading(mgdl: glucose(minute), date: at(Double(minute), from: origin))
    }
}

/// Flat at 100 until the meal, up to 160 at one hour, back to 100 at two hours, then flat.
private func triangle(_ minute: Int) -> Int {
    switch minute {
    case ..<0: return 100
    case 0 ..< 60: return 100 + minute
    case 60 ..< 120: return 160 - (minute - 60)
    default: return 100
    }
}

private func makeEvent(
    mealTime time: Date = mealTime,
    name: String = "Pasta pesto",
    carbs: Double = 60,
    carbEntryID: UUID? = nil,
    recommended: Double = 4
) -> AIInsights.MealEvent {
    let resultID = UUID()
    let key = AIInsights.MealEventIdentity.mealKey(mealName: name, itemNames: [], resultID: resultID)
    let draft = AIInsights.MealEventDraft(
        id: UUID(),
        recordedAt: time,
        mealTime: time,
        mealSlot: .dinner,
        meal: AIInsights.MealEventMeal(
            mealID: AIInsights.MealEventIdentity.mealID(forKey: key),
            mealKey: key,
            name: name,
            foodResultID: resultID,
            analysisAt: time,
            source: "aiCamera",
            photoEngine: nil
        ),
        nutrition: AIInsights.MealEventNutrition(
            carbs: carbs,
            fat: 10,
            protein: 10,
            fpu: AIInsights.MealEventNutrition.fpu(fat: 10, protein: 10),
            fiber: nil,
            kcal: nil,
            foodFinderCarbs: carbs,
            foodFinderFat: 10,
            foodFinderProtein: 10,
            carbLowerRatio: nil,
            carbUpperRatio: nil
        ),
        fpuID: nil,
        calculator: AIInsights.MealEventCalculator(
            wholeUnits: recommended,
            factoredUnits: recommended,
            recommendedUnits: recommended,
            fraction: 1,
            usedFattyMealFactor: false,
            fattyMealFactor: nil,
            usedSuperBolus: false,
            superBolusUnits: nil,
            reducedBolusSuggested: nil,
            enteredUnits: recommended,
            amountSource: .recommendation,
            isExternalInsulin: false,
            currentBG: nil,
            deltaBG: nil,
            iob: nil,
            cob: nil,
            target: nil,
            isf: nil,
            carbRatio: nil,
            minPredBG: nil,
            eventualBG: nil,
            targetDifferenceUnits: nil,
            iobReductionUnits: nil,
            cobUnits: nil,
            fifteenMinuteUnits: nil
        ),
        dosingMode: nil
    )
    var event = AIInsights.MealEvent(draft: draft)
    if let carbEntryID {
        event.carbLink.status = .linked
        event.carbLink.method = .date
        event.carbLink.carbEntryIDs = [carbEntryID]
    }
    return event
}

/// An event whose 4 U request was linked to pump row "meal-bolus" one minute after the meal.
private func linkedEvent(units: Double = 4) -> AIInsights.MealEvent {
    var events = [makeEvent()]
    AIInsights.MealEventLinker.request(&events[0], units: units, kind: .pump, at: mealTime)
    AIInsights.MealEventLinker.apply([
        AIInsights.MealEventBolusObservation(
            change: .inserted,
            pumpEventID: "meal-bolus",
            timestamp: at(1),
            programmedUnits: units,
            amountUnits: units,
            isMutable: false,
            isExternal: false,
            isSMB: false
        )
    ], to: &events)
    return events[0]
}

private func inputs(
    readings: [PostMealGlucoseReading] = readings(triangle),
    boluses: [Inputs.Bolus] = [],
    tempBasals: [Inputs.TempBasal] = [],
    scheduledBasals: [Inputs.ScheduledBasal] = [],
    carbs: [Inputs.Carbs] = [],
    iob: [Inputs.IOB] = []
) -> Inputs {
    Inputs(
        readings: readings,
        boluses: boluses,
        tempBasals: tempBasals,
        scheduledBasals: scheduledBasals,
        carbs: carbs,
        iob: iob
    )
}

/// `event` with a loop run at the meal reporting `isf` and `carbRatio`.
private func withLoop(_ event: AIInsights.MealEvent, isf: Double = 50, carbRatio: Double = 10) -> AIInsights.MealEvent {
    var event = event
    var loop = AIInsights.MealEventLoopSnapshot(reference: event.mealTime)
    loop.determination = AIInsights.MealEventDetermination(date: event.mealTime, isf: isf, carbRatio: carbRatio)
    event.loop = loop
    return event
}

private func bolus(_ id: String, _ minute: Double, _ units: Double, smb: Bool = false, external: Bool = false) -> Inputs.Bolus {
    Inputs.Bolus(pumpEventID: id, date: at(minute), units: units, isSMB: smb, isExternal: external)
}

@Suite("FoodFinder meal curves") struct MealEventCurveTests {
    @Test("Grid points take the nearest reading and join readings up to 15 minutes apart")
    func snapsAndInterpolates() {
        let sparse = [
            PostMealGlucoseReading(mgdl: 100, date: at(-1)),
            PostMealGlucoseReading(mgdl: 130, date: at(9)),
            PostMealGlucoseReading(mgdl: 200, date: at(60))
        ]
        let curve = AIInsights.MealEventCurve.make(readings: sparse, mealTime: mealTime, now: later)

        #expect(curve.startMinute == -60)
        #expect(curve.stepMinutes == 5)
        #expect(curve.values.count == 85)
        #expect(curve.value(atMinute: 0) == 100)
        // 5 minutes lies 6 of the 10 minutes from -1 to 9: 100 + 30 × 0.6.
        #expect(curve.value(atMinute: 5) == 118)
        #expect(curve.value(atMinute: 10) == 130)
        // 9 to 60 minutes is too long a gap to join.
        #expect(curve.value(atMinute: 30) == nil)
        #expect(curve.value(atMinute: 60) == 200)
        #expect(curve.value(atMinute: 7) == nil)
    }

    @Test("Points after now stay empty")
    func futureIsEmpty() {
        let curve = AIInsights.MealEventCurve.make(
            readings: readings(triangle),
            mealTime: mealTime,
            now: at(30)
        )
        #expect(curve.value(atMinute: 30) == 130)
        #expect(curve.value(atMinute: 35) == nil)
        #expect(curve.coverage(from: 0, through: 30) == 1)
    }
}

@Suite("FoodFinder meal outcomes") struct MealOutcomeTests {
    @Test("Baseline, peak, rise, nadir and return to baseline")
    func glucoseMetrics() {
        let analysis = Engine.analyze(makeEvent(), inputs: inputs(), now: later)
        let outcome = analysis.outcome

        #expect(analysis.isFinal)
        #expect(outcome.baselineMgdl == 100)
        #expect(outcome.peakMgdl == 160)
        #expect(outcome.peakMinute == 60)
        #expect(outcome.riseMgdl == 60)
        #expect(outcome.nadirMgdl == 100)
        #expect(outcome.returnToBaselineMinute == 120)
        #expect(outcome.coverage0to4h == 1)
        #expect(outcome.firstLowMinute == nil)
        #expect(!outcome.hadVeryLow)
        #expect(outcome.flags.isUndisturbed)
    }

    @Test("Incremental area counts only the part above the baseline")
    func incrementalArea() {
        let outcome = Engine.analyze(makeEvent(), inputs: inputs(), now: later).outcome
        // Triangle of 120 minutes wide and 60 mg/dL high.
        #expect(outcome.iauc2h == 3600)
        #expect(outcome.iauc3h == 3600)
        #expect(outcome.iauc4h == 3600)

        // Dipping 20 below the baseline after two hours adds nothing.
        let dip = readings { minute in minute >= 125 && minute < 240 ? 80 : triangle(minute) }
        let dipped = Engine.analyze(makeEvent(), inputs: inputs(readings: dip), now: later).outcome
        #expect(dipped.iauc4h == 3600)
        #expect(dipped.nadirMgdl == 80)
    }

    @Test("Low coverage leaves the area out and flags the meal")
    func lowCoverage() {
        let gappy = readings(triangle).filter { reading in
            let minute = reading.date.timeIntervalSince(mealTime) / 60
            return minute < 30 || minute > 150
        }
        let outcome = Engine.analyze(makeEvent(), inputs: inputs(readings: gappy), now: later).outcome
        #expect(outcome.coverage0to4h < Engine.minimumCoverage)
        #expect(outcome.iauc4h == nil)
        #expect(outcome.flags.lowCoverage)
        #expect(!outcome.flags.isUndisturbed)
    }

    @Test("A low within four hours is timed from the meal")
    func lows() {
        let low = readings { minute in minute >= 150 && minute < 170 ? 50 : triangle(minute) }
        let outcome = Engine.analyze(makeEvent(), inputs: inputs(readings: low), now: later).outcome
        #expect(outcome.firstLowMinute == 150)
        #expect(outcome.hadVeryLow)
        #expect(outcome.hadLow)
    }

    @Test("A meal still inside its six hours is not final")
    func notFinalYet() {
        let analysis = Engine.analyze(makeEvent(), inputs: inputs(), now: at(200))
        #expect(!analysis.isFinal)
        #expect(analysis.curve.value(atMinute: 205) == nil)
    }

    @Test("Insulin is split into meal bolus, SMB and corrections without counting the linked row twice")
    func insulinSplit() {
        let event = linkedEvent()
        #expect(event.bolus.status == .linked)

        let boluses = [
            bolus("meal-bolus", 1, 4),
            bolus("second-half", 20, 1),
            bolus("smb-1", 30, 0.3, smb: true),
            bolus("smb-2", 90, 0.5, smb: true),
            bolus("smb-late", 300, 0.4, smb: true),
            bolus("correction", 150, 1.5),
            bolus("pen", 200, 0.5, external: true),
            bolus("too-late", 250, 2)
        ]
        let insulin = Engine.analyze(event, inputs: inputs(boluses: boluses), now: later).outcome.insulin

        #expect(insulin.mealBolusUnits == 5)
        #expect(insulin.recommendedUnits == 4)
        #expect(insulin.smbUnits == 0.8)
        #expect(insulin.correctionUnits == 2)
        #expect(insulin.correctionMinutes == [150, 200])
        #expect(insulin.tempBasalExtraUnits == 0)
        #expect(abs(insulin.totalUnits - 7.8) < 0.001)
    }

    @Test("Temp basals count against the scheduled rate, clipped to the four hours")
    func tempBasalExtra() {
        let schedule = [
            Inputs.ScheduledBasal(date: at(-30), rate: 1),
            Inputs.ScheduledBasal(date: at(45), rate: 1)
        ]
        let temps = [
            // 15 of its 30 minutes fall after the meal: (3 − 1) × 0.25 h.
            Inputs.TempBasal(start: at(-15), end: at(15), rate: 3),
            // Cut short by the next temp basal after 15 minutes: (0 − 1) × 0.25 h.
            Inputs.TempBasal(start: at(60), end: at(90), rate: 0),
            Inputs.TempBasal(start: at(75), end: at(75), rate: 1)
        ]
        let extra = Engine.tempBasalExtra(
            from: mealTime,
            to: at(240),
            inputs: inputs(tempBasals: temps, scheduledBasals: schedule)
        )
        #expect(extra == 0.25)

        let unknown = Engine.tempBasalExtra(from: mealTime, to: at(240), inputs: inputs(tempBasals: temps))
        #expect(unknown == nil)
    }

    @Test("Later carbs are rescue carbs when glucose was low, otherwise another meal")
    func laterCarbs() {
        let own = UUID()
        let event = makeEvent(carbEntryID: own)
        let low = readings { minute in minute >= 150 && minute < 200 ? 65 : triangle(minute) }
        let carbs = [
            Inputs.Carbs(id: own, date: mealTime, grams: 60, isFPU: false),
            Inputs.Carbs(id: UUID(), date: at(40), grams: 12, isFPU: true),
            Inputs.Carbs(id: UUID(), date: at(90), grams: 30, isFPU: false),
            Inputs.Carbs(id: UUID(), date: at(160), grams: 15, isFPU: false),
            Inputs.Carbs(id: UUID(), date: at(-60), grams: 5, isFPU: false)
        ]
        let outcome = Engine.analyze(event, inputs: inputs(readings: low, carbs: carbs), now: later).outcome

        #expect(outcome.laterCarbs.count == 2)
        #expect(outcome.laterCarbs.first?.minute == 90)
        #expect(outcome.laterCarbs.first?.isRescue == false)
        #expect(outcome.laterCarbs.last?.minute == 160)
        #expect(outcome.laterCarbs.last?.isRescue == true)
        #expect(outcome.hadRescueCarbs)
        #expect(outcome.flags.mealAfter)
        // 5 g an hour before is below the 10 g threshold.
        #expect(!outcome.flags.mealBefore)
    }

    @Test("Without a carb link, the entry at the meal time with the meal's carbs is the meal itself")
    func unlinkedOwnEntry() {
        let carbs = [Inputs.Carbs(id: UUID(), date: mealTime, grams: 60, isFPU: false)]
        let outcome = Engine.analyze(makeEvent(), inputs: inputs(carbs: carbs), now: later).outcome
        #expect(outcome.laterCarbs.isEmpty)
        #expect(!outcome.flags.mealBefore)
    }

    @Test("Stored analyses are reused only when computed by the current version")
    func cachedVersion() {
        let analysis = Engine.analyze(makeEvent(), inputs: inputs(), now: later)
        var event = analysis.event
        event.curve = analysis.curve
        event.outcome = analysis.outcome
        #expect(Engine.cached(event)?.outcome == analysis.outcome)

        event.outcome?.version = AIInsights.MealOutcome.currentVersion - 1
        #expect(Engine.cached(event) == nil)
    }

    @Test("Curve and outcome survive the meal event file, and events without them still decode")
    func storedRoundTrip() throws {
        let analysis = Engine.analyze(linkedEvent(), inputs: inputs(), now: later)
        var event = analysis.event
        event.curve = analysis.curve
        event.outcome = analysis.outcome

        let encoder = AIInsights.MealEventStore.makeEncoder()
        let decoder = AIInsights.MealEventStore.makeDecoder()
        let decoded = try decoder.decode(AIInsights.MealEvent.self, from: encoder.encode(event))
        #expect(decoded == event)

        let plain = try decoder.decode(AIInsights.MealEvent.self, from: encoder.encode(analysis.event))
        #expect(plain.curve == nil)
        #expect(plain.outcome == nil)
    }
}

@Suite("FoodFinder insulin a meal took") struct MealOutcomeNeedTests {
    private let iob = [
        Inputs.IOB(date: at(-4), units: 1),
        Inputs.IOB(date: at(120), units: 3),
        Inputs.IOB(date: at(241), units: 0.8)
    ]

    @Test("Needed insulin is what acted in the four hours when glucose ends where it started")
    func actedInsulin() {
        let event = withLoop(linkedEvent())
        let boluses = [bolus("meal-bolus", 1, 4), bolus("smb", 60, 0.5, smb: true)]
        let need = Engine.analyze(event, inputs: inputs(boluses: boluses, iob: iob), now: later).outcome.need

        #expect(need?.actedUnits == 4.7)
        #expect(need?.glucoseUnits == 0)
        #expect(need?.rescueUnits == 0)
        #expect(need?.neededUnits == 4.7)
        // 60 g at 10 g/U is 6 U.
        #expect(need?.mealFactor == 0.783)
        #expect(need?.unitsPer10g == 0.783)
    }

    @Test("Ending above the start adds insulin and rescue carbs take it away")
    func glucoseAndRescue() {
        // 50 mg/dL above the start at 4 h with an ISF of 50 is one more unit.
        let high = readings { minute in minute >= 180 ? 150 : triangle(minute) }
        let event = withLoop(linkedEvent())
        let boluses = [bolus("meal-bolus", 1, 4)]
        let raised = Engine.analyze(event, inputs: inputs(readings: high, boluses: boluses, iob: iob), now: later)
        #expect(raised.outcome.need?.glucoseUnits == 1)
        #expect(raised.outcome.need?.neededUnits == 5.2)

        // 20 g rescue carbs at 10 g/U made up for 2 units too many.
        let low = readings { minute in minute >= 150 && minute < 200 ? 65 : triangle(minute) }
        let rescue = [Inputs.Carbs(id: UUID(), date: at(160), grams: 20, isFPU: false)]
        let rescued = Engine.analyze(
            event,
            inputs: inputs(readings: low, boluses: boluses, carbs: rescue, iob: iob),
            now: later
        )
        #expect(rescued.outcome.need?.rescueUnits == 2)
        #expect(rescued.outcome.need?.neededUnits == 2.2)
    }

    @Test("No estimate without IOB around the meal and at four hours, or without an ISF")
    func missingInputs() {
        let event = withLoop(linkedEvent())
        #expect(Engine.analyze(event, inputs: inputs(), now: later).outcome.need == nil)
        let onlyStart = [Inputs.IOB(date: at(-4), units: 1)]
        #expect(Engine.analyze(event, inputs: inputs(iob: onlyStart), now: later).outcome.need == nil)
        #expect(Engine.analyze(linkedEvent(), inputs: inputs(iob: iob), now: later).outcome.need == nil)
    }

    @Test("An ISF in mmol/L per unit is converted to mg/dL")
    func mmolISF() {
        #expect(Engine.isfMgdl(withLoop(makeEvent(), isf: 2.5)) == 2.5 * Engine.mgdlPerMmol)
        #expect(Engine.isfMgdl(withLoop(makeEvent(), isf: 45)) == 45)
    }

    @Test("The portion estimate needs enough meals and scales with carbs")
    func portionEstimate() {
        var all: [AIInsights.MealEventAnalysis] = []
        for index in 0 ..< 5 {
            let day = mealTime.addingTimeInterval(TimeInterval(index) * 24 * 60 * 60)
            var analysis = Engine.analyze(
                makeEvent(mealTime: day),
                inputs: inputs(readings: readings(mealTime: day, triangle)),
                now: day.addingTimeInterval(8 * 60 * 60)
            )
            let needed = 4.0 + Double(index) * 0.5
            analysis.outcome.need = AIInsights.MealOutcomeNeed(
                actedUnits: needed,
                glucoseUnits: 0,
                rescueUnits: 0,
                neededUnits: needed,
                mealFactor: needed / 6,
                unitsPer10g: needed / 6,
                isfMgdl: 50,
                carbRatio: 10
            )
            all.append(analysis)
        }

        let summary = Summary.make(analyses: all, scale: .change, includeDisturbed: false)
        #expect(summary.needCount == 5)
        #expect(summary.medianNeeded == 5)
        #expect(summary.neededP25 == 4.5)
        #expect(summary.neededP75 == 5.5)
        #expect(summary.insulin.first?.needed == 4)
        #expect(abs((summary.neededEstimate(forCarbs: 90) ?? 0) - 7.5) < 0.0001)

        let four = Summary.make(analyses: Array(all.prefix(4)), scale: .change, includeDisturbed: false)
        #expect(four.neededEstimate(forCarbs: 90) == nil)
    }
}

@Suite("FoodFinder meal response summary") struct MealResponseSummaryTests {
    private func analyses(_ count: Int, rise: (Int) -> Int = { 40 + $0 * 5 }) -> [AIInsights.MealEventAnalysis] {
        (0 ..< count).map { index in
            let day = mealTime.addingTimeInterval(TimeInterval(index) * 24 * 60 * 60)
            let peak = rise(index)
            let glucose = readings(mealTime: day) { minute in
                minute <= 0 ? 110 : 110 + peak * min(minute, 60) / 60
            }
            return Engine.analyze(
                makeEvent(mealTime: day),
                inputs: inputs(readings: glucose),
                now: day.addingTimeInterval(8 * 60 * 60)
            )
        }
    }

    @Test("Percentiles interpolate between ranks")
    func percentiles() {
        let values: [Double] = [10, 20, 30, 40, 50]
        #expect(Summary.percentile(values, 0.5) == 30)
        #expect(Summary.percentile(values, 0.25) == 20)
        #expect(Summary.percentile(values, 0.1) == 14)
        #expect(Summary.percentile([7], 0.9) == 7)
        #expect(Summary.median([4, 1, 3, 2]) == 2.5)
        #expect(Summary.median([]) == nil)
    }

    @Test("Style follows the number of meals: single, lines, band, wide band")
    func styles() {
        #expect(Summary.make(analyses: [], scale: .change, includeDisturbed: false).style == .empty)
        #expect(Summary.make(analyses: analyses(1), scale: .change, includeDisturbed: false).style == .single)

        let three = Summary.make(analyses: analyses(3), scale: .change, includeDisturbed: false)
        #expect(three.style == .lines)
        #expect(three.band.isEmpty)
        #expect(three.curves.filter(\.isLatest).count == 1)

        let five = Summary.make(analyses: analyses(5), scale: .change, includeDisturbed: false)
        #expect(five.style == .band)
        #expect(!five.band.isEmpty)
        #expect(five.band.allSatisfy { $0.p10 == nil })

        let ten = Summary.make(analyses: analyses(10), scale: .change, includeDisturbed: false)
        #expect(ten.band.contains { $0.p10 != nil && $0.p90 != nil })
    }

    @Test("The change scale lines meals up at their baseline")
    func changeScale() {
        let summary = Summary.make(analyses: analyses(5), scale: .change, includeDisturbed: false)
        let atMeal = summary.band.first { $0.minute == 0 }
        #expect(atMeal?.median == 0)
        // Rises of 40, 45, 50, 55 and 60 reach their peak at one hour.
        let atPeak = summary.band.first { $0.minute == 60 }
        #expect(atPeak?.median == 50)
        #expect(atPeak?.p25 == 45)
        #expect(atPeak?.p75 == 55)
        #expect(summary.medianRise == 50)
        #expect(summary.medianPeakMinute == 60)
        #expect(summary.includedCount == 5)

        let absolute = Summary.make(analyses: analyses(5), scale: .absolute, includeDisturbed: false)
        #expect(absolute.band.first { $0.minute == 60 }?.median == 160)
    }

    @Test("Disturbed meals are drawn but left out of the numbers unless included")
    func disturbedMeals() {
        var all = analyses(5)
        all[0].outcome.flags.mealAfter = true
        all[1].outcome.flags.lowCoverage = true

        let clean = Summary.make(analyses: all, scale: .change, includeDisturbed: false)
        #expect(clean.totalCount == 5)
        #expect(clean.includedCount == 3)
        #expect(clean.style == .lines)
        #expect(clean.leftOut.mealAfter == 1)
        #expect(clean.leftOut.lowCoverage == 1)
        #expect(clean.curves.filter { !$0.isIncluded }.count == 2)
        #expect(clean.insulin.count == 5)
        #expect(clean.insulin.filter(\.isIncluded).count == 3)

        let everything = Summary.make(analyses: all, scale: .change, includeDisturbed: true)
        #expect(everything.includedCount == 5)
        #expect(everything.style == .band)
        #expect(everything.leftOut.isEmpty)
    }

    @Test("Insulin numbers come from the included meals")
    func insulinNumbers() {
        var all = analyses(3)
        all[0].outcome.insulin.correctionUnits = 1
        all[2].outcome.insulin.correctionUnits = 2
        all[1].outcome.firstLowMinute = 180
        let summary = Summary.make(analyses: all, scale: .change, includeDisturbed: false)
        #expect(summary.correctionCount == 2)
        #expect(summary.medianCorrectionUnits == 1.5)
        #expect(summary.lowCount == 1)
        #expect(summary.insulin.first?.recommended == 4)
    }

    @Test("Response keys give one meal id for every result of the same meal")
    func responseKeys() {
        let first = AIInsights.FoodAnalysisResult(
            items: [],
            rawResponse: nil,
            timestamp: mealTime,
            source: .aiCamera,
            mealName: "Pasta Pesto"
        )
        let second = AIInsights.FoodAnalysisResult(
            items: [],
            rawResponse: nil,
            timestamp: later,
            source: .aiCamera,
            mealName: "pasta  pesto"
        )
        let keys = AIInsights.MealResponseKeys(results: [first, second])
        #expect(keys.mealIDs.count == 1)
        #expect(keys.foodResultIDs == [first.id, second.id])
    }
}
