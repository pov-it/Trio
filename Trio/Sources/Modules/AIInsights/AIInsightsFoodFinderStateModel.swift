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
        var source: FoodSourceID = .aiEstimate
        var sourceURL: URL?
        var sourceVerified: Bool = false
        var sourceName: String?
        var sourceBrand: String?
        var sourceImageURL: URL?
        var sourceScore: Double?
        var alternateMatches: [FoodLookupResult] = []

        var adjustedCarbs: Double { carbs * portionMultiplier }
        var adjustedFat: Double { fat * portionMultiplier }
        var adjustedProtein: Double { protein * portionMultiplier }
        var adjustedFiber: Double { fiber * portionMultiplier }
        var adjustedCalories: Double { calories * portionMultiplier }

        init(
            id: UUID = UUID(),
            name: String,
            portion: String,
            carbs: Double,
            fat: Double,
            protein: Double,
            fiber: Double,
            calories: Double,
            portionMultiplier: Double = 1.0,
            source: FoodSourceID = .aiEstimate,
            sourceURL: URL? = nil,
            sourceVerified: Bool = false,
            sourceName: String? = nil,
            sourceBrand: String? = nil,
            sourceImageURL: URL? = nil,
            sourceScore: Double? = nil,
            alternateMatches: [FoodLookupResult] = []
        ) {
            self.id = id
            self.name = name
            self.portion = portion
            self.carbs = carbs
            self.fat = fat
            self.protein = protein
            self.fiber = fiber
            self.calories = calories
            self.portionMultiplier = portionMultiplier
            self.source = source
            self.sourceURL = sourceURL
            self.sourceVerified = sourceVerified
            self.sourceName = sourceName
            self.sourceBrand = sourceBrand
            self.sourceImageURL = sourceImageURL
            self.sourceScore = sourceScore
            self.alternateMatches = alternateMatches
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case portion
            case carbs
            case fat
            case protein
            case fiber
            case calories
            case portionMultiplier
            case source
            case sourceURL
            case sourceVerified
            case sourceName
            case sourceBrand
            case sourceImageURL
            case sourceScore
            case alternateMatches
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decode(String.self, forKey: .name)
            portion = try container.decode(String.self, forKey: .portion)
            carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
            fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
            protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
            fiber = try container.decodeIfPresent(Double.self, forKey: .fiber) ?? 0
            calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
            portionMultiplier = try container.decodeIfPresent(Double.self, forKey: .portionMultiplier) ?? 1.0
            source = try container.decodeIfPresent(FoodSourceID.self, forKey: .source) ?? .aiEstimate
            sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
            sourceVerified = try container.decodeIfPresent(Bool.self, forKey: .sourceVerified) ?? false
            sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
            sourceBrand = try container.decodeIfPresent(String.self, forKey: .sourceBrand)
            sourceImageURL = try container.decodeIfPresent(URL.self, forKey: .sourceImageURL)
            sourceScore = try container.decodeIfPresent(Double.self, forKey: .sourceScore)
            alternateMatches = try container.decodeIfPresent([FoodLookupResult].self, forKey: .alternateMatches) ?? []
        }
    }

    /// Per-meal override that lets the user dictate the total macros without
    /// having to scale individual ingredients. Any field left nil falls back
    /// to the sum of `items`.
    struct MacroOverride: Codable, Equatable {
        var carbs: Double?
        var fat: Double?
        var protein: Double?
        var fiber: Double?
        var calories: Double?

        var isEmpty: Bool {
            carbs == nil && fat == nil && protein == nil && fiber == nil && calories == nil
        }
    }

    struct FoodAnalysisResult: Identifiable, Codable {
        var id: UUID = UUID()
        var items: [FoodItem]
        let rawResponse: String?
        let timestamp: Date
        let source: FoodSource
        var imageData: Data?
        var mealDescription: String?
        var mealName: String? = nil
        var mealPortion: String? = nil
        var confidence: Double? = nil
        var manualMacroOverride: MacroOverride? = nil
        var carbEstimateLowerBound: Double? = nil
        var carbEstimateUpperBound: Double? = nil
        var carbEstimateUncertaintyUnits: Double? = nil
        var analysisCandidateCount: Int? = nil
        var doseGuardApplied: Bool? = nil

        var totalCarbs: Double { manualMacroOverride?.carbs ?? items.reduce(0) { $0 + $1.adjustedCarbs } }
        var totalFat: Double { manualMacroOverride?.fat ?? items.reduce(0) { $0 + $1.adjustedFat } }
        var totalProtein: Double { manualMacroOverride?.protein ?? items.reduce(0) { $0 + $1.adjustedProtein } }
        var totalFiber: Double { manualMacroOverride?.fiber ?? items.reduce(0) { $0 + $1.adjustedFiber } }
        var totalCalories: Double { manualMacroOverride?.calories ?? items.reduce(0) { $0 + $1.adjustedCalories } }

        var hasManualMacroOverride: Bool {
            !(manualMacroOverride?.isEmpty ?? true)
        }

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
        let useReducedBolus: Bool?

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

    /// Per-item portion-adjustment stats used to bias future analyses.
    /// If a user systematically pushes "Pasta" to 1.5× we eventually start
    /// every new Pasta result at 1.5× instead of 1.0×.
    struct PortionLearningStat: Codable {
        var sum: Double
        var count: Int
        var lastMultiplier: Double
    }

    @Observable final class FoodFinderStateModel: BaseStateModel<Provider> {
        var isAnalyzing: Bool = false
        var errorMessage: String?
        var barcodeStatusMessage: String?
        var barcodeStatusIsSuccess: Bool = false
        var lastAddedFoodItemID: UUID?
        var currentResult: FoodAnalysisResult?
        var foodDescription: String = "" {
            didSet { saveDraftDescription() }
        }
        var recentResults: [FoodAnalysisResult] = []
        /// Meals the user has analyzed ≥ 3 times. Latest snapshot per meal.
        var frequentMeals: [FoodAnalysisResult] = []
        var showCamera: Bool = false
        var showBarcodeScanner: Bool = false
        var showPhotoPicker: Bool = false
        /// Image that just came back from camera/library — view shows the
        /// crop sheet while this is non-nil. Setting it nil dismisses the
        /// sheet (e.g. on Skip or Cancel).
        var pendingImageForCrop: Data?
        /// All images the user has attached to the next analysis. Earlier
        /// versions had a single `capturedImageData: Data?`; we keep the same
        /// behavior when the array contains one item but allow multi-photo
        /// composition for richer meal context.
        var capturedImages: [Data] = []
        /// Convenience accessor mirroring the old single-image API. Returns
        /// the first image; setting nil clears the array.
        var capturedImageData: Data? {
            get { capturedImages.first }
            set {
                if let new = newValue {
                    capturedImages = [new]
                } else {
                    capturedImages.removeAll()
                }
            }
        }
        var isDictating: Bool = false
        var isTranscribingDictation: Bool = false

        // Shared AI config
        var apiKey: String = ""
        var providerType: AIProvider = .google
        var model: String = AIProvider.google.defaultModel
        var baseURL: String = AIProvider.google.defaultEndpoint
        var aiDictationEnabled: Bool = false
        var aiDictationUsesSeparateProvider: Bool = false
        var aiDictationProviderType: AIProvider = .google
        var aiDictationModel: String = AIProvider.google.defaultDictationModel
        var aiDictationBaseURL: String = AIProvider.google.defaultEndpoint
        var aiDictationAPIKey: String = ""
        var aiEnabled: Bool = false
        var openFoodFactsBaseURL: String = AIInsights.defaultOpenFoodFactsBaseURL
        var foodFinderLookupMode: FoodFinderLookupMode = .verifiedAgent
        var foodFinderOpenFoodFactsEnabled: Bool = true
        var foodFinderUSDAEnabled: Bool = false
        var foodFinderPreferredSource: FoodSourceID = .openFoodFacts
        var foodFinderUSDAAPIKey: String = ""
        var foodFinderDoseGuardEnabled: Bool = true
        var foodFinderDoseGuardSamples: Int = 2
        var maxFoodFinderImages: Int { max(1, providerType.foodFinderImageLimit) }

        @ObservationIgnored private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        @ObservationIgnored private let audioEngine = AVAudioEngine()
        @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
        @ObservationIgnored private var hasAudioTap = false
        @ObservationIgnored private var aiAudioRecorder: AVAudioRecorder?
        @ObservationIgnored private var aiDictationAudioURL: URL?
        @ObservationIgnored private var isUsingAIDictation = false

        private struct ParsedFoodAnalysis {
            var items: [FoodItem]
            var mealName: String?
            var mealPortion: String?
            var confidence: Double?
        }

        private struct FoodAnalysisCandidate {
            var parsed: ParsedFoodAnalysis
            var rawResponse: String

            var totalCarbs: Double {
                parsed.items.reduce(0) { $0 + $1.adjustedCarbs }
            }
        }

        private struct FoodDoseGuardDiagnostics {
            var lowerBound: Double?
            var upperBound: Double?
            var uncertaintyUnits: Double?
            var candidateCount: Int
            var applied: Bool
        }

        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }
            if let savedDictationKey = provider.keychain.getValue(String.self, forKey: "ai_insights_dictation_api_key") {
                aiDictationAPIKey = savedDictationKey
            }
            if let savedUSDAKey = provider.keychain.getValue(String.self, forKey: "ai_foodfinder_usda_api_key") {
                foodFinderUSDAAPIKey = savedUSDAKey
            }

            providerType = provider.settings.aiProvider
            model = provider.settings.aiModel
            baseURL = provider.settings.aiBaseURL
            aiDictationEnabled = provider.settings.aiDictationEnabled
            aiDictationUsesSeparateProvider = provider.settings.aiDictationUsesSeparateProvider
            aiDictationProviderType = provider.settings.aiDictationProvider
            aiDictationModel = provider.settings.aiDictationModel
            aiDictationBaseURL = provider.settings.aiDictationBaseURL
            aiEnabled = provider.settings.aiEnabled
            openFoodFactsBaseURL = provider.settings.openFoodFactsBaseURL
            foodFinderLookupMode = provider.settings.foodFinderLookupMode
            foodFinderOpenFoodFactsEnabled = provider.settings.foodFinderOpenFoodFactsEnabled
            foodFinderUSDAEnabled = provider.settings.foodFinderUSDAEnabled
            foodFinderPreferredSource = provider.settings.foodFinderPreferredSource
            foodFinderDoseGuardEnabled = provider.settings.foodFinderDoseGuardEnabled
            foodFinderDoseGuardSamples = min(3, max(1, provider.settings.foodFinderDoseGuardSamples))

            loadDraftDescription()
            loadRecentResults()
            loadFrequentMeals()
        }

        // MARK: - Persistence

        private static let usageCountsKey = "ai_foodfinder_meal_usage"
        private static let frequentMealsKey = "ai_foodfinder_frequent"
        private static let portionLearningKey = "ai_foodfinder_portion_learning"
        private static let draftDescriptionKey = "ai_foodfinder_draft_description"
        private static let frequentThreshold = 3
        private static let frequentMealsMax = 10
        private static let portionLearningMinSamples = 2
        private static let portionLearningMinDeviation = 0.10

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

        private func loadDraftDescription() {
            foodDescription = UserDefaults.standard.string(forKey: Self.draftDescriptionKey) ?? ""
        }

        private func saveDraftDescription() {
            let trimmed = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.draftDescriptionKey)
            } else {
                UserDefaults.standard.set(foodDescription, forKey: Self.draftDescriptionKey)
            }
        }

        func loadFrequentMeals() {
            if let data = UserDefaults.standard.data(forKey: Self.frequentMealsKey),
               let saved = try? JSONDecoder().decode([FoodAnalysisResult].self, from: data)
            {
                frequentMeals = saved
            }
        }

        private func saveFrequentMeals() {
            let toSave = Array(frequentMeals.prefix(Self.frequentMealsMax))
            if let data = try? JSONEncoder().encode(toSave) {
                UserDefaults.standard.set(data, forKey: Self.frequentMealsKey)
            }
        }

        // MARK: - Frequency-based promotion

        /// Increments the usage counter for a meal name and returns the new total.
        @discardableResult
        private func bumpMealUsage(for name: String) -> Int {
            let key = Self.normalizeMealKey(name)
            guard !key.isEmpty else { return 0 }
            var counts = UserDefaults.standard.dictionary(forKey: Self.usageCountsKey) as? [String: Int] ?? [:]
            let newCount = (counts[key] ?? 0) + 1
            counts[key] = newCount
            UserDefaults.standard.set(counts, forKey: Self.usageCountsKey)
            return newCount
        }

        /// If a meal has been analyzed ≥ frequentThreshold times, store the
        /// latest snapshot as a "Frequent Meal". Replaces any earlier snapshot
        /// with the same normalized name.
        private func promoteIfFrequent(_ result: FoodAnalysisResult) {
            let nameRaw = result.mealName?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? result.items.map(\.name).joined(separator: ", ")
            let key = Self.normalizeMealKey(nameRaw)
            guard !key.isEmpty else { return }
            let count = bumpMealUsage(for: nameRaw)
            guard count >= Self.frequentThreshold else { return }
            frequentMeals.removeAll { Self.normalizeMealKey($0.mealName ?? "") == key }
            frequentMeals.insert(result, at: 0)
            saveFrequentMeals()
        }

        private static func normalizeMealKey(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        // MARK: - Portion learning

        private func loadPortionLearning() -> [String: PortionLearningStat] {
            guard let data = UserDefaults.standard.data(forKey: Self.portionLearningKey),
                  let saved = try? JSONDecoder().decode([String: PortionLearningStat].self, from: data)
            else { return [:] }
            return saved
        }

        private func savePortionLearning(_ stats: [String: PortionLearningStat]) {
            if let data = try? JSONEncoder().encode(stats) {
                UserDefaults.standard.set(data, forKey: Self.portionLearningKey)
            }
        }

        /// Records the user's chosen multiplier for an item so future analyses
        /// of the same item can start at the learned average.
        private func recordPortionLearning(itemName: String, multiplier: Double) {
            let key = Self.normalizeMealKey(itemName)
            guard !key.isEmpty else { return }
            var stats = loadPortionLearning()
            var entry = stats[key] ?? PortionLearningStat(sum: 0, count: 0, lastMultiplier: 1.0)
            entry.sum += multiplier
            entry.count += 1
            entry.lastMultiplier = multiplier
            stats[key] = entry
            savePortionLearning(stats)
        }

        /// Applies learned per-item portion multipliers to a fresh analysis
        /// result before showing it to the user. Only applies when the user
        /// has logged at least `portionLearningMinSamples` adjustments AND
        /// the learned average deviates by at least 10% from 1.0×.
        private func applyLearnedPortions(to result: inout FoodAnalysisResult) {
            let stats = loadPortionLearning()
            guard !stats.isEmpty else { return }
            for i in result.items.indices {
                let key = Self.normalizeMealKey(result.items[i].name)
                guard let stat = stats[key],
                      stat.count >= Self.portionLearningMinSamples
                else { continue }
                let avg = stat.sum / Double(stat.count)
                if abs(avg - 1.0) >= Self.portionLearningMinDeviation {
                    result.items[i].portionMultiplier = max(0.25, avg)
                }
            }
        }

        /// Load recent FoodFinder analyses without instantiating the full state
        /// model. Used by the chat prompt builder to inject meal history.
        static func loadStoredRecentResults() -> [FoodAnalysisResult] {
            guard let data = UserDefaults.standard.data(forKey: "ai_foodfinder_recent"),
                  let saved = try? JSONDecoder().decode([FoodAnalysisResult].self, from: data)
            else { return [] }
            return saved
        }

        /// Build a chat prompt section describing recent FoodFinder analyses.
        /// Always returns a section header so the AI knows FoodFinder data
        /// exists, even when the user hasn't logged anything recently.
        static func buildMealPromptContext(at now: Date = Date(), lookbackHours: Double = 48) -> String {
            let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
            let windowLabel = lookbackHours >= 48
                ? String(format: "last %.0f days", lookbackHours / 24)
                : String(format: "last %.0f hours", lookbackHours)
            let recent = loadStoredRecentResults()
                .filter { $0.timestamp >= cutoff }
                .sorted { $0.timestamp > $1.timestamp }

            guard !recent.isEmpty else {
                return "## Recent Meals (FoodFinder)\n- No meals analyzed in the \(windowLabel). (FoodFinder is available; the user can describe meals or scan barcodes to log carbs/fat/protein.)\n"
            }

            let formatter = DateFormatter()
            formatter.dateStyle = lookbackHours > 48 ? .short : .none
            formatter.timeStyle = .short
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE"

            var ctx = "## Recent Meals (FoodFinder)\n"
            ctx += "Last \(recent.count) meal analysis(es) from the \(windowLabel):\n"
            for result in recent.prefix(8) {
                let when = "\(dayFormatter.string(from: result.timestamp)) \(formatter.string(from: result.timestamp))"
                let name = result.mealName?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                    ?? result.items.map(\.name).joined(separator: ", ").aiInsightsNilIfEmpty
                    ?? "Meal"
                ctx += String(
                    format: "- %@ — %@: %.0fg carbs, %.0fg fat, %.0fg protein, %.0fg fiber, %.0f kcal",
                    when,
                    name,
                    result.totalCarbs,
                    result.totalFat,
                    result.totalProtein,
                    result.totalFiber,
                    result.totalCalories
                )
                if result.items.count > 1 {
                    let itemList = result.items.prefix(5).map(\.name).joined(separator: ", ")
                    ctx += " [\(itemList)\(result.items.count > 5 ? ", …" : "")]"
                }
                ctx += "\n"
            }
            return ctx
        }

        // MARK: - Text Analysis

        @MainActor
        func analyzeCurrentInput() async {
            let description = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !capturedImages.isEmpty {
                await analyzeImages(capturedImages, description: description)
            } else {
                await analyzeFood(description: description)
            }
        }

        /// Append a new image to the composer. The cap follows the active
        /// provider's multimodal limits.
        func attachImage(_ imageData: Data) {
            guard capturedImages.count < maxFoodFinderImages else { return }
            capturedImages.append(imageData)
        }

        func attachImages(_ imageData: [Data]) {
            let remaining = max(0, maxFoodFinderImages - capturedImages.count)
            guard remaining > 0 else { return }
            capturedImages.append(contentsOf: imageData.prefix(remaining))
        }

        /// Remove an attached image by index (used by the per-thumb delete
        /// button in the composer).
        func removeAttachedImage(at index: Int) {
            guard capturedImages.indices.contains(index) else { return }
            capturedImages.remove(at: index)
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
                var (candidate, diagnostics) = try await requestFoodAnalysisCandidates(
                    prompt: "Analyze this food: \(description)",
                    imageData: nil,
                    description: description,
                    hasImage: false
                )

                var parsed = candidate.parsed
                if shouldRetrySuspiciousResult(parsed, description: description, hasImage: false) {
                    let retry = try await requestFoodAnalysisCandidates(
                        prompt: "Re-evaluate this likely carb-containing meal. The previous estimate returned zero or near-zero carbs, which is implausible. Return the same strict JSON object schema with realistic standard portions. Food: \(description)",
                        imageData: nil,
                        description: description,
                        hasImage: false
                    )
                    candidate = retry.0
                    diagnostics = retry.1
                    parsed = candidate.parsed
                }
                guard !parsed.items.isEmpty,
                      !isSuspiciousZeroCarbResult(parsed, description: description, hasImage: false)
                else {
                    errorMessage = String(localized: "The AI returned an implausible nutrition estimate. Add portion details and try again.", comment: "FoodFinder implausible estimate error")
                    return
                }

                var result = FoodAnalysisResult(
                    items: parsed.items,
                    rawResponse: candidate.rawResponse,
                    timestamp: Date(),
                    source: .aiText,
                    imageData: nil,
                    mealDescription: description,
                    mealName: parsed.mealName ?? description,
                    mealPortion: parsed.mealPortion,
                    confidence: parsed.confidence
                )
                applyDoseGuardDiagnostics(diagnostics, to: &result)
                applyLearnedPortions(to: &result)

                currentResult = result
                recentResults.insert(result, at: 0)
                saveRecentResults()
                promoteIfFrequent(result)
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
            \(AIInsights.responseLanguageInstruction())

            When given a food description or image, respond ONLY with one valid JSON object matching this schema:
            {
              "mealName": "Spaghetti gamberi e zucchine",
              "mealPortion": "1 plate (about 450g)",
              "confidence": 0.78,
              "items": [
                {
                  "name": "Spaghetti",
                  "portion": "1 plate portion (250g cooked)",
                  "carbs": 75.0,
                  "fat": 2.0,
                  "protein": 13.0,
                  "fiber": 4.0,
                  "calories": 395
                }
              ]
            }

            RULES:
            - Prefer a conservative lower plausible portion over an overestimate when the portion is uncertain.
            - The user must still confirm/edit the result before dosing; do not include insulin advice or dosing math.
            - Preserve explicit user quantities and units exactly when present.
            - Use modest standard serving sizes when portions are not specified.
            - Do not output chain-of-thought, hidden calculations, or explanatory prose.
            - Be as accurate as possible with carb counts — this directly affects insulin dosing
            - Break compound meals into individual items (e.g. "burger and fries" → separate items)
            - Use standard serving sizes when portions are not specified
            - Include fiber separately — the user's pump system can use net carbs
            - Use the user's text as a strong clue when the photo is ambiguous
            - If a named meal is likely carb-containing (pasta, rice, bread, pizza, potato, fruit, dessert), do not return 0 carbs unless the portion is truly negligible
            - Treat pure seasonings and zero-carb liquids as ~0 carbs/fat/protein: salt, pepper, herbs, spices, plain or sparkling water, black coffee, plain tea, and calorie-free sweeteners
            - Count only the edible fraction: when a food is described "with peel/skin/shell" (e.g. unpeeled banana, egg in shell, shrimp in shell), base carbs on the edible part, not the gross weight
            - When preparation is unspecified, assume the normally-eaten edible/cooked form, not raw dry flour/powder weights (e.g. "rice" means cooked rice, not dry grains; "oats" means prepared, not dry unless stated)
            - Do not inflate vague labels (vegetable, sauce, curry, dal, vaji, salad, side) into a large starch portion unless the text or image clearly shows a large starch serving
            - Recognize embedded and hyphenated quantities as exact portions (e.g. "230-gram", "weighing 30 grams", "a 330ml can", "two 25g slices") and honor them precisely
            - If you cannot identify the food, respond with: {"mealName":"Unknown","mealPortion":"Unknown","confidence":0.1,"items":[]}
            - Food names and portion descriptions should match the user's app language when possible
            - Respond ONLY with the JSON object. No markdown, no explanation outside the JSON.
            """
        }

        private var foodFinderResponseFormat: [String: Any]? {
            switch providerType {
            case .google:
                return ["type": "json_object"]
            case .openai:
                return [
                "type": "json_schema",
                "json_schema": [
                    "name": "food_finder_analysis",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["mealName", "mealPortion", "confidence", "items"],
                        "properties": [
                            "mealName": ["type": "string"],
                            "mealPortion": ["type": "string"],
                            "confidence": ["type": "number"],
                            "items": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "additionalProperties": false,
                                    "required": ["name", "portion", "carbs", "fat", "protein", "fiber", "calories"],
                                    "properties": [
                                        "name": ["type": "string"],
                                        "portion": ["type": "string"],
                                        "carbs": ["type": "number"],
                                        "fat": ["type": "number"],
                                        "protein": ["type": "number"],
                                        "fiber": ["type": "number"],
                                        "calories": ["type": "number"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
                ]
            case .anthropic, .custom:
                return nil
            }
        }

        // MARK: - Response Parsing

        private func parseFoodAnalysis(from text: String) -> ParsedFoodAnalysis {
            guard let jsonText = extractJSONFragment(from: text),
                  let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return ParsedFoodAnalysis(items: [])
            }

            let rawItems: [[String: Any]]
            var mealName: String?
            var mealPortion: String?
            var confidence: Double?

            if let array = json as? [[String: Any]] {
                rawItems = array
            } else if let object = json as? [String: Any],
                      let items = object["items"] as? [[String: Any]]
            {
                rawItems = items
                mealName = stringValue(object["mealName"] ?? object["meal_name"] ?? object["name"], fallback: "")
                mealPortion = stringValue(object["mealPortion"] ?? object["meal_portion"] ?? object["portion"], fallback: "")
                confidence = doubleValue(object["confidence"])
            } else {
                rawItems = []
            }

            let items = rawItems.map { item in
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

            return ParsedFoodAnalysis(
                items: items,
                mealName: mealName?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty,
                mealPortion: mealPortion?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty,
                confidence: confidence
            )
        }

        private func parseFoodItems(from text: String) -> [FoodItem] {
            parseFoodAnalysis(from: text).items
        }

        // MARK: - Food Lookup Agent

        private var isFoodLookupAgentEnabled: Bool {
            foodFinderLookupMode == .verifiedAgent
        }

        private var enabledFoodSourcesInPreferenceOrder: [FoodSourceID] {
            var sources: [FoodSourceID] = []
            if foodFinderPreferredSource == .openFoodFacts, foodFinderOpenFoodFactsEnabled {
                sources.append(.openFoodFacts)
            }
            if foodFinderPreferredSource == .usda, foodFinderUSDAEnabled, !foodFinderUSDAAPIKey.isEmpty {
                sources.append(.usda)
            }
            if foodFinderOpenFoodFactsEnabled, !sources.contains(.openFoodFacts) {
                sources.append(.openFoodFacts)
            }
            if foodFinderUSDAEnabled, !foodFinderUSDAAPIKey.isEmpty, !sources.contains(.usda) {
                sources.append(.usda)
            }
            return sources
        }

        private func enrichFoodItemsWithLookup(_ items: [FoodItem]) async -> [FoodItem] {
            guard isFoodLookupAgentEnabled else { return items }

            var enriched: [FoodItem] = []
            for item in items {
                enriched.append(await enrichFoodItemWithLookup(item))
            }
            return enriched
        }

        private func enrichFoodItemWithLookup(_ item: FoodItem) async -> FoodItem {
            let matches = await lookupFoodSources(query: item.name)
            guard let best = bestLookupMatch(for: item, from: matches) else {
                var fallback = item
                fallback.source = .aiEstimate
                fallback.sourceVerified = false
                fallback.alternateMatches = matches
                return fallback
            }

            return itemByApplyingLookup(best, to: item, alternates: matches)
        }

        private func lookupFoodSources(query: String) async -> [FoodLookupResult] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            var results: [FoodLookupResult] = []
            for source in enabledFoodSourcesInPreferenceOrder {
                do {
                    switch source {
                    case .openFoodFacts:
                        results.append(contentsOf: try await lookupOpenFoodFactsResults(trimmed))
                    case .usda:
                        results.append(contentsOf: try await lookupUSDAResults(trimmed))
                    case .aiEstimate:
                        break
                    }
                } catch {
                    debugPrint("FoodFinder lookup failed for \(source.rawValue): \(error)")
                }
            }
            return results.sorted { $0.verifiedScore > $1.verifiedScore }
        }

        private func bestLookupMatch(for item: FoodItem, from matches: [FoodLookupResult]) -> FoodLookupResult? {
            matches
                .map { match in
                    (match: match, score: match.verifiedScore * nameMatchScore(item.name, match.name))
                }
                .filter { $0.score >= 0.52 }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return sourceRank(lhs.match.sourceID) < sourceRank(rhs.match.sourceID)
                    }
                    return lhs.score > rhs.score
                }
                .first?
                .match
        }

        private func sourceRank(_ source: FoodSourceID) -> Int {
            source == foodFinderPreferredSource ? 0 : 1
        }

        private func itemByApplyingLookup(
            _ lookup: FoodLookupResult,
            to item: FoodItem,
            alternates: [FoodLookupResult]
        ) -> FoodItem {
            let existingGrams = gramsFromPortion(item.portion)
            let lookupGrams = lookup.portionGrams
            let scale: Double
            let portion: String

            if let existingGrams, let lookupGrams, lookupGrams > 0 {
                scale = max(0.05, existingGrams / lookupGrams)
                portion = item.portion
            } else {
                scale = 1
                portion = item.portion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? lookup.portion
                    : item.portion
            }

            return FoodItem(
                id: item.id,
                name: item.name,
                portion: portion,
                carbs: lookup.carbs * scale,
                fat: lookup.fat * scale,
                protein: lookup.protein * scale,
                fiber: lookup.fiber * scale,
                calories: lookup.calories * scale,
                portionMultiplier: item.portionMultiplier,
                source: lookup.sourceID,
                sourceURL: lookup.sourceURL,
                sourceVerified: lookup.sourceVerified,
                sourceName: lookup.name,
                sourceBrand: lookup.brand,
                sourceImageURL: lookup.imageURL,
                sourceScore: lookup.verifiedScore,
                alternateMatches: alternates
            )
        }

        private func foodItem(from lookup: FoodLookupResult, fallbackName: String, existingPortion: String?) -> FoodItem {
            let seed = FoodItem(
                name: fallbackName,
                portion: existingPortion?.aiInsightsNilIfEmpty ?? lookup.portion,
                carbs: lookup.carbs,
                fat: lookup.fat,
                protein: lookup.protein,
                fiber: lookup.fiber,
                calories: lookup.calories
            )
            return itemByApplyingLookup(lookup, to: seed, alternates: [lookup])
        }

        private func nameMatchScore(_ query: String, _ candidate: String) -> Double {
            let q = normalizedFoodTokens(query)
            let c = normalizedFoodTokens(candidate)
            guard !q.isEmpty, !c.isEmpty else { return 0 }
            let overlap = q.intersection(c).count
            if overlap == 0 { return 0.25 }
            let coverage = Double(overlap) / Double(q.count)
            let union = Double(q.union(c).count)
            let jaccard = union > 0 ? Double(overlap) / union : coverage
            return min(1, max(coverage, jaccard))
        }

        private func normalizedFoodTokens(_ text: String) -> Set<String> {
            let stopWords: Set<String> = [
                "the", "and", "with", "for", "een", "het", "de", "met", "van", "zonder", "about",
                "portion", "serving", "plate", "bowl", "cooked", "raw"
            ]
            let cleaned = text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
            return Set(cleaned)
        }

        private func gramsFromPortion(_ portion: String) -> Double? {
            let pattern = #"(\d+(?:[.,]\d+)?)\s*(g|gram|grams|ml|milliliter|milliliters)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            let range = NSRange(portion.startIndex..<portion.endIndex, in: portion)
            guard let match = regex.firstMatch(in: portion, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: portion)
            else { return nil }
            return Double(String(portion[valueRange]).replacingOccurrences(of: ",", with: "."))
        }

        // MARK: - Helpers

        func updatePortion(for itemId: UUID, multiplier: Double) {
            guard var result = currentResult,
                  let idx = result.items.firstIndex(where: { $0.id == itemId })
            else { return }
            let clamped = max(0.25, multiplier)
            result.items[idx].portionMultiplier = clamped
            storeUpdatedResult(result)
            // Record so future analyses of the same item start at the
            // user's preferred portion automatically.
            recordPortionLearning(itemName: result.items[idx].name, multiplier: clamped)
        }

        func updateItemName(for itemId: UUID, name: String) {
            guard var result = currentResult,
                  let idx = result.items.firstIndex(where: { $0.id == itemId })
            else { return }
            result.items[idx].name = name
            storeUpdatedResult(result)
        }

        /// Replace an entire ingredient with edited values from the macro-edit
        /// modal. The replacement keeps the original id so swipes/IDs remain stable.
        func replaceItem(_ item: FoodItem) {
            guard var result = currentResult,
                  let idx = result.items.firstIndex(where: { $0.id == item.id })
            else { return }
            result.items[idx] = item
            storeUpdatedResult(result)
        }

        /// Set or clear the per-meal manual macro override.
        func updateManualMacroOverride(_ override: MacroOverride?) {
            guard var result = currentResult else { return }
            if let override, !override.isEmpty {
                result.manualMacroOverride = override
            } else {
                result.manualMacroOverride = nil
            }
            storeUpdatedResult(result)
        }

        @MainActor
        func reanalyzeItem(_ itemId: UUID, query: String? = nil) async {
            guard let result = currentResult,
                  let item = result.items.first(where: { $0.id == itemId }),
                  !(query ?? item.name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }

            isAnalyzing = true
            errorMessage = nil
            defer { isAnalyzing = false }

            do {
                guard let replacement = try await searchIngredient(
                    named: query ?? item.name,
                    existingPortion: item.portion
                ) else {
                    errorMessage = String(localized: "No matching nutrition estimate was found.", comment: "FoodFinder no replacement error")
                    return
                }

                guard var updatedResult = currentResult,
                      let idx = updatedResult.items.firstIndex(where: { $0.id == itemId })
                else { return }
                var updatedItem = replacement
                updatedItem.id = itemId
                updatedItem.portionMultiplier = item.portionMultiplier
                updatedResult.items[idx] = updatedItem
                storeUpdatedResult(updatedResult)
            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        @MainActor
        func addIngredient(named name: String) async {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, var result = currentResult else { return }

            isAnalyzing = true
            errorMessage = nil
            defer { isAnalyzing = false }

            do {
                guard let item = try await searchIngredient(named: trimmed, existingPortion: nil) else {
                    errorMessage = String(localized: "No matching nutrition estimate was found.", comment: "FoodFinder no replacement error")
                    return
                }

                result.items.append(item)
                storeUpdatedResult(result)
                foodDescription = ""
            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        @MainActor
        func addIngredientFromCurrentInput() async {
            let description = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !capturedImages.isEmpty {
                await addIngredientsFromImages(capturedImages, description: description)
            } else {
                await addIngredient(named: description)
            }
        }

        /// Backwards-compatible single-image entry point.
        @MainActor
        func addIngredientsFromImage(_ imageData: Data, description: String = "") async {
            await addIngredientsFromImages([imageData], description: description)
        }

        @MainActor
        func addIngredientsFromImages(_ images: [Data], description: String = "") async {
            guard !images.isEmpty, currentResult != nil else { return }
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
                let multi = images.count > 1
                    ? "These \(images.count) photos show the items to add. "
                    : ""
                let (candidate, _) = try await requestFoodAnalysisCandidates(
                    prompt: "\(multi)Analyze the food in the photo(s) and return items to add to an existing meal.\(context)",
                    imageData: images.first,
                    additionalImageData: Array(images.dropFirst()),
                    description: trimmedDescription,
                    hasImage: true
                )

                let parsed = candidate.parsed
                guard !parsed.items.isEmpty else {
                    errorMessage = String(localized: "No food items could be identified in the photo.", comment: "FoodFinder add from image error")
                    return
                }

                guard var result = currentResult else { return }
                result.items.append(contentsOf: parsed.items)
                storeUpdatedResult(result)
                foodDescription = ""
                capturedImages.removeAll()

            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        @MainActor
        func addIngredientFromBarcode(_ barcode: String) async {
            guard var result = currentResult else { return }

            isAnalyzing = true
            errorMessage = nil
            barcodeStatusMessage = nil
            defer { isAnalyzing = false }

            do {
                guard var components = URLComponents(url: openFoodFactsProductURL(for: barcode), resolvingAgainstBaseURL: false) else {
                    setBarcodeError(String(localized: "Invalid barcode.", comment: "Barcode error"))
                    return
                }
                components.queryItems = [
                    URLQueryItem(name: "fields", value: "code,product_name,brands,nutriments,serving_size,serving_quantity,nutrition_data_completeness,image_url,url")
                ]
                guard let url = components.url else {
                    setBarcodeError(String(localized: "Invalid OpenFoodFacts URL.", comment: "Barcode error"))
                    return
                }

                var urlRequest = URLRequest(url: url)
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                urlRequest.setValue("TrioAIInsights/\(appVersion) (https://github.com/pov-it/Trio)", forHTTPHeaderField: "User-Agent")
                urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Int(doubleValue(json["status"])) == 1,
                      let product = json["product"] as? [String: Any]
                else {
                    setBarcodeError(String(localized: "Product not found. Try the AI Camera instead.", comment: "Barcode error"))
                    return
                }

                let name = stringValue(product["product_name"], fallback: String(localized: "Unknown Product", comment: "Unknown barcode product"))
                let serving = stringValue(product["serving_size"], fallback: String(localized: "1 serving", comment: "Default food serving"))
                let nutriments = product["nutriments"] as? [String: Any] ?? [:]

                let item = openFoodFactsLookupResult(from: product, fallbackName: name)
                    .map { foodItem(from: $0, fallbackName: $0.name, existingPortion: serving) }
                    ?? FoodItem(
                        name: name,
                        portion: serving,
                        carbs: nutrientValue(["carbohydrates_serving", "carbohydrates_100g"], in: nutriments),
                        fat: nutrientValue(["fat_serving", "fat_100g"], in: nutriments),
                        protein: nutrientValue(["proteins_serving", "proteins_100g"], in: nutriments),
                        fiber: nutrientValue(["fiber_serving", "fiber_100g"], in: nutriments),
                        calories: nutrientValue(["energy-kcal_serving", "energy-kcal_100g"], in: nutriments),
                        source: .openFoodFacts,
                        sourceVerified: true
                    )

                result.items.append(item)
                storeUpdatedResult(result)
                lastAddedFoodItemID = item.id
                setBarcodeSuccess(
                    String(
                        format: String(localized: "Added %@", comment: "Barcode product added success"),
                        item.name
                    )
                )

            } catch {
                setBarcodeError(String(localized: "Network error looking up barcode: \(error.localizedDescription)", comment: "Barcode error"))
            }
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

            // Atwater factors: kcal/g of carbs=4, fat=9, protein=4. When the
            // user edits a macro, the calorie value is rederived so the row
            // stays internally consistent without an extra "recompute" step.
            if macro != .calories {
                let item = result.items[idx]
                result.items[idx].calories = 4 * item.carbs + 9 * item.fat + 4 * item.protein
            }

            storeUpdatedResult(result)
        }

        func removeItem(_ itemId: UUID) {
            guard var result = currentResult else { return }
            result.items.removeAll { $0.id == itemId }
            storeUpdatedResult(result)
        }

        func deleteRecentResult(_ result: FoodAnalysisResult) {
            recentResults.removeAll { $0.id == result.id }
            saveRecentResults()
        }

        /// Remove a meal from the "Frequent Meals" list and also reset its
        /// usage counter so we don't immediately re-promote it.
        func deleteFrequentMeal(_ result: FoodAnalysisResult) {
            let key = Self.normalizeMealKey(result.mealName ?? "")
            frequentMeals.removeAll { $0.id == result.id || Self.normalizeMealKey($0.mealName ?? "") == key }
            saveFrequentMeals()
            if !key.isEmpty {
                var counts = UserDefaults.standard.dictionary(forKey: Self.usageCountsKey) as? [String: Int] ?? [:]
                counts.removeValue(forKey: key)
                UserDefaults.standard.set(counts, forKey: Self.usageCountsKey)
            }
        }

        private func storeUpdatedResult(_ result: FoodAnalysisResult) {
            currentResult = result
            if let idx = recentResults.firstIndex(where: { $0.id == result.id }) {
                recentResults[idx] = result
                saveRecentResults()
            }
        }

        func discardCapturedImage() {
            capturedImageData = nil
        }

        func clearResult(resetDraft: Bool = false) {
            currentResult = nil
            errorMessage = nil
            barcodeStatusMessage = nil
            lastAddedFoodItemID = nil
            if resetDraft {
                capturedImageData = nil
                foodDescription = ""
            }
        }

        func sendToBolusCalculator(openBolusCalculator: Bool = true) {
            guard let result = currentResult else { return }
            let itemNames = result.items.map(\.name).joined(separator: ", ")
            let handoff = FoodBolusHandoff(
                carbs: result.totalCarbs,
                fat: result.totalFat,
                protein: result.totalProtein,
                note: itemNames.isEmpty ? "FoodFinder" : itemNames,
                createdAt: Date(),
                useReducedBolus: AIInsights.foodFinderReducedBolusRecommended(fat: result.totalFat, protein: result.totalProtein)
            )
            FoodBolusHandoff.store(handoff)
            if openBolusCalculator {
                showModal(for: .treatmentView)
            }
        }

        // MARK: - Camera Analysis (Multimodal)

        /// Backwards-compatible single-image entry point. Delegates to
        /// `analyzeImages(_:description:)`.
        @MainActor
        func analyzeImage(_ imageData: Data, description: String = "") async {
            await analyzeImages([imageData], description: description)
        }

        /// Multi-image AI analysis: sends every attached photo as a separate
        /// part of the same user turn so the model can reason across them
        /// (e.g. side dish + portion ruler + ingredient label).
        @MainActor
        func analyzeImages(_ images: [Data], description: String = "") async {
            guard !images.isEmpty else { return }
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
                let multi = images.count > 1
                    ? "These \(images.count) photos show ONE meal. "
                    : ""
                var (candidate, diagnostics) = try await requestFoodAnalysisCandidates(
                    prompt: "\(multi)Analyze the food. Identify each item and provide the nutritional breakdown.\(context)",
                    imageData: images.first,
                    additionalImageData: Array(images.dropFirst()),
                    description: trimmedDescription,
                    hasImage: true
                )

                var parsed = candidate.parsed
                let validationDescription = trimmedDescription.isEmpty ? (parsed.mealName ?? "") : trimmedDescription
                if shouldRetrySuspiciousResult(parsed, description: validationDescription, hasImage: true) {
                    let retry = try await requestFoodAnalysisCandidates(
                        prompt: "Re-evaluate this photo and user context carefully. The previous estimate returned zero or near-zero carbs for a likely carb-containing meal. Return the same strict JSON object schema and break the meal into ingredients. User context: \(trimmedDescription)",
                        imageData: images.first,
                        additionalImageData: Array(images.dropFirst()),
                        description: validationDescription,
                        hasImage: true
                    )
                    candidate = retry.0
                    diagnostics = retry.1
                    parsed = candidate.parsed
                }
                guard !parsed.items.isEmpty,
                      !isSuspiciousZeroCarbResult(parsed, description: validationDescription, hasImage: true)
                else {
                    errorMessage = parsed.items.isEmpty
                        ? String(localized: "The photo could not be analyzed. Try a clearer photo, add a short meal description, or check whether your AI provider supports image input.", comment: "FoodFinder image analysis empty result error")
                        : String(localized: "The AI returned an implausible nutrition estimate. Add portion details and try again.", comment: "FoodFinder implausible estimate error")
                    return
                }

                var result = FoodAnalysisResult(
                    items: parsed.items,
                    rawResponse: candidate.rawResponse,
                    timestamp: Date(),
                    source: .aiCamera,
                    // Store only the first image to keep the recent-results
                    // payload small; the AI saw all of them.
                    imageData: images.first,
                    mealDescription: trimmedDescription.isEmpty ? nil : trimmedDescription,
                    mealName: parsed.mealName ?? trimmedDescription.aiInsightsNilIfEmpty,
                    mealPortion: parsed.mealPortion,
                    confidence: parsed.confidence
                )
                applyDoseGuardDiagnostics(diagnostics, to: &result)
                applyLearnedPortions(to: &result)
                currentResult = result
                recentResults.insert(result, at: 0)
                saveRecentResults()
                promoteIfFrequent(result)
                foodDescription = ""
                capturedImages.removeAll()

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
            barcodeStatusMessage = nil
            defer { isAnalyzing = false }

            do {
                guard var components = URLComponents(url: openFoodFactsProductURL(for: barcode), resolvingAgainstBaseURL: false) else {
                    setBarcodeError(String(localized: "Invalid barcode.", comment: "Barcode error"))
                    return
                }
                components.queryItems = [
                    URLQueryItem(name: "fields", value: "code,product_name,brands,nutriments,serving_size,serving_quantity,nutrition_data_completeness,image_url,url")
                ]
                guard let url = components.url else {
                    setBarcodeError(String(localized: "Invalid OpenFoodFacts URL.", comment: "Barcode error"))
                    return
                }

                var request = URLRequest(url: url)
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                request.setValue("TrioAIInsights/\(appVersion) (https://github.com/pov-it/Trio)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    setBarcodeError(String(localized: "Product not found in OpenFoodFacts.", comment: "Barcode error"))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Int(doubleValue(json["status"])) == 1,
                      let product = json["product"] as? [String: Any]
                else {
                    setBarcodeError(String(localized: "Product not found. Try the AI Camera instead.", comment: "Barcode error"))
                    return
                }

                let name = stringValue(product["product_name"], fallback: String(localized: "Unknown Product", comment: "Unknown barcode product"))
                let serving = stringValue(product["serving_size"], fallback: String(localized: "1 serving", comment: "Default food serving"))
                let nutriments = product["nutriments"] as? [String: Any] ?? [:]

                let carbs = nutrientValue(["carbohydrates_serving", "carbohydrates_100g"], in: nutriments)
                let fat = nutrientValue(["fat_serving", "fat_100g"], in: nutriments)
                let protein = nutrientValue(["proteins_serving", "proteins_100g"], in: nutriments)
                let fiber = nutrientValue(["fiber_serving", "fiber_100g"], in: nutriments)
                let calories = nutrientValue(["energy-kcal_serving", "energy-kcal_100g"], in: nutriments)

                let item = openFoodFactsLookupResult(from: product, fallbackName: name)
                    .map { foodItem(from: $0, fallbackName: $0.name, existingPortion: serving) }
                    ?? FoodItem(
                        name: name,
                        portion: serving,
                        carbs: carbs,
                        fat: fat,
                        protein: protein,
                        fiber: fiber,
                        calories: calories,
                        source: .openFoodFacts,
                        sourceVerified: true
                    )

                let result = FoodAnalysisResult(
                    items: [item],
                    rawResponse: nil,
                    timestamp: Date(),
                    source: .barcode,
                    imageData: nil,
                    mealDescription: name,
                    mealName: name,
                    mealPortion: serving,
                    confidence: 0.95
                )
                currentResult = result
                lastAddedFoodItemID = item.id
                setBarcodeSuccess(
                    String(
                        format: String(localized: "Scanned %@", comment: "Barcode product scanned success"),
                        item.name
                    )
                )
                recentResults.insert(result, at: 0)
                saveRecentResults()

            } catch {
                setBarcodeError(String(localized: "Network error looking up barcode: \(error.localizedDescription)", comment: "Barcode error"))
            }
        }

        private func setBarcodeError(_ message: String) {
            errorMessage = message
            barcodeStatusMessage = message
            barcodeStatusIsSuccess = false
        }

        private func setBarcodeSuccess(_ message: String) {
            barcodeStatusMessage = message
            barcodeStatusIsSuccess = true
        }

        // MARK: - Dictation

        @MainActor
        func toggleDictation() {
            guard !isTranscribingDictation else { return }
            isDictating ? stopDictation() : startDictation()
        }

        @MainActor
        func stopDictation() {
            if isUsingAIDictation {
                stopAIDictationRecording()
                return
            }

            let preservedText = foodDescription
            audioEngine.stop()
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            if hasAudioTap {
                audioEngine.inputNode.removeTap(onBus: 0)
                hasAudioTap = false
            }
            recognitionRequest = nil
            recognitionTask = nil
            if foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !preservedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                foodDescription = preservedText
            }
            isDictating = false
        }

        @MainActor
        private func startDictation() {
            if aiDictationEnabled, !effectiveDictationAPIKey.isEmpty {
                startAIDictationRecording()
                return
            }
            startAppleDictation()
        }

        @MainActor
        private func startAppleDictation() {
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

        @MainActor
        private func startAIDictationRecording() {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard granted else {
                        self.errorMessage = String(localized: "Microphone permission is required for dictation.", comment: "Microphone permission error")
                        return
                    }
                    self.beginAIDictationRecording()
                }
            }
        }

        @MainActor
        private func beginAIDictationRecording() {
            stopDictation()

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("foodfinder-dictation-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.prepareToRecord()
                recorder.record()
                aiAudioRecorder = recorder
                aiDictationAudioURL = url
                isUsingAIDictation = true
                isDictating = true
            } catch {
                errorMessage = String(localized: "Could not start AI dictation: \(error.localizedDescription)", comment: "AI dictation start error")
                startAppleDictation()
            }
        }

        @MainActor
        private func stopAIDictationRecording() {
            aiAudioRecorder?.stop()
            aiAudioRecorder = nil
            isDictating = false
            isUsingAIDictation = false
            guard let url = aiDictationAudioURL else { return }
            aiDictationAudioURL = nil
            isTranscribingDictation = true

            Task {
                await transcribeAIDictationAudio(from: url)
            }
        }

        @MainActor
        private func transcribeAIDictationAudio(from url: URL) async {
            defer {
                isTranscribingDictation = false
                try? FileManager.default.removeItem(at: url)
            }

            do {
                let audioData = try Data(contentsOf: url)
                let transcript = try await AIServiceAdapter.transcribeAudio(
                    audioData: audioData,
                    mimeType: "audio/mp4",
                    provider: effectiveDictationProviderType,
                    model: effectiveDictationModel,
                    baseURL: effectiveDictationBaseURL,
                    apiKey: effectiveDictationAPIKey,
                    languageHint: Locale.preferredLanguages.first ?? Locale.current.identifier
                )
                appendDictationTranscript(transcript)
            } catch {
                do {
                    let fallback = try await transcribeWithAppleSpeechFile(url)
                    appendDictationTranscript(fallback)
                } catch {
                    errorMessage = String(localized: "Could not transcribe dictation: \(error.localizedDescription)", comment: "Dictation transcription error")
                }
            }
        }

        private var effectiveDictationProviderType: AIProvider {
            aiDictationUsesSeparateProvider ? aiDictationProviderType : providerType
        }

        private var effectiveDictationModel: String {
            let candidate = aiDictationModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
            return effectiveDictationProviderType.defaultDictationModel
        }

        private var effectiveDictationBaseURL: String {
            aiDictationUsesSeparateProvider ? aiDictationBaseURL : baseURL
        }

        private var effectiveDictationAPIKey: String {
            guard aiDictationUsesSeparateProvider else { return apiKey }
            let separateKey = aiDictationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return separateKey.isEmpty ? apiKey : separateKey
        }

        @MainActor
        private func appendDictationTranscript(_ transcript: String) {
            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }

            let existing = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            foodDescription = existing.isEmpty ? cleaned : "\(existing) \(cleaned)"
        }

        private func transcribeWithAppleSpeechFile(_ url: URL) async throws -> String {
            try await requestAppleSpeechAuthorization()
            return try await withCheckedThrowingContinuation { continuation in
                guard let recognizer = speechRecognizer else {
                    continuation.resume(throwing: AIServiceAdapter.AIError.parsingError("Speech recognizer is unavailable"))
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = false
                var didResume = false
                recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal, !didResume {
                        didResume = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if let error, !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func requestAppleSpeechAuthorization() async throws {
            try await withCheckedThrowingContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    if status == .authorized {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: AIServiceAdapter.AIError.parsingError("Speech recognition permission is required"))
                    }
                }
            }
        }

        // MARK: - Parsing Helpers

        private func foodFinderCandidateCount(hasImage: Bool) -> Int {
            guard foodFinderDoseGuardEnabled else { return 1 }
            // Vision estimates are where stochastic portion drift hurts most,
            // but text-only meals also benefit when the user gives an
            // ambiguous restaurant-style description.
            let requested = min(3, max(1, foodFinderDoseGuardSamples))
            return hasImage ? requested : min(2, requested)
        }

        private func requestFoodAnalysisCandidates(
            prompt: String,
            imageData: Data?,
            additionalImageData: [Data] = [],
            description: String,
            hasImage: Bool
        ) async throws -> (FoodAnalysisCandidate, FoodDoseGuardDiagnostics) {
            let count = foodFinderCandidateCount(hasImage: hasImage)
            var candidates: [FoodAnalysisCandidate] = []
            var lastError: Error?

            for _ in 0 ..< count {
                do {
                    let response = try await requestFoodAnalysis(
                        prompt: prompt,
                        imageData: imageData,
                        additionalImageData: additionalImageData
                    )
                    var parsed = parseFoodAnalysis(from: response)
                    parsed.items = await enrichFoodItemsWithLookup(parsed.items)
                    candidates.append(FoodAnalysisCandidate(parsed: parsed, rawResponse: response))
                } catch {
                    lastError = error
                }
            }

            guard !candidates.isEmpty else {
                throw lastError ?? AIServiceAdapter.AIError.noContent
            }

            let usable = candidates.filter {
                !$0.parsed.items.isEmpty &&
                    !isSuspiciousZeroCarbResult($0.parsed, description: description, hasImage: hasImage)
            }
            let pool = usable.isEmpty ? candidates : usable
            let sorted = pool.sorted { $0.totalCarbs < $1.totalCarbs }
            let applied = foodFinderDoseGuardEnabled && sorted.count > 1
            let selected = applied
                ? sorted[max(0, Int(floor(Double(sorted.count - 1) * 0.25)))]
                : pool[0]

            let lower = sorted.first?.totalCarbs
            let upper = sorted.last?.totalCarbs
            let uncertaintyUnits: Double? = {
                guard let lower, let upper else { return nil }
                // Report the full carb spread translated to insulin units at
                // I:C 1:10, matching the safety metric used in the papers.
                return max(0, upper - lower) / 10.0
            }()

            return (
                selected,
                FoodDoseGuardDiagnostics(
                    lowerBound: lower,
                    upperBound: upper,
                    uncertaintyUnits: uncertaintyUnits,
                    candidateCount: candidates.count,
                    applied: applied
                )
            )
        }

        private func applyDoseGuardDiagnostics(
            _ diagnostics: FoodDoseGuardDiagnostics,
            to result: inout FoodAnalysisResult
        ) {
            result.carbEstimateLowerBound = diagnostics.lowerBound
            result.carbEstimateUpperBound = diagnostics.upperBound
            result.carbEstimateUncertaintyUnits = diagnostics.uncertaintyUnits
            result.analysisCandidateCount = diagnostics.candidateCount
            result.doseGuardApplied = diagnostics.applied

            guard diagnostics.applied,
                  let lower = diagnostics.lowerBound,
                  let upper = diagnostics.upperBound,
                  upper > lower
            else { return }

            let relativeSpread = (upper - lower) / max(upper, 1)
            let baseConfidence = result.confidence ?? 0.65
            result.confidence = max(0.1, baseConfidence * (1 - min(0.45, relativeSpread * 0.6)))
        }

        private func requestFoodAnalysis(
            prompt: String,
            imageData: Data?,
            additionalImageData: [Data] = []
        ) async throws -> String {
            let request = AIServiceAdapter.AIRequest(
                model: model,
                messages: [
                    AIServiceAdapter.ChatMessagePayload(role: .system, content: foodFinderSystemPrompt),
                    AIServiceAdapter.ChatMessagePayload(role: .user, content: prompt)
                ],
                temperature: 0.0,
                topP: 0.85,
                topK: nil,
                maxTokens: 2048,
                imageData: imageData,
                additionalImageData: additionalImageData,
                responseFormat: foodFinderResponseFormat
            )

            let response = try await AIServiceAdapter.send(
                request: request,
                provider: providerType,
                baseURL: baseURL,
                apiKey: apiKey
            )
            return response.text
        }

        private func searchIngredient(named name: String, existingPortion: String?) async throws -> FoodItem? {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if isFoodLookupAgentEnabled {
                let matches = await lookupFoodSources(query: trimmed)
                if let best = bestLookupMatch(
                    for: FoodItem(
                        name: trimmed,
                        portion: existingPortion ?? String(localized: "1 serving", comment: "Default food serving"),
                        carbs: 0,
                        fat: 0,
                        protein: 0,
                        fiber: 0,
                        calories: 0
                    ),
                    from: matches
                ) {
                    return foodItem(from: best, fallbackName: trimmed, existingPortion: existingPortion)
                }
            }

            let portionHint = existingPortion.map { " Keep this portion if it still makes sense: \($0)." } ?? ""
            let responseText = try await requestFoodAnalysis(
                prompt: "Analyze this single ingredient or food item and return exactly one item in the strict JSON object schema. Item: \(trimmed).\(portionHint)",
                imageData: nil
            )
            return parseFoodAnalysis(from: responseText).items.first
        }

        private func lookupOpenFoodFactsResults(_ query: String) async throws -> [FoodLookupResult] {
            guard var components = URLComponents(url: openFoodFactsSearchURL(), resolvingAgainstBaseURL: false) else {
                return []
            }
            components.queryItems = [
                URLQueryItem(name: "search_terms", value: query),
                URLQueryItem(name: "fields", value: "code,product_name,brands,nutriments,serving_size,serving_quantity,nutrition_data_completeness,image_url,url"),
                URLQueryItem(name: "page_size", value: "5"),
                URLQueryItem(name: "json", value: "1")
            ]
            guard let url = components.url else { return [] }

            var request = URLRequest(url: url)
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            request.setValue("TrioAIInsights/\(appVersion) (https://github.com/pov-it/Trio)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let products = json["products"] as? [[String: Any]]
            else {
                return []
            }

            return products.compactMap { openFoodFactsLookupResult(from: $0, fallbackName: query) }
        }

        private func openFoodFactsLookupResult(from product: [String: Any], fallbackName: String) -> FoodLookupResult? {
            let name = stringValue(product["product_name"], fallback: fallbackName)
            guard name != fallbackName || product["nutriments"] != nil else { return nil }
            let serving = stringValue(product["serving_size"], fallback: String(localized: "1 serving", comment: "Default food serving"))
            let nutriments = product["nutriments"] as? [String: Any] ?? [:]
            let completeness = min(1, max(0.35, doubleValue(product["nutrition_data_completeness"])))
            let code = stringValue(product["code"], fallback: "")
            let servingQuantity = doubleValue(product["serving_quantity"])
            let sourceURL: URL? = {
                if let raw = product["url"] as? String, let url = URL(string: raw) {
                    return url
                }
                if !code.isEmpty {
                    return URL(string: "https://world.openfoodfacts.org/product/\(code)")
                }
                return nil
            }()

            return FoodLookupResult(
                sourceID: .openFoodFacts,
                name: name,
                brand: stringValue(product["brands"], fallback: "").aiInsightsNilIfEmpty,
                portion: serving,
                portionGrams: gramsFromPortion(serving) ?? (servingQuantity > 0 ? servingQuantity : nil),
                carbs: nutrientValue(["carbohydrates_serving", "carbohydrates_100g"], in: nutriments),
                fat: nutrientValue(["fat_serving", "fat_100g"], in: nutriments),
                protein: nutrientValue(["proteins_serving", "proteins_100g"], in: nutriments),
                fiber: nutrientValue(["fiber_serving", "fiber_100g"], in: nutriments),
                calories: nutrientValue(["energy-kcal_serving", "energy-kcal_100g"], in: nutriments),
                sourceURL: sourceURL,
                verifiedScore: completeness,
                imageURL: (product["image_url"] as? String).flatMap(URL.init(string:))
            )
        }

        private func lookupUSDAResults(_ query: String) async throws -> [FoodLookupResult] {
            let apiKey = foodFinderUSDAAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else { return [] }

            var components = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search")
            components?.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "pageSize", value: "5"),
                URLQueryItem(name: "api_key", value: apiKey)
            ]
            guard let url = components?.url else { return [] }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let foods = json["foods"] as? [[String: Any]]
            else {
                return []
            }

            return foods.compactMap { usdaLookupResult(from: $0, fallbackName: query) }
        }

        private func usdaLookupResult(from food: [String: Any], fallbackName: String) -> FoodLookupResult? {
            let name = stringValue(food["description"], fallback: fallbackName)
            let fdcId = Int(doubleValue(food["fdcId"]))
            let nutrients = food["foodNutrients"] as? [[String: Any]] ?? []
            let servingSize = doubleValue(food["servingSize"])
            let servingUnit = stringValue(food["servingSizeUnit"], fallback: "g")
            let grams = servingSize > 0 ? servingSize : 100
            let portion = servingSize > 0
                ? "\(String(format: "%.0f", servingSize)) \(servingUnit)"
                : String(localized: "100 g", comment: "USDA default portion")
            let score = stringValue(food["dataType"], fallback: "").localizedCaseInsensitiveContains("foundation") ? 0.9 : 0.78

            return FoodLookupResult(
                sourceID: .usda,
                name: name,
                brand: stringValue(food["brandOwner"], fallback: "").aiInsightsNilIfEmpty,
                portion: portion,
                portionGrams: grams,
                carbs: usdaNutrient(["Carbohydrate, by difference", "Carbohydrate"], in: nutrients),
                fat: usdaNutrient(["Total lipid (fat)", "Total Fat"], in: nutrients),
                protein: usdaNutrient(["Protein"], in: nutrients),
                fiber: usdaNutrient(["Fiber, total dietary", "Fiber"], in: nutrients),
                calories: usdaNutrient(["Energy"], in: nutrients),
                sourceURL: fdcId > 0 ? URL(string: "https://fdc.nal.usda.gov/fdc-app.html#/food-details/\(fdcId)/nutrients") : nil,
                verifiedScore: score,
                imageURL: nil
            )
        }

        private func shouldRetrySuspiciousResult(_ parsed: ParsedFoodAnalysis, description: String, hasImage: Bool) -> Bool {
            isSuspiciousZeroCarbResult(parsed, description: description, hasImage: hasImage)
        }

        private func isSuspiciousZeroCarbResult(_ parsed: ParsedFoodAnalysis, description: String, hasImage: Bool) -> Bool {
            let totalCarbs = parsed.items.reduce(0) { $0 + $1.adjustedCarbs }
            guard totalCarbs <= 0.5 else { return false }

            let text = "\(description) \(parsed.mealName ?? "") \(parsed.items.map(\.name).joined(separator: " "))"
                .lowercased()
            let likelyCarbWords = [
                "spaghetti", "pasta", "noodle", "rice", "risotto", "bread", "toast", "bun", "bagel",
                "pizza", "potato", "fries", "banana", "apple", "fruit", "oat", "cereal", "granola",
                "cake", "cookie", "dessert", "wrap", "tortilla", "sandwich", "sushi", "dumpling"
            ]

            if likelyCarbWords.contains(where: { text.contains($0) }) {
                return true
            }

            return hasImage &&
                !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                (parsed.confidence ?? 0) < 0.35
        }

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

        private func openFoodFactsSearchURL() -> URL {
            var trimmed = openFoodFactsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            let base = trimmed.isEmpty ? AIInsights.defaultOpenFoodFactsBaseURL : trimmed
            let normalizedBase = base.hasSuffix("/api/v2") ? base : "\(base)/api/v2"
            return URL(string: "\(normalizedBase)/search")
                ?? URL(string: "\(AIInsights.defaultOpenFoodFactsBaseURL)/search")!
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

        private func usdaNutrient(_ names: [String], in nutrients: [[String: Any]]) -> Double {
            for name in names {
                if let nutrient = nutrients.first(where: { entry in
                    let nutrientName = stringValue(entry["nutrientName"] ?? entry["name"], fallback: "")
                    return nutrientName.localizedCaseInsensitiveContains(name)
                }) {
                    return doubleValue(nutrient["value"] ?? nutrient["amount"])
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
