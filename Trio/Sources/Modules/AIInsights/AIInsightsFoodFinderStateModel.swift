import AVFoundation
import Foundation
import Observation
import Speech
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
        var adjustedFat: Double { fat * portionMultiplier }
        var adjustedProtein: Double { protein * portionMultiplier }
        var adjustedFiber: Double { fiber * portionMultiplier }
        var adjustedCalories: Double { calories * portionMultiplier }
    }

    struct FoodAnalysisResult: Identifiable, Codable {
        var id: UUID = UUID()
        var items: [FoodItem]
        let rawResponse: String?
        let timestamp: Date
        let source: FoodSource

        var totalCarbs: Double { items.reduce(0) { $0 + $1.adjustedCarbs } }
        var totalFat: Double { items.reduce(0) { $0 + $1.adjustedFat } }
        var totalProtein: Double { items.reduce(0) { $0 + $1.adjustedProtein } }
        var totalFiber: Double { items.reduce(0) { $0 + $1.adjustedFiber } }
        var totalCalories: Double { items.reduce(0) { $0 + $1.adjustedCalories } }

        enum FoodSource: String, Codable {
            case aiText
            case aiVoice
            case aiCamera
            case barcode
        }
    }

    enum FoodMacro: String, CaseIterable, Identifiable {
        case carbs
        case fat
        case protein
        case fiber
        case calories

        var id: String { rawValue }
    }

    struct FoodBolusHandoff: Codable {
        static let userDefaultsKey = "ai_foodfinder_pending_bolus_handoff"

        let carbs: Double
        let fat: Double
        let protein: Double
        let note: String
        let createdAt: Date

        static func store(_ handoff: FoodBolusHandoff) {
            if let data = try? JSONEncoder().encode(handoff) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        }

        static func consume() -> FoodBolusHandoff? {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let handoff = try? JSONDecoder().decode(FoodBolusHandoff.self, from: data)
            else {
                return nil
            }
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            return handoff
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
        var isDictating: Bool = false

        // Shared AI config
        var apiKey: String = ""
        var providerType: AIProvider = .google
        var model: String = AIProvider.google.defaultModel
        var baseURL: String = AIProvider.google.defaultEndpoint
        var aiEnabled: Bool = false
        var openFoodFactsBaseURL: String = AIInsights.defaultOpenFoodFactsBaseURL

        @ObservationIgnored private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        @ObservationIgnored private let audioEngine = AVAudioEngine()
        @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
        @ObservationIgnored private var hasAudioTap = false

        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }

            providerType = provider.settings.aiProvider
            model = provider.settings.aiModel
            baseURL = provider.settings.aiBaseURL
            aiEnabled = provider.settings.aiEnabled
            openFoodFactsBaseURL = provider.settings.openFoodFactsBaseURL

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
        func analyzeCurrentInput() async {
            let description = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if let imageData = capturedImageData {
                await analyzeImage(imageData, description: description)
            } else {
                await analyzeFood(description: description)
            }
        }

        func attachImage(_ imageData: Data) {
            capturedImageData = imageData
        }

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
                capturedImageData = nil

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
            guard let jsonText = extractJSONFragment(from: text),
                  let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return []
            }

            let rawItems: [[String: Any]]
            if let array = json as? [[String: Any]] {
                rawItems = array
            } else if let object = json as? [String: Any],
                      let items = object["items"] as? [[String: Any]]
            {
                rawItems = items
            } else {
                rawItems = []
            }

            return rawItems.map { item in
                FoodItem(
                    name: stringValue(item["name"], fallback: String(localized: "Unknown", comment: "Unknown food item")),
                    portion: stringValue(item["portion"] ?? item["serving"], fallback: "1 serving"),
                    carbs: doubleValue(item["carbs"] ?? item["carbohydrates"]),
                    fat: doubleValue(item["fat"]),
                    protein: doubleValue(item["protein"] ?? item["proteins"]),
                    fiber: doubleValue(item["fiber"] ?? item["fibre"]),
                    calories: doubleValue(item["calories"] ?? item["kcal"] ?? item["energy_kcal"])
                )
            }
        }

        // MARK: - Helpers

        func updatePortion(for itemId: UUID, multiplier: Double) {
            guard var result = currentResult,
                  let idx = result.items.firstIndex(where: { $0.id == itemId })
            else { return }
            result.items[idx].portionMultiplier = max(0.25, multiplier)
            currentResult = result
        }

        func updateMacro(for itemId: UUID, macro: FoodMacro, adjustedValue: Double) {
            guard var result = currentResult,
                  let idx = result.items.firstIndex(where: { $0.id == itemId })
            else { return }

            let multiplier = max(result.items[idx].portionMultiplier, 0.25)
            let baseValue = max(0, adjustedValue) / multiplier

            switch macro {
            case .carbs:
                result.items[idx].carbs = baseValue
            case .fat:
                result.items[idx].fat = baseValue
            case .protein:
                result.items[idx].protein = baseValue
            case .fiber:
                result.items[idx].fiber = baseValue
            case .calories:
                result.items[idx].calories = baseValue
            }

            currentResult = result
        }

        func removeItem(_ itemId: UUID) {
            guard var result = currentResult else { return }
            result.items.removeAll { $0.id == itemId }
            currentResult = result
        }

        func discardCapturedImage() {
            capturedImageData = nil
        }

        func clearResult() {
            currentResult = nil
            errorMessage = nil
            capturedImageData = nil
            foodDescription = ""
        }

        func sendToBolusCalculator() {
            guard let result = currentResult else { return }
            let itemNames = result.items.map(\.name).joined(separator: ", ")
            let handoff = FoodBolusHandoff(
                carbs: result.totalCarbs,
                fat: result.totalFat,
                protein: result.totalProtein,
                note: itemNames.isEmpty ? "FoodFinder" : itemNames,
                createdAt: Date()
            )
            FoodBolusHandoff.store(handoff)
            showModal(for: .treatmentView)
        }

        // MARK: - Camera Analysis (Multimodal)

        @MainActor
        func analyzeImage(_ imageData: Data, description: String = "") async {
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
                let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = trimmedDescription.isEmpty ? "" : "\nUser context: \(trimmedDescription)"
                let request = AIServiceAdapter.AIRequest(
                    model: model,
                    messages: [
                        AIServiceAdapter.ChatMessagePayload(role: .system, content: foodFinderSystemPrompt),
                        AIServiceAdapter.ChatMessagePayload(role: .user, content: "Analyze the food in this photo. Identify each item and provide the nutritional breakdown.\(context)")
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
                foodDescription = ""
                capturedImageData = nil

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
                guard var components = URLComponents(url: openFoodFactsProductURL(for: barcode), resolvingAgainstBaseURL: false) else {
                    errorMessage = String(localized: "Invalid barcode.", comment: "Barcode error")
                    return
                }
                components.queryItems = [
                    URLQueryItem(name: "fields", value: "product_name,nutriments,serving_size,serving_quantity")
                ]
                guard let url = components.url else {
                    errorMessage = String(localized: "Invalid OpenFoodFacts URL.", comment: "Barcode error")
                    return
                }

                var request = URLRequest(url: url)
                request.setValue("Trio AIInsights FoodFinder", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    errorMessage = String(localized: "Product not found in OpenFoodFacts.", comment: "Barcode error")
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Int(doubleValue(json["status"])) == 1,
                      let product = json["product"] as? [String: Any]
                else {
                    errorMessage = String(localized: "Product not found. Try the AI Camera instead.", comment: "Barcode error")
                    return
                }

                let name = stringValue(product["product_name"], fallback: "Unknown Product")
                let serving = stringValue(product["serving_size"], fallback: "1 serving")
                let nutriments = product["nutriments"] as? [String: Any] ?? [:]

                let carbs = nutrientValue(["carbohydrates_serving", "carbohydrates_100g"], in: nutriments)
                let fat = nutrientValue(["fat_serving", "fat_100g"], in: nutriments)
                let protein = nutrientValue(["proteins_serving", "proteins_100g"], in: nutriments)
                let fiber = nutrientValue(["fiber_serving", "fiber_100g"], in: nutriments)
                let calories = nutrientValue(["energy-kcal_serving", "energy-kcal_100g"], in: nutriments)

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

        // MARK: - Dictation

        @MainActor
        func toggleDictation() {
            isDictating ? stopDictation() : startDictation()
        }

        @MainActor
        func stopDictation() {
            audioEngine.stop()
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            if hasAudioTap {
                audioEngine.inputNode.removeTap(onBus: 0)
                hasAudioTap = false
            }
            recognitionRequest = nil
            recognitionTask = nil
            isDictating = false
        }

        @MainActor
        private func startDictation() {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    guard status == .authorized else {
                        self.errorMessage = String(localized: "Speech recognition permission is required for dictation.", comment: "Speech permission error")
                        return
                    }
                    self.beginSpeechRecognition()
                }
            }
        }

        @MainActor
        private func beginSpeechRecognition() {
            stopDictation()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasAudioTap = true

            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.foodDescription = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopDictation()
                    }
                }
            }

            do {
                try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                try audioEngine.start()
                isDictating = true
            } catch {
                errorMessage = String(localized: "Could not start dictation: \(error.localizedDescription)", comment: "Dictation error")
                stopDictation()
            }
        }

        // MARK: - Parsing Helpers

        private func extractJSONFragment(from text: String) -> String? {
            let cleaned = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if cleaned.first == "[" || cleaned.first == "{" {
                return cleaned
            }

            if let arrayStart = cleaned.firstIndex(of: "["),
               let arrayEnd = cleaned.lastIndex(of: "]"),
               arrayStart < arrayEnd
            {
                return String(cleaned[arrayStart ... arrayEnd])
            }

            if let objectStart = cleaned.firstIndex(of: "{"),
               let objectEnd = cleaned.lastIndex(of: "}"),
               objectStart < objectEnd
            {
                return String(cleaned[objectStart ... objectEnd])
            }

            return nil
        }

        private func openFoodFactsProductURL(for barcode: String) -> URL {
            var trimmed = openFoodFactsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            let base = trimmed.isEmpty ? AIInsights.defaultOpenFoodFactsBaseURL : trimmed
            let normalizedBase = base.hasSuffix("/api/v2") ? base : "\(base)/api/v2"
            return URL(string: "\(normalizedBase)/product/\(barcode).json")
                ?? URL(string: "\(AIInsights.defaultOpenFoodFactsBaseURL)/product/\(barcode).json")!
        }

        private func nutrientValue(_ keys: [String], in nutriments: [String: Any]) -> Double {
            for key in keys {
                let value = doubleValue(nutriments[key])
                if value > 0 {
                    return value
                }
            }
            return 0
        }

        private func stringValue(_ value: Any?, fallback: String) -> String {
            if let string = value as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return string
            }
            return fallback
        }

        private func doubleValue(_ value: Any?) -> Double {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let string = value as? String {
                return Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0
            }
            return 0
        }
    }
}
