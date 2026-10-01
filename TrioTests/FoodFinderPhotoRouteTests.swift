import Foundation
import Testing

@testable import Trio

@Suite("FoodFinder meal-photo comparison")
struct FoodFinderPhotoRouteTests {
    @Test("Identical macros and the same name agree completely")
    func identicalEstimates() {
        let macros = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Rice",
            carbs: 40,
            fat: 2,
            protein: 4,
            calories: 200
        )
        #expect(AIInsights.FoodFinderPhotoAgreement.percent(macros, macros) == 100)
    }

    @Test("A 40 g versus 50 g carb gap with the rest equal scores 92")
    func carbGapExample() {
        let onDevice = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Rice",
            carbs: 40,
            fat: 2,
            protein: 4,
            calories: 200
        )
        let gemini = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Rice",
            carbs: 50,
            fat: 2,
            protein: 4,
            calories: 200
        )
        #expect(AIInsights.FoodFinderPhotoAgreement.percent(onDevice, gemini) == 92)
    }

    @Test("Carbs of 0 g versus 40 g with the rest equal scores 60")
    func totalCarbDisagreement() {
        let onDevice = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Rice",
            carbs: 0,
            fat: 2,
            protein: 4,
            calories: 200
        )
        let gemini = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Rice",
            carbs: 40,
            fat: 2,
            protein: 4,
            calories: 200
        )
        #expect(AIInsights.FoodFinderPhotoAgreement.percent(onDevice, gemini) == 60)
    }

    @Test("Values inside the gram and calorie floors count as a match")
    func nearZeroMacrosAgree() {
        let onDevice = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Water",
            carbs: 0,
            fat: 0,
            protein: 0,
            calories: 0
        )
        let gemini = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Water",
            carbs: 0.5,
            fat: 1,
            protein: 1,
            calories: 10
        )
        #expect(AIInsights.FoodFinderPhotoAgreement.percent(onDevice, gemini) == 100)
    }

    @Test("A missing meal name moves the name weight onto carbs")
    func emptyNameShiftsWeight() {
        let onDevice = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "",
            carbs: 40,
            fat: 2,
            protein: 4,
            calories: 200
        )
        let gemini = AIInsights.FoodFinderPhotoAgreement.Macros(
            name: "Rice",
            carbs: 50,
            fat: 2,
            protein: 4,
            calories: 200
        )
        #expect(AIInsights.FoodFinderPhotoAgreement.percent(onDevice, gemini) == 90)
    }

    @Test("Both ready estimates log Gemini and publish agreement")
    func bothReadyAdoptsGemini() {
        let comparison = AIInsights.FoodFinderPhotoComparison.make(
            onDevice: side(name: "Rice", carbs: 40),
            gemini: side(name: "Rice", carbs: 50)
        )
        #expect(comparison?.adoptedEngine == .gemini)
        #expect(comparison?.agreementPercent == 92)
        #expect(comparison?.onDevice.outcome == .ready)
        #expect(comparison?.gemini.outcome == .ready)
    }

    @Test("A missing Gemini estimate logs the on-device side and leaves agreement unset")
    func geminiUnavailable() {
        let comparison = AIInsights.FoodFinderPhotoComparison.make(
            onDevice: side(name: "Rice", carbs: 40),
            gemini: .unavailable("API Key is missing. Configure it in AI Settings.")
        )
        #expect(comparison?.adoptedEngine == .onDevice)
        #expect(comparison?.agreementPercent == nil)
        #expect(comparison?.gemini.outcome == .unavailable)
    }

    @Test("A missing on-device model still logs Gemini")
    func onDeviceUnavailable() {
        let comparison = AIInsights.FoodFinderPhotoComparison.make(
            onDevice: .unavailable("The on-device model is still downloading."),
            gemini: side(name: "Rice", carbs: 50)
        )
        #expect(comparison?.adoptedEngine == .gemini)
        #expect(comparison?.agreementPercent == nil)
        #expect(comparison?.onDevice.outcome == .unavailable)
    }

    @Test("Two failed estimates do not produce a meal comparison")
    func bothFailed() {
        let comparison = AIInsights.FoodFinderPhotoComparison.make(
            onDevice: .failed("On-device meal analysis failed."),
            gemini: .failed("Gemini did not return an estimate.")
        )
        #expect(comparison == nil)
    }

    @Test("Gemini is logged while on-device is still running, and agreement follows when it finishes")
    func geminiFirstThenOnDevice() {
        var comparison = AIInsights.FoodFinderPhotoComparison.make(
            onDevice: .pending,
            gemini: side(name: "Rice", carbs: 50)
        )
        #expect(comparison?.adoptedEngine == .gemini)
        #expect(comparison?.agreementPercent == nil)
        #expect(comparison?.onDevice.outcome == .pending)

        comparison?.completeOnDevice(side(name: "Rice", carbs: 40))
        #expect(comparison?.onDevice.outcome == .ready)
        #expect(comparison?.agreementPercent == 92)
        #expect(comparison?.adoptedEngine == .gemini)

        comparison?.completeOnDevice(.failed("On-device meal analysis failed."))
        #expect(comparison?.agreementPercent == nil)
    }

    @Test("A side still running when the app stopped is settled as not finished")
    func settlesInterruptedSide() {
        var comparison = AIInsights.FoodFinderPhotoComparison.make(
            onDevice: .pending,
            gemini: side(name: "Rice", carbs: 50)
        )
        #expect(comparison?.settleInterruptedSides() == true)
        #expect(comparison?.onDevice.outcome == .failed)
        #expect(comparison?.settleInterruptedSides() == false)
    }

    @Test("On-device JSON matches the FoodFinder meal schema")
    func onDeviceJSONShape() {
        let estimate = AIInsights.FoodFinderOnDeviceEstimate(
            mealName: "Pasta",
            mealPortion: "1 plate (400 g)",
            confidence: 0.5,
            items: [
                AIInsights.FoodFinderOnDeviceEstimate.Item(
                    name: "Spaghetti",
                    portion: "1 serving (250 g)",
                    carbs: 70,
                    fat: 2,
                    protein: 12,
                    fiber: 4,
                    calories: 380
                )
            ],
            rawJSON: ""
        )
        let text = AIInsights.FoodFinderOnDeviceJSON.string(from: estimate)
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let items = object?["items"] as? [[String: Any]]
        #expect(object?["mealName"] as? String == "Pasta")
        #expect(object?["mealPortion"] as? String == "1 plate (400 g)")
        #expect(object?["confidence"] as? Double == 0.5)
        #expect(items?.count == 1)
        #expect(items?.first?["name"] as? String == "Spaghetti")
        #expect(items?.first?["portion"] as? String == "1 serving (250 g)")
        #expect(items?.first?["carbs"] as? Double == 70)
        #expect(items?.first?["fat"] as? Double == 2)
        #expect(items?.first?["protein"] as? Double == 12)
        #expect(items?.first?["fiber"] as? Double == 4)
        #expect(items?.first?["calories"] as? Double == 380)
    }

    @Test("Macro numbers stay non-negative and blank names are dropped")
    func numberCleanup() {
        #expect(AIInsights.FoodFinderOnDeviceNumbers.grams(-4) == 0)
        #expect(AIInsights.FoodFinderOnDeviceNumbers.grams(.nan) == 0)
        #expect(AIInsights.FoodFinderOnDeviceNumbers.confidence(82) == 0.82)
        #expect(AIInsights.FoodFinderOnDeviceNumbers.confidence(1.4) == 1)
        let item = AIInsights.FoodFinderOnDeviceNumbers.item(
            name: "  Rice ",
            portion: " ",
            carbs: 40,
            fat: -1,
            protein: 3,
            fiber: 1,
            calories: 180
        )
        #expect(item?.name == "Rice")
        #expect(item?.portion == "1 serving")
        #expect(item?.fat == 0)
        #expect(
            AIInsights.FoodFinderOnDeviceNumbers.item(
                name: "   ",
                portion: "1",
                carbs: 1,
                fat: 1,
                protein: 1,
                fiber: 1,
                calories: 1
            ) == nil
        )
    }

    @Test("Saved meals without a photo engine still decode")
    func legacyResultDecodes() throws {
        let result = AIInsights.FoodAnalysisResult(
            items: [],
            rawResponse: nil,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .aiCamera,
            photoEngine: .onDevice
        )
        let data = try JSONEncoder().encode(result)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "photoEngine")
        object.removeValue(forKey: "photoComparison")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AIInsights.FoodAnalysisResult.self, from: stripped)
        #expect(decoded.photoEngine == nil)
        #expect(decoded.photoComparison == nil)
        #expect(decoded.source == .aiCamera)
    }

    private func side(name: String, carbs: Double) -> AIInsights.FoodFinderPhotoSide {
        .ready(
            mealName: name,
            mealPortion: "1 serving",
            items: [
                AIInsights.FoodItem(
                    name: name,
                    portion: "1 serving",
                    carbs: carbs,
                    fat: 2,
                    protein: 4,
                    fiber: 0,
                    calories: 200
                )
            ]
        )
    }
}
