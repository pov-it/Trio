import Foundation
import Observation
import Swinject

extension AIInsights {
    // MARK: - FoodFinder Data Types

    struct FoodItem: Identifiable, Codable {
        var id: UUID = UUID()
        var name: String
        var portion: String
        var carbs: Double
        var fat: Double
        var protein: Double
        var fiber: Double
        var calories: Double
        var portionMultiplier: Double = 1.0

        var adjustedCarbs: Double { carbs * portionMultiplier }
        var adjustedCalories: Double { calories * portionMultiplier }
    }

    struct FoodAnalysisResult: Identifiable, Codable {
        var id: UUID = UUID()
        let items: [FoodItem]
        let rawResponse: String?
        let timestamp: Date
        let source: FoodSource

        var totalCarbs: Double { items.reduce(0) { $0 + $1.adjustedCarbs } }
        var totalCalories: Double { items.reduce(0) { $0 + $1.adjustedCalories } }

        enum FoodSource: String, Codable {
            case aiText
            case aiVoice
            case aiCamera
            case barcode
        }
    }

    // MARK: - FoodFinder State Model

    @Observable final class FoodFinderStateModel: BaseStateModel<Provider> {
        var isAnalyzing: Bool = false
        var errorMessage: String?
        var currentResult: FoodAnalysisResult?
        var foodDescription: String = ""
        var recentResults: [FoodAnalysisResult] = []
        var showCamera: Bool = false
        var showBarcodeScanner: Bool = false
        var capturedImageData: Data?

        // Shared AI config
        var apiKey: String = ""
        var providerType: AIProvider = .google
        var model: String = AIProvider.google.defaultModel
        var baseURL: String = AIProvider.google.defaultEndpoint
        var aiEnabled: Bool = false

        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }

            providerType = provider.settings.aiProvider
            model = provider.settings.aiModel
            baseURL = provider.settings.aiBaseURL
            aiEnabled = provider.settings.aiEnabled

