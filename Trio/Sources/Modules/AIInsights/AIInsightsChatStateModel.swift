import Foundation
import Observation
import Swinject

extension AIInsights {
    @Observable final class ChatStateModel: BaseStateModel<Provider> {
        var messages: [ChatMessage] = []
        var isGenerating: Bool = false
        var errorMessage: String?
        var apiKey: String = ""
        var providerType: AIProvider = .google
        var model: String = AIProvider.google.defaultModel
        var baseURL: String = AIProvider.google.defaultEndpoint
        var systemPrompt: String = AIInsights.defaultSystemPrompt
        var personality: AIPersonality = .clinicalExpert
        var analysisPeriodDays: Int = 7
        var aiEnabled: Bool = false

        // Live status from Trio
        var currentIOB: Double?

        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }

            providerType = provider.settings.aiProvider
            model = provider.settings.aiModel
            baseURL = provider.settings.aiBaseURL
            systemPrompt = provider.settings.aiSystemPrompt
            personality = provider.settings.aiPersonality
            analysisPeriodDays = provider.settings.aiAnalysisPeriodDays
            aiEnabled = provider.settings.aiEnabled

            // Load live status
            currentIOB = provider.currentIOB
            
            loadMessages()
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
            provider.settings = settings
        }

        func resetToDefaults() {
            baseURL = providerType.defaultEndpoint
            model = providerType.defaultModel
            saveSettings()
        }

        // MARK: - Persistence

        func saveMessages() {
            if let data = try? JSONEncoder().encode(messages) {
                UserDefaults.standard.set(data, forKey: "ai_insights_chat_history")
            }
        }

        func loadMessages() {
            if let data = UserDefaults.standard.data(forKey: "ai_insights_chat_history"),
               let savedMessages = try? JSONDecoder().decode([ChatMessage].self, from: data)
            {
                messages = savedMessages
            }
        }

        // MARK: - Chat Actions

        func sendHintChip(_ chip: HintChip) {
            let userMessage = ChatMessage(
                content: chip.localizedTitle,
                isUser: true,
                timestamp: Date(),
                hintChip: chip
            )
            messages.append(userMessage)
            saveMessages()
            Task {
                await generateResponse(for: chip.localizedTitle)
            }
        }

        func sendUserMessage(_ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let userMessage = ChatMessage(
                content: text,
                isUser: true,
                timestamp: Date()
            )
            messages.append(userMessage)
            saveMessages()
            Task {
                await generateResponse(for: text)
            }
        }

        func clearChat() {
            messages = []
            errorMessage = nil
            saveMessages()
        }

        // MARK: - AI Response Generation

        @MainActor
        private func generateResponse(for input: String) async {
            guard provider != nil else {
                errorMessage = String(localized: "AI Insights is not ready yet.", comment: "AI error")
                return
            }

            guard !apiKey.isEmpty else {
                errorMessage = String(localized: "API Key is missing. Configure it in AI Settings.", comment: "AI error")
                return
            }

            isGenerating = true
            errorMessage = nil
            defer { isGenerating = false }

            do {
                // Fetch data
                let glucose = await provider.fetchGlucose(since: Date().addingTimeInterval(-Double(analysisPeriodDays) * 24 * 3600))
                let carbs = await provider.fetchCarbs()

                // Aggregate stats
                let basalProfile = await provider.getBasalProfile()
                let isf = await provider.getISF()
                let cr = await provider.getCR()
                let target = await provider.getTarget()

                let stats = DataAggregator.aggregate(
                    glucose: glucose,
                    carbs: carbs,
                    basalProfile: basalProfile,
                    isf: isf,
                    cr: cr,
                    target: target,
                    units: provider.units,
                    iob: currentIOB,
                    cob: nil,
                    periodDays: analysisPeriodDays,
                    lowThreshold: provider.settings.low,
                    highThreshold: provider.settings.high
                )

                // Build context-aware prompt
                let contextPrompt = buildContextPrompt(stats: stats, input: input)

                // Build messages payload — limit to last 10 messages to avoid exceeding
                // the model's context window. The system prompt already contains the full
                // data context, so older chat messages are less critical.
                let recentMessages = messages.suffix(10)
                let chatHistory = recentMessages.map { msg -> AIServiceAdapter.ChatMessagePayload in
                    AIServiceAdapter.ChatMessagePayload(
                        role: msg.isUser ? .user : .assistant,
                        content: msg.content
                    )
                }

                let request = AIServiceAdapter.AIRequest(
                    model: model,
                    messages: [
                        AIServiceAdapter.ChatMessagePayload(role: .system, content: contextPrompt),
                    ] + chatHistory,
                    temperature: 0.7,
                    topP: 0.95,
                    topK: nil,
                    maxTokens: 2048
                )

                let response = try await AIServiceAdapter.send(
                    request: request,
                    provider: providerType,
                    baseURL: baseURL,
                    apiKey: apiKey
                )

                let assistantMessage = ChatMessage(
                    content: response.text,
                    isUser: false,
                    timestamp: Date()
                )
                messages.append(assistantMessage)
                saveMessages()

            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        // MARK: - Prompt Engineering

        private func buildContextPrompt(stats: AggregatedStats, input: String) -> String {
            let unitsStr = provider.units.rawValue
            let personalitySuffix = personality.systemPromptSuffix

            var prompt = """
            \(systemPrompt)

            PERSONALITY: \(personalitySuffix)

            You are analyzing data from a Trio (OpenAPS-based) closed-loop insulin delivery system.
            The algorithm uses oref0/oref1 for determining basal rates, temporary basals, and SMB (Super Micro Bolus) decisions.
            Therapy settings in Trio are: Basal Rate schedule, Insulin Sensitivity Factor (ISF), Carb Ratio (CR), and Glucose Targets.

            SAFETY RULES:
            - Never suggest changes exceeding ±20% from current values
            - Conservative bias: under-adjust rather than over-adjust
            - Always include "Reasons not to change" section
            - If data is insufficient, say so clearly rather than guessing

            CURRENT DATA (last \(stats.periodDays) days):
            - Average glucose: \(String(format: "%.1f", stats.averageGlucose)) \(unitsStr)
            - GMI: \(String(format: "%.1f", stats.gmi))%
            - Time in Range: \(String(format: "%.1f", stats.tir.timeInRange))%
            - Time Below Low: \(String(format: "%.1f", stats.tir.timeBelowLow))%
            - Time Above High: \(String(format: "%.1f", stats.tir.timeAboveHigh))%
            - Glucose Std Dev: \(String(format: "%.1f", stats.glucoseStdDev)) \(unitsStr)
            - Average daily carbs: \(String(format: "%.0f", stats.averageDailyCarbs)) g

            DETECTED PATTERNS: \(stats.detectedPatterns.map(\.rawValue).joined(separator: ", "))

            HOURLY GLUCOSE AVERAGES:
            \(stats.hourlyGlucoseAverage.map { h in String(format: "%02d:00 — %.1f %s", h.hour, h.average, unitsStr) }.joined(separator: "\n"))

            CURRENT SETTINGS:
            - Basal Profile: \(stats.currentBasalProfile)
            - ISF: \(stats.currentISF)
            - Carb Ratio: \(stats.currentCR)
            - Target: \(stats.currentTarget)

            LIVE STATUS:
            """

            if let glucose = stats.currentGlucose {
                prompt += "- Current Glucose: \(String(format: "%.0f", glucose)) \(unitsStr)\n"
            }
            if let direction = stats.currentDirection {
                prompt += "- Direction: \(direction)\n"
            }
            if let iob = stats.currentIOB {
                prompt += "- IOB: \(String(format: "%.2f", iob)) U\n"
            }
            if let cob = stats.currentCOB {
                prompt += "- COB: \(String(format: "%.0f", cob)) g\n"
            }

            prompt += "\nUSER QUESTION: \(input)"

            return prompt
        }
    }
}