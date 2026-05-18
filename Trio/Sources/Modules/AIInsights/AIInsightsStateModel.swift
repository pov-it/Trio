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
        var systemPrompt: String = AIInsights.defaultChatSystemPrompt
        var personality: AIPersonality = .clinicalExpert
        var analysisPeriodDays: Int = 7
        var aiEnabled: Bool = false
        var openFoodFactsBaseURL: String = AIInsights.defaultOpenFoodFactsBaseURL
        var locationContextEnabled: Bool = false

        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }

            providerType = provider.settings.aiProvider
            model = provider.settings.aiModel
            baseURL = provider.settings.aiBaseURL
            systemPrompt = AIInsights.migratingSystemPrompt(provider.settings.aiSystemPrompt)
            personality = provider.settings.aiPersonality
            analysisPeriodDays = provider.settings.aiAnalysisPeriodDays
            aiEnabled = provider.settings.aiEnabled
            openFoodFactsBaseURL = provider.settings.openFoodFactsBaseURL
            locationContextEnabled = provider.settings.aiLocationContextEnabled

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

        func saveSettings() {
            guard provider != nil else { return }

            var settings = provider.settings
            settings.aiProvider = providerType
            settings.aiModel = model
            settings.aiBaseURL = baseURL
            settings.aiSystemPrompt = systemPrompt
            settings.aiPersonality = personality
            settings.aiAnalysisPeriodDays = analysisPeriodDays
            settings.aiEnabled = aiEnabled
            settings.openFoodFactsBaseURL = openFoodFactsBaseURL
            settings.aiLocationContextEnabled = locationContextEnabled
            provider.settings = settings
        }

        func resetToDefaults() {
            baseURL = providerType.defaultEndpoint
            model = providerType.defaultModel
            systemPrompt = AIInsights.defaultChatSystemPrompt
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
