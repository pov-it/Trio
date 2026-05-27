import Foundation
import Observation
import Swinject

extension AIInsights {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var isGenerating: Bool = false
        var insightsResult: String = ""
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
        var systemPrompt: String = AIInsights.defaultChatSystemPrompt
        var personality: AIPersonality = .clinicalExpert
        var analysisPeriodDays: Int = 7
        var aiEnabled: Bool = false
        var openFoodFactsBaseURL: String = AIInsights.defaultOpenFoodFactsBaseURL
        var foodFinderLookupMode: FoodFinderLookupMode = .verifiedAgent
        var foodFinderOpenFoodFactsEnabled: Bool = true
        var foodFinderUSDAEnabled: Bool = false
        var foodFinderPreferredSource: FoodSourceID = .openFoodFacts
        var foodFinderUSDAAPIKey: String = ""
        var locationContextEnabled: Bool = false
        var healthKitCaffeineEnabled: Bool = false
        var healthKitAlcoholEnabled: Bool = false

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
            systemPrompt = AIInsights.migratingSystemPrompt(provider.settings.aiSystemPrompt)
            personality = provider.settings.aiPersonality
            analysisPeriodDays = provider.settings.aiAnalysisPeriodDays
            aiEnabled = provider.settings.aiEnabled
            openFoodFactsBaseURL = provider.settings.openFoodFactsBaseURL
            foodFinderLookupMode = provider.settings.foodFinderLookupMode
            foodFinderOpenFoodFactsEnabled = provider.settings.foodFinderOpenFoodFactsEnabled
            foodFinderUSDAEnabled = provider.settings.foodFinderUSDAEnabled
            foodFinderPreferredSource = provider.settings.foodFinderPreferredSource
            locationContextEnabled = provider.settings.aiLocationContextEnabled
            healthKitCaffeineEnabled = provider.settings.aiHealthKitCaffeineEnabled
            healthKitAlcoholEnabled = provider.settings.aiHealthKitAlcoholEnabled

            // Wire the location service's gate to the live settings value so the
            // singleton can self-check before geocoding or emitting prompt context.
            AIInsights_LocationService.shared.isEnabledProvider = { [weak self] in
                self?.provider?.settings.aiLocationContextEnabled ?? false
            }
        }

        func saveAPIKey() {
            guard provider != nil else { return }
            provider.keychain.setValue(apiKey, forKey: "ai_insights_api_key")
        }

        func saveDictationAPIKey() {
            guard provider != nil else { return }
            provider.keychain.setValue(aiDictationAPIKey, forKey: "ai_insights_dictation_api_key")
        }

        func saveFoodFinderUSDAAPIKey() {
            guard provider != nil else { return }
            provider.keychain.setValue(foodFinderUSDAAPIKey, forKey: "ai_foodfinder_usda_api_key")
        }

        func saveSettings() {
            guard provider != nil else { return }

            var settings = provider.settings
            settings.aiProvider = providerType
            settings.aiModel = model
            settings.aiBaseURL = baseURL
            settings.aiDictationEnabled = aiDictationEnabled
            settings.aiDictationUsesSeparateProvider = aiDictationUsesSeparateProvider
            settings.aiDictationProvider = aiDictationProviderType
            settings.aiDictationModel = aiDictationModel
            settings.aiDictationBaseURL = aiDictationBaseURL
            settings.aiSystemPrompt = systemPrompt
            settings.aiPersonality = personality
            settings.aiAnalysisPeriodDays = analysisPeriodDays
            settings.aiEnabled = aiEnabled
            settings.openFoodFactsBaseURL = openFoodFactsBaseURL
            settings.foodFinderLookupMode = foodFinderLookupMode
            settings.foodFinderOpenFoodFactsEnabled = foodFinderOpenFoodFactsEnabled
            settings.foodFinderUSDAEnabled = foodFinderUSDAEnabled
            settings.foodFinderPreferredSource = foodFinderPreferredSource
            settings.aiLocationContextEnabled = locationContextEnabled
            settings.aiHealthKitCaffeineEnabled = healthKitCaffeineEnabled
            settings.aiHealthKitAlcoholEnabled = healthKitAlcoholEnabled
            provider.settings = settings
        }

        func resetToDefaults() {
            baseURL = providerType.defaultEndpoint
            model = providerType.defaultModel
            if !aiDictationUsesSeparateProvider {
                aiDictationModel = providerType.defaultDictationModel
            }
            systemPrompt = AIInsights.defaultChatSystemPrompt
            saveSettings()
        }

        func resetDictationDefaults() {
            let dictationProvider = aiDictationUsesSeparateProvider ? aiDictationProviderType : providerType
            aiDictationBaseURL = dictationProvider.defaultEndpoint
            aiDictationModel = dictationProvider.defaultDictationModel
            saveSettings()
        }

        func resetOpenFoodFactsURL() {
            openFoodFactsBaseURL = AIInsights.defaultOpenFoodFactsBaseURL
            saveSettings()
        }

        @MainActor
        func generateInsights() async {
            guard provider != nil else {
                insightsResult = String(localized: "Error: AI Insights is not ready yet.", comment: "AI error")
                return
            }

            guard !apiKey.isEmpty else {
                insightsResult = String(localized: "Error: API Key is missing.", comment: "AI error")
                return
            }

            isGenerating = true
            defer { isGenerating = false }

            do {
                let startDate = Date().addingTimeInterval(-24 * 3600)
                let glucose = await provider.fetchGlucose(since: startDate)
                let carbs = await provider.fetchCarbs(since: startDate)

                let dataContext = """
                Glucose (last 24h): \(glucose.map { "\($0.dateString): \($0.glucose ?? $0.sgv ?? 0) \($0.direction?.rawValue ?? "")" }.joined(separator: "\n"))
                Carbs: \(carbs.map { "\($0.createdAt): \($0.carbs)g" }.joined(separator: "\n"))
                """

                let personalitySuffix = personality.systemPromptSuffix
                let fullPrompt = "\(systemPrompt)\n\n\(AIInsights.responseLanguageInstruction())\n\nPERSONALITY: \(personalitySuffix)\n\nData:\n\(dataContext)"

                let request = AIServiceAdapter.AIRequest(
                    model: model,
                    messages: [
                        AIServiceAdapter.ChatMessagePayload(role: .user, content: fullPrompt)
                    ],
                    temperature: 0.7,
                    topP: nil,
                    topK: nil,
                    maxTokens: 2048
                )

                let response = try await AIServiceAdapter.send(
                    request: request,
                    provider: providerType,
                    baseURL: baseURL,
                    apiKey: apiKey
                )

                insightsResult = response.text

            } catch let error as AIServiceAdapter.AIError {
                insightsResult = error.errorDescription ?? error.localizedDescription
            } catch {
                insightsResult = String(localized: "Error generating insights: \(error.localizedDescription)", comment: "AI error")
            }
        }
    }
}
