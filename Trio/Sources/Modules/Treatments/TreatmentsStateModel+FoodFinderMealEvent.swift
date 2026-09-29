import Foundation

extension Treatments.StateModel {
    /// Records the FoodFinder meal this calculator was opened with, once its carb entry is stored.
    @MainActor func recordFoodFinderMealEvent(fpuID: String?) {
        guard let handoff = foodFinderHandoff else { return }
        foodFinderHandoff = nil
        let draft = makeFoodFinderMealEventDraft(handoff: handoff, fpuID: fpuID.flatMap { UUID(uuidString: $0) })
        foodFinderMealEventID = draft.id
        AIInsights.MealEventRecorder.shared.record(draft)
    }

    /// Tells the recorder that the bolus for the recorded meal is being given. For a pump bolus, returns the
    /// callback that reports whether the pump accepted it.
    @MainActor @discardableResult func requestFoodFinderMealEventBolus(
        units: Double,
        kind: AIInsights.MealEventBolus.Kind,
        at date: Date
    ) -> (@Sendable (Bool, String) -> Void)? {
        guard let eventID = foodFinderMealEventID else { return nil }
        foodFinderMealEventID = nil
        let recorder = AIInsights.MealEventRecorder.shared
        recorder.requestBolus(eventID: eventID, units: units, kind: kind, at: date)
        guard kind == .pump else { return nil }
        return { success, _ in
            recorder.bolusEnactFinished(eventID: eventID, success: success, at: Date())
        }
    }

    @MainActor private func makeFoodFinderMealEventDraft(
        handoff: AIInsights.FoodBolusHandoff,
        fpuID: UUID?
    ) -> AIInsights.MealEventDraft {
        let id = UUID()
        let mealKey = handoff.mealKey ?? AIInsights.MealEventIdentity.mealKey(
            mealName: handoff.mealName,
            itemNames: [handoff.note],
            resultID: handoff.foodResultID ?? id
        )
        let carbs = Double(self.carbs)
        let fat = Double(self.fat)
        let protein = Double(self.protein)
        let entered = Double(amount)
        let recommended = Double(insulinCalculated)

        return AIInsights.MealEventDraft(
            id: id,
            recordedAt: Date(),
            mealTime: date,
            mealSlot: AIInsights.MealSlot.from(date: date),
            meal: AIInsights.MealEventMeal(
                mealID: AIInsights.MealEventIdentity.mealID(forKey: mealKey),
                mealKey: mealKey,
                name: handoff.mealName ?? handoff.note,
                foodResultID: handoff.foodResultID,
                analysisAt: handoff.analysisAt,
                source: handoff.source,
                photoEngine: handoff.photoEngine,
                portionMultiplier: handoff.portionMultiplier
            ),
            nutrition: AIInsights.MealEventNutrition(
                carbs: carbs,
                fat: fat,
                protein: protein,
                fpu: AIInsights.MealEventNutrition.fpu(fat: fat, protein: protein),
                fiber: handoff.fiber,
                kcal: handoff.calories,
                foodFinderCarbs: handoff.carbs,
                foodFinderFat: handoff.fat,
                foodFinderProtein: handoff.protein,
                carbLowerRatio: handoff.carbLowerRatio,
                carbUpperRatio: handoff.carbUpperRatio
            ),
            fpuID: fpuID,
            calculator: AIInsights.MealEventCalculator(
                wholeUnits: Double(wholeCalc),
                factoredUnits: Double(factoredInsulin),
                recommendedUnits: recommended,
                fraction: Double(fraction),
                usedFattyMealFactor: useFattyMealCorrectionFactor,
                fattyMealFactor: fattyMeals ? Double(fattyMealFactor) : nil,
                usedSuperBolus: useSuperBolus,
                superBolusUnits: useSuperBolus ? Double(superBolusInsulin) : nil,
                reducedBolusSuggested: handoff.useReducedBolus,
                enteredUnits: entered,
                amountSource: AIInsights.MealEventCalculator.amountSource(entered: entered, recommended: recommended),
                isExternalInsulin: externalInsulin,
                currentBG: Self.known(currentBG),
                deltaBG: Self.known(currentBG) == nil ? nil : Double(deltaBG),
                iob: Double(iob),
                cob: Double(cob),
                target: Self.known(target),
                isf: Self.known(isf),
                carbRatio: Self.known(carbRatio),
                minPredBG: Self.known(minPredBG),
                eventualBG: Self.known(evBG),
                targetDifferenceUnits: Double(targetDifferenceInsulin),
                iobReductionUnits: Double(iobInsulinReduction),
                cobUnits: Double(wholeCobInsulin),
                fifteenMinuteUnits: Double(fifteenMinInsulin)
            ),
            dosingMode: dosingMode.rawValue
        )
    }

    /// The calculator shows 0 for a glucose, target or ratio it has no value for.
    private static func known(_ value: Decimal) -> Double? {
        value > 0 ? Double(value) : nil
    }
}