            loadRecentResults()
        }

        // MARK: - Persistence

        func loadRecentResults() {
            if let data = UserDefaults.standard.data(forKey: "ai_foodfinder_recent"),
               let saved = try? JSONDecoder().decode([FoodAnalysisResult].self, from: data)
            {
                recentResults = saved
            }
        }

        func saveRecentResults() {
            // Keep last 20 results
            let toSave = Array(recentResults.prefix(20))
            if let data = try? JSONEncoder().encode(toSave) {
                UserDefaults.standard.set(data, forKey: "ai_foodfinder_recent")
            }
        }

        // MARK: - Text Analysis

        @MainActor
        func analyzeFood(description: String) async {
            guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            guard provider != nil else {
                errorMessage = String(localized: "AI Insights is not ready yet.", comment: "AI error")
                return
            }
            guard !apiKey.isEmpty else {
                errorMessage = String(localized: "API Key is missing. Configure it in AI Settings.", comment: "AI error")
                return
            }

            isAnalyzing = true
            errorMessage = nil
            defer { isAnalyzing = false }

            do {
                let request = AIServiceAdapter.AIRequest(
                    model: model,
                    messages: [
                        AIServiceAdapter.ChatMessagePayload(role: .system, content: foodFinderSystemPrompt),
                        AIServiceAdapter.ChatMessagePayload(role: .user, content: "Analyze this food: \(description)")
                    ],
                    temperature: 0.2,
                    topP: 0.9,
                    topK: nil,
                    maxTokens: 2048
                )

                let response = try await AIServiceAdapter.send(
                    request: request,
                    provider: providerType,
                    baseURL: baseURL,
                    apiKey: apiKey
                )

                let items = parseFoodItems(from: response.text)

                let result = FoodAnalysisResult(
                    items: items,
                    rawResponse: response.text,
                    timestamp: Date(),
                    source: .aiText
                )

                currentResult = result
                recentResults.insert(result, at: 0)
                saveRecentResults()
                foodDescription = ""

            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        // MARK: - Prompt Engineering

        private var foodFinderSystemPrompt: String {
            let unitsStr = provider?.units.rawValue ?? "mg/dL"
            return """
            You are a precise nutritional analysis assistant for a person with Type 1 Diabetes using the Trio (OpenAPS) insulin pump system.
            The user's glucose unit preference is \(unitsStr).

            When given a food description, respond ONLY with a valid JSON array of food items:
            [
              {
                "name": "Brown Rice",
                "portion": "1 cup (195g)",
                "carbs": 45.0,
                "fat": 1.8,
                "protein": 5.0,
                "fiber": 3.5,
                "calories": 216
              }
            ]

            RULES:
            - Be as accurate as possible with carb counts — this directly affects insulin dosing
            - Break compound meals into individual items (e.g. "burger and fries" → separate items)
            - Use standard serving sizes when portions are not specified
            - Include fiber separately — the user's pump system can use net carbs
            - If you cannot identify the food, respond with: [{"name":"Unknown","portion":"Unknown","carbs":0,"fat":0,"protein":0,"fiber":0,"calories":0}]
            - Respond ONLY with the JSON array. No markdown, no explanation outside the JSON.
            """
        }

        // MARK: - Response Parsing

        private func parseFoodItems(from text: String) -> [FoodItem] {
            let cleaned = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = cleaned.data(using: .utf8) else { return [] }

            struct RawItem: Codable {
                let name: String
                let portion: String
                let carbs: Double
                let fat: Double
                let protein: Double
                let fiber: Double
                let calories: Double
            }

            guard let raw = try? JSONDecoder().decode([RawItem].self, from: data) else {
                return [FoodItem(
                    name: String(localized: "Could not parse", comment: "FoodFinder parse error"),
                    portion: "—",
                    carbs: 0,
                    fat: 0,
                    protein: 0,
                    fiber: 0,
                    calories: 0
                )]
            }

            return raw.map { r in
                FoodItem(
                    name: r.name,
                    portion: r.portion,
                    carbs: r.carbs,
                    fat: r.fat,
                    protein: r.protein,
                    fiber: r.fiber,
                    calories: r.calories
                )
            }
        }

        // MARK: - Helpers

        func updatePortion(for itemId: UUID, multiplier: Double) {
            guard var result = currentResult,
                  let idx = result.items.firstIndex(where: { $0.id == itemId })
            else { return }
            var items = result.items
            items[idx].portionMultiplier = max(0.25, multiplier)
            currentResult = FoodAnalysisResult(
                id: result.id,
                items: items,
                rawResponse: result.rawResponse,
                timestamp: result.timestamp,
                source: result.source
            )
        }

        func removeItem(_ itemId: UUID) {
            guard let result = currentResult else { return }
            let filtered = result.items.filter { $0.id != itemId }
            currentResult = FoodAnalysisResult(
                id: result.id,
                items: filtered,
                rawResponse: result.rawResponse,
                timestamp: result.timestamp,
                source: result.source
            )
        }

        func clearResult() {
            currentResult = nil
            errorMessage = nil
        }

        // MARK: - Camera Analysis (Multimodal)

        @MainActor
        func analyzeImage(_ imageData: Data) async {
            guard provider != nil else {
                errorMessage = String(localized: "AI Insights is not ready yet.", comment: "AI error")
                return
            }
            guard !apiKey.isEmpty else {
                errorMessage = String(localized: "API Key is missing. Configure it in AI Settings.", comment: "AI error")
                return
            }

            isAnalyzing = true
            errorMessage = nil
            defer { isAnalyzing = false }

            do {
                let request = AIServiceAdapter.AIRequest(
                    model: model,
                    messages: [
                        AIServiceAdapter.ChatMessagePayload(role: .system, content: foodFinderSystemPrompt),
                        AIServiceAdapter.ChatMessagePayload(role: .user, content: "Analyze the food in this photo. Identify each item and provide the nutritional breakdown.")
                    ],
                    temperature: 0.2,
                    topP: 0.9,
                    topK: nil,
                    maxTokens: 2048,
                    imageData: imageData
                )

                let response = try await AIServiceAdapter.send(
                    request: request,
                    provider: providerType,
                    baseURL: baseURL,
                    apiKey: apiKey
                )

                let items = parseFoodItems(from: response.text)
                let result = FoodAnalysisResult(
                    items: items,
                    rawResponse: response.text,
                    timestamp: Date(),
                    source: .aiCamera
                )
                currentResult = result
                recentResults.insert(result, at: 0)
                saveRecentResults()

            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        // MARK: - Barcode Lookup (OpenFoodFacts)

        @MainActor
        func lookupBarcode(_ barcode: String) async {
            isAnalyzing = true
            errorMessage = nil
            defer { isAnalyzing = false }

            do {
                let urlString = "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=product_name,nutriments,serving_size"
                guard let url = URL(string: urlString) else {
                    errorMessage = String(localized: "Invalid barcode.", comment: "Barcode error")
                    return
                }

                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    errorMessage = String(localized: "Product not found in OpenFoodFacts.", comment: "Barcode error")
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? Int, status == 1,
                      let product = json["product"] as? [String: Any]
                else {
                    errorMessage = String(localized: "Product not found. Try the AI Camera instead.", comment: "Barcode error")
                    return
                }

                let name = product["product_name"] as? String ?? "Unknown Product"
                let serving = product["serving_size"] as? String ?? "1 serving"
                let nutriments = product["nutriments"] as? [String: Any] ?? [:]

                let carbs = nutriments["carbohydrates_serving"] as? Double
                    ?? nutriments["carbohydrates_100g"] as? Double ?? 0
                let fat = nutriments["fat_serving"] as? Double
                    ?? nutriments["fat_100g"] as? Double ?? 0
                let protein = nutriments["proteins_serving"] as? Double
                    ?? nutriments["proteins_100g"] as? Double ?? 0
                let fiber = nutriments["fiber_serving"] as? Double
                    ?? nutriments["fiber_100g"] as? Double ?? 0
                let calories = nutriments["energy-kcal_serving"] as? Double
                    ?? nutriments["energy-kcal_100g"] as? Double ?? 0

                let item = FoodItem(
                    name: name,
                    portion: serving,
                    carbs: carbs,
                    fat: fat,
                    protein: protein,
                    fiber: fiber,
                    calories: calories
                )

                let result = FoodAnalysisResult(
                    items: [item],
                    rawResponse: nil,
                    timestamp: Date(),
                    source: .barcode
                )
                currentResult = result
                recentResults.insert(result, at: 0)
                saveRecentResults()

            } catch {
                errorMessage = String(localized: "Network error looking up barcode: \(error.localizedDescription)", comment: "Barcode error")
            }
        }
    }
}
