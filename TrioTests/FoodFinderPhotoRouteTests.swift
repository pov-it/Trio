import Foundation
import Testing

@testable import Trio

@Suite("FoodFinder meal-photo routing")
struct FoodFinderPhotoRouteTests {
    @Test("Automatic uses on-device when Apple Intelligence is ready")
    func automaticPrefersOnDevice() {
        let route = AIInsights.FoodFinderPhotoRouter.route(
            preference: .automatic,
            onDeviceAvailable: true,
            geminiConfigured: true
        )
        #expect(route == .onDevice)
    }

    @Test("Automatic keeps Gemini when the on-device model is missing")
    func automaticFallsThroughToGemini() {
        let unavailable = AIInsights.FoodFinderPhotoRouter.route(
            preference: .automatic,
            onDeviceAvailable: false,
            geminiConfigured: true
        )
        #expect(unavailable == .gemini)
    }

    @Test("Automatic still tries on-device when Gemini is not configured")
    func automaticWithoutGeminiKey() {
        let route = AIInsights.FoodFinderPhotoRouter.route(
            preference: .automatic,
            onDeviceAvailable: true,
            geminiConfigured: false
        )
        #expect(route == .onDevice)
        #expect(
            AIInsights.FoodFinderPhotoRouter.fallsBackToGemini(
                preference: .automatic,
                geminiConfigured: false
            ) == false
        )
    }

    @Test("Automatic with neither engine reports both missing")
    func automaticWithNothing() {
        let route = AIInsights.FoodFinderPhotoRouter.route(
            preference: .automatic,
            onDeviceAvailable: false,
            geminiConfigured: false
        )
        #expect(route == .blocked(.neitherAvailable))
    }

    @Test("Gemini preference ignores a ready on-device model")
    func cloudPreference() {
        let ready = AIInsights.FoodFinderPhotoRouter.route(
            preference: .cloud,
            onDeviceAvailable: true,
            geminiConfigured: true
        )
        let missingKey = AIInsights.FoodFinderPhotoRouter.route(
            preference: .cloud,
            onDeviceAvailable: true,
            geminiConfigured: false
        )
        #expect(ready == .gemini)
        #expect(missingKey == .blocked(.geminiNotConfigured))
    }

    @Test("On this iPhone does not call Gemini when the model is missing")
    func onDevicePreference() {
        let ready = AIInsights.FoodFinderPhotoRouter.route(
            preference: .onDevice,
            onDeviceAvailable: true,
            geminiConfigured: true
        )
        let missing = AIInsights.FoodFinderPhotoRouter.route(
            preference: .onDevice,
            onDeviceAvailable: false,
            geminiConfigured: true
        )
        #expect(ready == .onDevice)
        #expect(missing == .blocked(.onDeviceUnavailable))
        #expect(
            AIInsights.FoodFinderPhotoRouter.fallsBackToGemini(
                preference: .onDevice,
                geminiConfigured: true
            ) == false
        )
    }

    @Test("A failed on-device attempt may use Gemini in automatic mode")
    func generationFailureFallsBack() {
        #expect(
            AIInsights.FoodFinderPhotoRouter.fallsBackToGemini(
                preference: .automatic,
                geminiConfigured: true
            )
        )
        #expect(
            AIInsights.FoodFinderPhotoRouter.fallsBackToGemini(
                preference: .cloud,
                geminiConfigured: true
            )
        )
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
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AIInsights.FoodAnalysisResult.self, from: stripped)
        #expect(decoded.photoEngine == nil)
        #expect(decoded.source == .aiCamera)
    }
}
