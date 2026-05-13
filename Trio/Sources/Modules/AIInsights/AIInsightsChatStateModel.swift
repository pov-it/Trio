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
        var systemPrompt: String = AIInsights.defaultChatSystemPrompt
        var personality: AIPersonality = .clinicalExpert
        var analysisPeriodDays: Int = 7
        var aiEnabled: Bool = false
        var knowledgeBase: String = ""
        var conversations: [ChatConversation] = []
        var activeConversationID: UUID = UUID()

        // Live status from Trio
        var currentIOB: Double?

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

            // Load live status
            currentIOB = provider.currentIOB
            
            loadConversations()
            startNewConversation()
            loadKnowledgeBase()
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
            systemPrompt = AIInsights.defaultChatSystemPrompt
            saveSettings()
        }

        // MARK: - Persistence

        func saveConversations() {
            if let data = try? JSONEncoder().encode(conversations) {
                UserDefaults.standard.set(data, forKey: "ai_insights_conversations")
            }
        }

        func loadConversations() {
            if let data = UserDefaults.standard.data(forKey: "ai_insights_conversations"),
               let savedConversations = try? JSONDecoder().decode([ChatConversation].self, from: data)
            {
                conversations = savedConversations.sorted { $0.updatedAt > $1.updatedAt }
                return
            }

            if let legacyData = UserDefaults.standard.data(forKey: "ai_insights_chat_history"),
               let legacyMessages = try? JSONDecoder().decode([ChatMessage].self, from: legacyData),
               !legacyMessages.isEmpty
            {
                conversations = [
                    ChatConversation(
                        title: title(for: legacyMessages),
                        messages: legacyMessages,
                        createdAt: legacyMessages.first?.timestamp ?? Date(),
                        updatedAt: legacyMessages.last?.timestamp ?? Date()
                    )
                ]
                saveConversations()
                UserDefaults.standard.removeObject(forKey: "ai_insights_chat_history")
            }
        }

        func saveMessages() {
            persistActiveConversation()
        }

        func saveKnowledgeBase() {
            UserDefaults.standard.set(knowledgeBase, forKey: "ai_insights_knowledge_base")
        }

        func loadKnowledgeBase() {
            knowledgeBase = UserDefaults.standard.string(forKey: "ai_insights_knowledge_base") ?? ""
        }

        // MARK: - Chat Actions

        func startNewConversation() {
            activeConversationID = UUID()
            messages = []
            errorMessage = nil
        }

        func selectConversation(_ conversation: ChatConversation) {
            activeConversationID = conversation.id
            messages = conversation.messages
            errorMessage = nil
        }

        func deleteConversation(_ conversation: ChatConversation) {
            conversations.removeAll { $0.id == conversation.id }
            saveConversations()
            if activeConversationID == conversation.id {
                startNewConversation()
            }
        }

        func filteredConversations(searchText: String) -> [ChatConversation] {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return conversations }
            return conversations.filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(query) ||
                    conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
            }
        }

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
            conversations.removeAll { $0.id == activeConversationID }
            saveConversations()
            startNewConversation()
        }

        private func persistActiveConversation() {
            guard !messages.isEmpty else { return }

            let now = Date()
            if let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) {
                conversations[idx].messages = messages
                conversations[idx].title = title(for: messages)
                conversations[idx].updatedAt = now
            } else {
                conversations.insert(
                    ChatConversation(
                        id: activeConversationID,
                        title: title(for: messages),
                        messages: messages,
                        createdAt: messages.first?.timestamp ?? now,
                        updatedAt: now
                    ),
                    at: 0
                )
            }

            conversations.sort { $0.updatedAt > $1.updatedAt }
            saveConversations()
        }

        private func title(for messages: [ChatMessage]) -> String {
            let firstUserMessage = messages.first(where: { $0.isUser })?.content ?? String(localized: "New conversation", comment: "AI chat title")
            let trimmed = firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return String(localized: "New conversation", comment: "AI chat title")
            }
            return String(trimmed.prefix(48))
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
                let startDate = Date().addingTimeInterval(-Double(analysisPeriodDays) * 24 * 3600)
                let glucose = await provider.fetchGlucose(since: startDate)
                let carbs = await provider.fetchCarbs(since: startDate)

                // Aggregate stats
                let basalProfile = await provider.getBasalProfile()
                let isf = await provider.getISF()
                let cr = await provider.getCR()
                let target = await provider.getTarget()
                let isfDescription = await provider.getISFDescription()
                let crDescription = await provider.getCRDescription()
                let targetDescription = await provider.getTargetDescription()

                let stats = DataAggregator.aggregate(
                    glucose: glucose,
                    carbs: carbs,
                    basalProfile: basalProfile,
                    isf: isf,
                    cr: cr,
                    target: target,
                    isfDescription: isfDescription,
                    crDescription: crDescription,
                    targetDescription: targetDescription,
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
                // the model's context window. 
                var chatHistory: [AIServiceAdapter.ChatMessagePayload] = []
                
                if messages.count > 10 {
                    chatHistory.append(AIServiceAdapter.ChatMessagePayload(
                        role: .assistant,
                        content: "[System note: Older conversation history has been compacted/omitted to save context window]"
                    ))
                }
                
                let recentMessages = messages.suffix(10)
                chatHistory += recentMessages.map { msg -> AIServiceAdapter.ChatMessagePayload in
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

                var responseText = response.text

                // Extract and process any <KNOWLEDGE> blocks updated by the AI
                if let knowledgeRange = responseText.range(of: "(?s)<KNOWLEDGE>(.*?)</KNOWLEDGE>", options: .regularExpression) {
                    let newKnowledge = String(responseText[knowledgeRange])
                        .replacingOccurrences(of: "<KNOWLEDGE>", with: "")
                        .replacingOccurrences(of: "</KNOWLEDGE>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !newKnowledge.isEmpty {
                        // The AI outputs the ENTIRE updated knowledge base, so we overwrite it completely
                        knowledgeBase = newKnowledge
                        saveKnowledgeBase()
                    }
                    // Remove the block so the user doesn't see the internal RAG working
                    responseText.removeSubrange(knowledgeRange)
                    responseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let assistantMessage = ChatMessage(
                    content: responseText,
                    isUser: false,
                    timestamp: Date(),
                    actions: suggestedActions(for: input, response: responseText)
                )
                messages.append(assistantMessage)
                saveMessages()

            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        private func suggestedActions(for input: String, response: String) -> [ChatAction] {
            let text = "\(input) \(response)".lowercased()
            var actions: [ChatAction] = []

            func append(_ action: ChatAction) {
                guard !actions.contains(where: { $0.destination == action.destination }) else { return }
                actions.append(action)
            }

            if text.contains("basal") || text.contains("basaal") || text.contains("night") || text.contains("nacht") {
                append(ChatAction(
                    title: String(localized: "Review in Therapy Insights", comment: "Chat action"),
                    systemImage: "waveform.path.ecg.rectangle.fill",
                    destination: .therapyInsights
                ))
                append(ChatAction(
                    title: String(localized: "Open Basal Rates", comment: "Chat action"),
                    systemImage: "slider.horizontal.3",
                    destination: .basalSettings
                ))
            }

            if text.contains("isf") || text.contains("sensitivity") || text.contains("gevoelig") {
                append(ChatAction(
                    title: String(localized: "Open Insulin Sensitivity", comment: "Chat action"),
                    systemImage: "syringe",
                    destination: .isfSettings
                ))
            }

            if text.contains("carb ratio") || text.contains("cr") || text.contains("koolhydraat") || text.contains("ratio") {
                append(ChatAction(
                    title: String(localized: "Open Carb Ratios", comment: "Chat action"),
                    systemImage: "fork.knife",
                    destination: .carbRatioSettings
                ))
            }

            if text.contains("meal") || text.contains("eten") || text.contains("food") || text.contains("carbs") || text.contains("koolhydraten") {
                append(ChatAction(
                    title: String(localized: "Open FoodFinder", comment: "Chat action"),
                    systemImage: "camera.viewfinder",
                    destination: .foodFinder
                ))
            }

            if actions.isEmpty, text.contains("setting") || text.contains("instelling") || text.contains("aanpassing") {
                append(ChatAction(
                    title: String(localized: "Open Therapy Settings", comment: "Chat action"),
                    systemImage: "gearshape.2",
                    destination: .therapySettings
                ))
            }

            return Array(actions.prefix(3))
        }

        // MARK: - Prompt Engineering

        private func buildContextPrompt(stats: AggregatedStats, input: String) -> String {
            let unitsStr = provider.units.rawValue
            let personalitySuffix = personality.systemPromptSuffix

            var prompt = """
            \(systemPrompt)

            \(AIInsights.responseLanguageInstruction())

            PERSONALITY: \(personalitySuffix)

            You are analyzing data from a Trio (OpenAPS-based) closed-loop insulin delivery system.
            The algorithm uses oref0/oref1 for determining basal rates, temporary basals, and SMB (Super Micro Bolus) decisions.
            Therapy settings in Trio are: Basal Rate schedule, Insulin Sensitivity Factor (ISF), Carb Ratio (CR), and Glucose Targets.

            SAFETY RULES:
            - Never suggest changes exceeding ±20% from current values
            - Conservative bias: under-adjust rather than over-adjust
            - Mention reasons not to change only when they matter for the user's question
            - If data is insufficient, say so clearly rather than guessing
            - When a setting review, meal analysis, or therapy edit would help, explicitly mention the next in-app view to open. The app may render those as interactive action cards.

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
            \(stats.hourlyGlucoseAverage.map { h in "\(String(format: "%02d:00", h.hour)) - \(String(format: "%.1f", h.average)) \(unitsStr)" }.joined(separator: "\n"))

            CURRENT SETTINGS:
            - Basal Profile: \(stats.currentBasalProfile)
            - ISF: \(stats.currentISF)
            - Carb Ratio: \(stats.currentCR)
            - Target: \(stats.currentTarget)
            """

            if !knowledgeBase.isEmpty {
                prompt += """

                USER PROFILE & KNOWLEDGE BASE (Continuously Updated):
                \(knowledgeBase)
                """
            }

            prompt += """

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

            prompt += """

            KNOWLEDGE BASE INSTRUCTION (RAG):
            You maintain a living, concise Knowledge Base about the user's demographic, lifestyle, diet, and habits.
            If the USER QUESTION implies new facts or changes to existing facts, you must REWRITE the ENTIRE Knowledge Base to include the new information, resolve any conflicting old information, and keep it compact (maximum 10 bullet points). 
            Output the newly updated complete knowledge base at the very end of your response, formatted exactly like this:
            
            <KNOWLEDGE>
            - [Fact 1]
            - [Fact 2]
            </KNOWLEDGE>
            
            Only output this block if the knowledge base needs to be updated. Do NOT output it if nothing has changed.

            USER QUESTION: \(input)
            """

            return prompt
        }
    }
}
