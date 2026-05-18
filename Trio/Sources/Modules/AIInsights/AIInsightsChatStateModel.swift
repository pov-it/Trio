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
        var showApplyDisclaimer: Bool = false
        var pendingApplySuggestion: Suggestion?

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

            // Wire the location service gate to the live settings value (chat may open
            // without the settings view ever being shown, so we re-wire here too).
            AIInsights_LocationService.shared.isEnabledProvider = { [weak self] in
                self?.provider?.settings.aiLocationContextEnabled ?? false
            }
            // Fire a fresh location lookup if the user has opted in.
            AIInsights_LocationService.shared.requestLocationIfEnabled()

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

        func requestApply(_ suggestion: Suggestion) {
            pendingApplySuggestion = suggestion
            showApplyDisclaimer = true
        }

        @MainActor
        func confirmApply() async {
            guard let suggestion = pendingApplySuggestion else { return }
            showApplyDisclaimer = false
            pendingApplySuggestion = nil

            do {
                let beforeSnapshot = await provider.captureTherapySnapshot()
                try await provider.applySuggestion(suggestion)
                let afterSnapshot = await provider.captureTherapySnapshot()

                SuggestionHistoryStore.append(
                    SuggestionHistoryRecord(
                        suggestion: suggestion,
                        appliedAt: Date(),
                        status: .applied,
                        beforeSnapshot: beforeSnapshot,
                        afterSnapshot: afterSnapshot
                    )
                )
                messages = messages.map { $0 }
                saveMessages()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func cancelApply() {
            showApplyDisclaimer = false
            pendingApplySuggestion = nil
        }

        func dismissTherapySuggestion(_ suggestion: Suggestion) {
            let snapshot = TherapySnapshot(
                basalProfile: [],
                isfSensitivity: 0,
                carbRatio: 0,
                target: 0,
                capturedAt: Date(),
                insulinSensitivities: nil,
                carbRatios: nil,
                bgTargets: nil
            )
            SuggestionHistoryStore.append(
                SuggestionHistoryRecord(
                    suggestion: suggestion,
                    appliedAt: Date(),
                    status: .dismissed,
                    beforeSnapshot: snapshot,
                    afterSnapshot: snapshot
                )
            )
            removeTherapySuggestion(suggestion)
        }

        @MainActor
        func revertLatestMatchingSuggestion(_ suggestion: Suggestion) async {
            guard let record = SuggestionHistoryStore.load().first(where: { record in
                record.status == .applied &&
                    (record.suggestion.id == suggestion.id ||
                        (record.suggestion.settingType == suggestion.settingType &&
                            record.suggestion.timeBlock == suggestion.timeBlock &&
                            record.suggestion.proposedValue == suggestion.proposedValue))
            }) else {
                errorMessage = String(localized: "No applied matching suggestion was found to revert.", comment: "AI chat revert error")
                return
            }

            do {
                try await provider.restoreSnapshot(record.beforeSnapshot, for: record.suggestion.settingType)
                SuggestionHistoryStore.updateStatus(for: record.id, to: .reverted)
                messages = messages.map { $0 }
                saveMessages()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        @MainActor
        func addAdjustmentSuggestionToPresets(_ suggestion: AdjustmentSuggestion) async {
            do {
                try await provider.addAdjustmentSuggestionToPresets(suggestion)
                removeAdjustmentSuggestion(suggestion)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        @MainActor
        func startAdjustmentSuggestion(_ suggestion: AdjustmentSuggestion) async {
            do {
                try await provider.startAdjustmentSuggestion(suggestion)
                removeAdjustmentSuggestion(suggestion)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func dismissAdjustmentSuggestion(_ suggestion: AdjustmentSuggestion) {
            removeAdjustmentSuggestion(suggestion)
        }

        private func removeTherapySuggestion(_ suggestion: Suggestion) {
            for idx in messages.indices {
                guard var suggestions = messages[idx].therapySuggestions else { continue }
                suggestions.removeAll { $0.id == suggestion.id }
                messages[idx].therapySuggestions = suggestions.isEmpty ? nil : suggestions
            }
            saveMessages()
        }

        private func removeAdjustmentSuggestion(_ suggestion: AdjustmentSuggestion) {
            for idx in messages.indices {
                guard var suggestions = messages[idx].adjustmentSuggestions else { continue }
                suggestions.removeAll { $0.id == suggestion.id }
                messages[idx].adjustmentSuggestions = suggestions.isEmpty ? nil : suggestions
            }
            saveMessages()
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

                let allowTherapySuggestions = shouldOfferTherapySuggestions(for: input)
                let allowAdjustmentSuggestions = shouldOfferAdjustmentSuggestions(for: input)

                // Build context-aware prompt
                let contextPrompt = buildContextPrompt(
                    stats: stats,
                    input: input,
                    allowTherapySuggestions: allowTherapySuggestions,
                    allowAdjustmentSuggestions: allowAdjustmentSuggestions
                )

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
                    maxTokens: 8192
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
                } else if let start = responseText.range(of: "<KNOWLEDGE>") {
                    responseText.removeSubrange(start.lowerBound ..< responseText.endIndex)
                    responseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let structuredSuggestions = extractStructuredSuggestions(
                    from: &responseText,
                    allowTherapy: allowTherapySuggestions,
                    allowAdjustments: allowAdjustmentSuggestions
                )

                let assistantMessage = ChatMessage(
                    content: responseText,
                    isUser: false,
                    timestamp: Date(),
                    actions: nil,
                    therapySuggestions: structuredSuggestions.therapy.isEmpty ? nil : structuredSuggestions.therapy,
                    adjustmentSuggestions: structuredSuggestions.adjustments.isEmpty ? nil : structuredSuggestions.adjustments
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

            if text.contains("rise") || text.contains("rising") || text.contains("up") || text.contains("stijg") || text.contains("omhoog") || text.contains("hoger") || text.contains("high") || text.contains("hyper") {
                append(ChatAction(
                    title: String(localized: "Rising pattern", comment: "Chat action trend up"),
                    systemImage: "arrow.up.right.circle.fill",
                    destination: .risingPattern
                ))
            }

            if text.contains("drop") || text.contains("fall") || text.contains("falling") || text.contains("down") || text.contains("daal") || text.contains("omlaag") || text.contains("lager") || text.contains("low") || text.contains("hypo") {
                append(ChatAction(
                    title: String(localized: "Falling pattern", comment: "Chat action trend down"),
                    systemImage: "arrow.down.right.circle.fill",
                    destination: .fallingPattern
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

        // MARK: - Structured Suggestions

        private func shouldOfferTherapySuggestions(for input: String) -> Bool {
            let text = input.lowercased()
            let settingWords = [
                "setting", "settings", "instelling", "instellingen", "basal", "basaal",
                "isf", "sensitivity", "gevoelig", "carb ratio", "koolhydraat", "ratio"
            ]
            let changeWords = [
                "aanpassing", "aanpassingen", "verander", "veranderen", "wijzig", "wijzigen",
                "change", "adjust", "review", "suggest", "recommend", "advies", "voorstel"
            ]
            let patternWords = [
                "hypo", "low", "laag", "ochtend", "morning", "nacht", "night", "continu", "steeds", "waarom", "why"
            ]
            let mentionsSetting = settingWords.contains { text.contains($0) }
            let asksForChange = changeWords.contains { text.contains($0) }
            let asksAboutLowPattern = patternWords.contains { text.contains($0) } &&
                (text.contains("hypo") || text.contains("low") || text.contains("laag"))
            return (mentionsSetting && asksForChange) || asksAboutLowPattern
        }

        private func shouldOfferAdjustmentSuggestions(for input: String) -> Bool {
            let text = input.lowercased()
            let adjustmentWords = [
                "override", "overrides", "temporary target", "temp target", "tijdelijk streefdoel",
                "tijdelijke streefdoelen", "preset"
            ]
            let intentWords = [
                "aanpassing", "aanpassingen", "verander", "wijzig", "change", "adjust", "suggest",
                "recommend", "advies", "voorstel", "kan ik doen", "voorkom", "prevent", "prepare", "bereid"
            ]
            let contextWords = ["sport", "exercise", "training", "workout", "ziek", "sick", "hypo", "hyper", "ochtend", "morning"]
            let asksForPattern = ["waarom", "why", "continu", "steeds", "altijd", "often"].contains { text.contains($0) }
            let mentionsAdjustment = adjustmentWords.contains { text.contains($0) }
            let asksForAdjustment = intentWords.contains { text.contains($0) }
            let hasAdjustmentContext = contextWords.contains { text.contains($0) }
            let asksAboutLowPattern = asksForPattern && (text.contains("hypo") || text.contains("low") || text.contains("laag"))

            return mentionsAdjustment || (asksForAdjustment && hasAdjustmentContext) || asksAboutLowPattern
        }

        private func extractStructuredSuggestions(
            from responseText: inout String,
            allowTherapy: Bool,
            allowAdjustments: Bool
        ) -> (therapy: [Suggestion], adjustments: [AdjustmentSuggestion]) {
            guard let startTag = responseText.range(of: "<TRIO_SUGGESTIONS>") else {
                return ([], [])
            }

            let contentStart = startTag.upperBound
            let closingTag = responseText.range(of: "</TRIO_SUGGESTIONS>", range: contentStart ..< responseText.endIndex)
            let contentEnd = closingTag?.lowerBound ?? responseText.endIndex
            let removalEnd = closingTag?.upperBound ?? responseText.endIndex

            let jsonText = String(responseText[contentStart ..< contentEnd])
                .replacingOccurrences(of: "<TRIO_SUGGESTIONS>", with: "")
                .replacingOccurrences(of: "</TRIO_SUGGESTIONS>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            responseText.removeSubrange(startTag.lowerBound ..< removalEnd)
            responseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return ([], [])
            }

            let therapy = allowTherapy ? parseTherapySuggestions(object["therapySuggestions"]) : []
            let adjustments = allowAdjustments ? parseAdjustmentSuggestions(object["adjustmentSuggestions"]) : []
            return (therapy, adjustments)
        }

        private func parseTherapySuggestions(_ rawValue: Any?) -> [Suggestion] {
            guard let rawSuggestions = rawValue as? [[String: Any]] else { return [] }

            return rawSuggestions.compactMap { object in
                let type = parseSettingType(stringValue(from: object, keys: ["settingType", "setting_type", "type"]))
                let current = stringValue(from: object, keys: ["currentValue", "current_value"]) ?? ""
                let proposed = stringValue(from: object, keys: ["proposedValue", "proposed_value"]) ?? ""
                guard !current.isEmpty, !proposed.isEmpty else { return nil }

                return Suggestion(
                    settingType: type,
                    timeBlock: stringValue(from: object, keys: ["timeBlock", "time_block", "timeRange", "time_range"])
                        ?? String(localized: "General", comment: "General therapy time block"),
                    currentValue: current,
                    proposedValue: proposed,
                    reasoning: stringValue(from: object, keys: ["reasoning", "reason", "rationale"])
                        ?? String(localized: "No reasoning provided.", comment: "Therapy suggestion missing reasoning"),
                    confidence: confidenceValue(object["confidence"]),
                    createdAt: Date()
                )
            }
        }

        private func parseAdjustmentSuggestions(_ rawValue: Any?) -> [AdjustmentSuggestion] {
            guard let rawSuggestions = rawValue as? [[String: Any]] else { return [] }

            return rawSuggestions.compactMap { object in
                guard let kind = parseAdjustmentKind(stringValue(from: object, keys: ["kind", "type"])) else { return nil }
                let duration = intValue(object["durationMinutes"] ?? object["duration_minutes"]) ?? 0
                guard duration > 0 else { return nil }

                return AdjustmentSuggestion(
                    kind: kind,
                    name: stringValue(from: object, keys: ["name", "title"])
                        ?? kind.localizedTitle,
                    durationMinutes: duration,
                    targetValue: decimalValue(object["targetValue"] ?? object["target_value"] ?? object["target"]),
                    percentage: doubleValue(object["percentage"]),
                    smbIsOff: boolValue(object["smbIsOff"] ?? object["smb_is_off"]) ?? false,
                    isf: boolValue(object["isf"]) ?? false,
                    cr: boolValue(object["cr"]) ?? false,
                    reasoning: stringValue(from: object, keys: ["reasoning", "reason", "rationale"])
                        ?? String(localized: "No reasoning provided.", comment: "Adjustment suggestion missing reasoning"),
                    confidence: confidenceValue(object["confidence"]),
                    createdAt: Date()
                )
            }
        }

        private func parseSettingType(_ value: String?) -> Suggestion.SettingType {
            let normalized = (value ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            switch normalized {
            case let s where s.contains("basal"):
                return .basalRate
            case let s where s.contains("sensitivity") || s.contains("isf"):
                return .isf
            case let s where s.contains("carb") || s.contains("ratio") || s == "cr":
                return .carbRatio
            default:
                return .basalRate
            }
        }

        private func parseAdjustmentKind(_ value: String?) -> AdjustmentSuggestion.Kind? {
            let normalized = (value ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            if normalized.contains("override") { return .override }
            if normalized.contains("temp") || normalized.contains("target") || normalized.contains("streef") { return .tempTarget }
            return nil
        }

        private func stringValue(from object: [String: Any], keys: [String]) -> String? {
            for key in keys {
                if let string = object[key] as? String,
                   !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }

        private func decimalValue(_ value: Any?) -> Decimal? {
            if let number = value as? NSNumber {
                return number.decimalValue
            }
            if let string = value as? String {
                return Decimal(string: string.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
            }
            return nil
        }

        private func doubleValue(_ value: Any?) -> Double? {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let string = value as? String {
                return Double(string.replacingOccurrences(of: ",", with: "."))
            }
            return nil
        }

        private func intValue(_ value: Any?) -> Int? {
            if let number = value as? NSNumber {
                return number.intValue
            }
            if let string = value as? String {
                return Int(string)
            }
            return nil
        }

        private func boolValue(_ value: Any?) -> Bool? {
            if let bool = value as? Bool {
                return bool
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            if let string = value as? String {
                switch string.lowercased() {
                case "true", "yes", "ja", "1": return true
                case "false", "no", "nee", "0": return false
                default: return nil
                }
            }
            return nil
        }

        private func confidenceValue(_ value: Any?) -> Double {
            if let number = value as? NSNumber {
                return min(max(number.doubleValue, 0), 1)
            }
            if let string = value as? String {
                switch string.lowercased() {
                case "high": return 0.85
                case "medium": return 0.65
                case "low": return 0.35
                default:
                    return min(max(Double(string) ?? 0.5, 0), 1)
                }
            }
            return 0.5
        }

        // MARK: - Prompt Engineering

        private func buildContextPrompt(
            stats: AggregatedStats,
            input: String,
            allowTherapySuggestions: Bool,
            allowAdjustmentSuggestions: Bool
        ) -> String {
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
            - Use inline trend tokens in prose when helpful: (arrowUp), (arrowDown), (arrowFlat), (arrowDoubleUp), (arrowDoubleDown), (arrowUpRight), (arrowDownRight).
            - Mention Trio setting names naturally, for example basal rates, ISF, carb ratios, overrides, and temporary targets. The app turns those words into inline links.
            - In Dutch answers, prefer "basaalwaarden" over "basal rates" and "koolhydraatratio's" over "carb ratios". "override" and "overrides" may stay as-is.
            - For value changes, write current value -> proposed value, then explain in words. Do not add another arrow after the proposed value.
            - Use lightweight Markdown for emphasis and lists when helpful: **bold** key findings, and use short bullet lists for multiple points.
            - Put every bullet point on its own line. Never place two bullet points inside the same paragraph.
            - Do not output markdown horizontal separators such as "-----".
            - When you include structured suggestions, keep the visible answer concise enough that the hidden block is not truncated.
            - Finish the visible answer in complete sentences before any hidden XML-style blocks. Never start <KNOWLEDGE> or <TRIO_SUGGESTIONS> until the user-facing answer is fully complete.

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

            let caffeineContext = AIInsights_CaffeineTracker.shared.buildCaffeinePromptContext()
            if !caffeineContext.isEmpty {
                prompt += "\n\n" + caffeineContext
            }

            let locationContext = AIInsights_LocationService.shared.locationContextForPrompt()
            if !locationContext.isEmpty {
                prompt += "\n\n" + locationContext
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

            STRUCTURED SUGGESTIONS:
            \(structuredSuggestionInstruction(allowTherapy: allowTherapySuggestions, allowAdjustments: allowAdjustmentSuggestions))

            USER QUESTION: \(input)
            """

            return prompt
        }

        private func structuredSuggestionInstruction(allowTherapy: Bool, allowAdjustments: Bool) -> String {
            guard allowTherapy || allowAdjustments else {
                return "Do not output a <TRIO_SUGGESTIONS> block for this answer."
            }

            var sections: [String] = []
            if allowTherapy {
                sections.append("""
                If the user's question asks for setting changes or a pattern that likely needs setting review, append therapySuggestions inside <TRIO_SUGGESTIONS>. Use only justified conservative changes:
                {"settingType":"Basal Rate"|"Insulin Sensitivity Factor"|"Carb Ratio","timeBlock":"03:00 - 07:00","currentValue":"0.80 U/hr","proposedValue":"0.72 U/hr","reasoning":"Short evidence-based reason in the user's language.","confidence":0.0-1.0}
                """)
            }

            if allowAdjustments {
                sections.append("""
                If an override or temporary target would be useful, append adjustmentSuggestions inside <TRIO_SUGGESTIONS>:
                {"kind":"override"|"tempTarget","name":"Short preset name","durationMinutes":120,"targetValue":8.3,"percentage":80,"smbIsOff":false,"isf":true,"cr":true,"reasoning":"Short evidence-based reason in the user's language.","confidence":0.0-1.0}
                Use targetValue in \(provider.units.rawValue). For tempTarget, targetValue is required. For override, percentage is optional and defaults to 100.
                """)
            }

            return """
            \(sections.joined(separator: "\n"))
            First write the complete visible answer. Then, if needed, output the structured block only at the very end, and only in this exact wrapper:
            <TRIO_SUGGESTIONS>
            {"therapySuggestions":[],"adjustmentSuggestions":[]}
            </TRIO_SUGGESTIONS>
            Do not mention the hidden block to the user.
            """
        }
    }
}
