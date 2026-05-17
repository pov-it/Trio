import Foundation
import Observation
import Swinject

extension AIInsights {
    @Observable final class TherapyInsightsStateModel: BaseStateModel<Provider> {
        var isAnalyzing: Bool = false
        var errorMessage: String?
        var suggestions: [Suggestion] = []
        var settingsScore: SettingsScore?
        var stats: AggregatedStats?
        var analysisPeriodDays: Int = 7
        var selectedSettingType: Suggestion.SettingType?
        var suggestionHistory: [SuggestionHistoryRecord] = []
        var showApplyDisclaimer: Bool = false
        var pendingApplySuggestion: Suggestion?

        // Settings from shared AI config
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
            analysisPeriodDays = provider.settings.aiAnalysisPeriodDays

            // Load cached suggestions
            loadSuggestions()
            suggestionHistory = SuggestionHistoryStore.load()
        }

        // MARK: - Suggestion Persistence

        func saveSuggestions() {
            if let data = try? JSONEncoder().encode(suggestions) {
                UserDefaults.standard.set(data, forKey: "ai_insights_therapy_suggestions")
            }
        }

        func loadSuggestions() {
            if let data = UserDefaults.standard.data(forKey: "ai_insights_therapy_suggestions"),
               let saved = try? JSONDecoder().decode([Suggestion].self, from: data)
            {
                suggestions = saved
            }
        }

        func clearSuggestions() {
            suggestions = []
            settingsScore = nil
            stats = nil
            saveSuggestions()
        }

        // MARK: - One-Tap Apply

        /// User taps Apply — show disclaimer first
        func requestApply(_ suggestion: Suggestion) {
            pendingApplySuggestion = suggestion
            showApplyDisclaimer = true
        }

        /// User confirmed the disclaimer — actually write the setting
        @MainActor
        func confirmApply() async {
            guard let suggestion = pendingApplySuggestion else { return }
            showApplyDisclaimer = false
            pendingApplySuggestion = nil

            do {
                let beforeSnapshot = await provider.captureTherapySnapshot()
                try await provider.applySuggestion(suggestion)
                let afterSnapshot = await provider.captureTherapySnapshot()

                let record = SuggestionHistoryRecord(
                    suggestion: suggestion,
                    appliedAt: Date(),
                    status: .applied,
                    beforeSnapshot: beforeSnapshot,
                    afterSnapshot: afterSnapshot
                )
                SuggestionHistoryStore.append(record)
                suggestionHistory = SuggestionHistoryStore.load()

                suggestions.removeAll { $0.id == suggestion.id }
                saveSuggestions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func cancelApply() {
            showApplyDisclaimer = false
            pendingApplySuggestion = nil
        }

        /// Dismiss a suggestion without applying
        func dismissSuggestion(_ suggestion: Suggestion) {
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
            let record = SuggestionHistoryRecord(
                suggestion: suggestion,
                appliedAt: Date(),
                status: .dismissed,
                beforeSnapshot: snapshot,
                afterSnapshot: snapshot
            )
            SuggestionHistoryStore.append(record)
            suggestionHistory = SuggestionHistoryStore.load()
            suggestions.removeAll { $0.id == suggestion.id }
            saveSuggestions()
        }

        /// Revert a previously applied suggestion
        @MainActor
        func revertSuggestion(_ record: SuggestionHistoryRecord) async {
            do {
                try await provider.restoreSnapshot(record.beforeSnapshot, for: record.suggestion.settingType)
                SuggestionHistoryStore.updateStatus(for: record.id, to: .reverted)
                suggestionHistory = SuggestionHistoryStore.load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func deleteHistoryRecord(_ record: SuggestionHistoryRecord) {
            SuggestionHistoryStore.delete(record.id)
            suggestionHistory = SuggestionHistoryStore.load()
        }

        func clearHistory() {
            SuggestionHistoryStore.clear()
            suggestionHistory = []
        }

        func saveAnalysisPeriod() {
            guard provider != nil else { return }
            var settings = provider.settings
            settings.aiAnalysisPeriodDays = analysisPeriodDays
            provider.settings = settings
        }

        // MARK: - Analysis

        @MainActor
        func refreshSettingsScore() async {
            guard provider != nil else { return }

            let (aggregated, _) = await loadAnalysisData()
            stats = aggregated
            settingsScore = computeSettingsScore(from: aggregated)
        }

        @MainActor
        func runAnalysis(for settingType: Suggestion.SettingType? = nil) async {
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
            selectedSettingType = settingType
            defer { isAnalyzing = false }

            do {
                // 1. Fetch and aggregate data
                let (aggregated, carbs) = await loadAnalysisData()

                self.stats = aggregated

                // 2. Compute Settings Score
                settingsScore = computeSettingsScore(from: aggregated)

                // 3. Build the therapy-specific prompt
                let treatmentContext = buildTreatmentContext(from: carbs)
                let therapyChangeContext = buildTherapyChangeContext()
                let prompt = buildTherapyPrompt(
                    stats: aggregated,
                    settingType: settingType,
                    treatmentContext: treatmentContext,
                    therapyChangeContext: therapyChangeContext
                )

                // 4. Send to AI
                let request = AIServiceAdapter.AIRequest(
                    model: model,
                    messages: [
                        AIServiceAdapter.ChatMessagePayload(role: .system, content: therapySystemPrompt),
                        AIServiceAdapter.ChatMessagePayload(role: .user, content: prompt)
                    ],
                    temperature: 0.3,
                    topP: 0.9,
                    topK: nil,
                    maxTokens: 4096
                )

                let response = try await AIServiceAdapter.send(
                    request: request,
                    provider: providerType,
                    baseURL: baseURL,
                    apiKey: apiKey
                )

                // 5. Parse suggestions from AI response
                let parsed = parseSuggestions(from: response.text, settingType: settingType)
                suggestions = parsed
                saveSuggestions()

            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        private func loadAnalysisData() async -> (AggregatedStats, [CarbsEntry]) {
            let startDate = Date().addingTimeInterval(-Double(analysisPeriodDays) * 24 * 3600)
            async let glucoseTask = provider.fetchGlucose(since: startDate)
            async let carbsTask = provider.fetchCarbs(since: startDate)
            async let basalProfileTask = provider.getBasalProfile()
            async let isfTask = provider.getISF()
            async let crTask = provider.getCR()
            async let targetTask = provider.getTarget()
            async let isfDescriptionTask = provider.getISFDescription()
            async let crDescriptionTask = provider.getCRDescription()
            async let targetDescriptionTask = provider.getTargetDescription()

            let (
                glucose,
                carbs,
                basalProfile,
                isf,
                cr,
                target,
                isfDescription,
                crDescription,
                targetDescription
            ) = await (
                glucoseTask,
                carbsTask,
                basalProfileTask,
                isfTask,
                crTask,
                targetTask,
                isfDescriptionTask,
                crDescriptionTask,
                targetDescriptionTask
            )

            let aggregated = DataAggregator.aggregate(
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
                iob: provider.currentIOB,
                cob: nil,
                periodDays: analysisPeriodDays,
                lowThreshold: provider.settings.low,
                highThreshold: provider.settings.high
            )
            return (aggregated, carbs)
        }

        // MARK: - Settings Score

        private func computeSettingsScore(from stats: AggregatedStats) -> SettingsScore {
            // ADA/AACE consensus scoring
            // TIR >70% = good, <54 time = <1%, CV <36%
            var score = 0.0

            // TIR component (max 40 points)
            score += min(stats.tir.timeInRange / 70.0 * 40.0, 40.0)

            // Time below range component (max 25 points, penalty for lows)
            let belowPenalty = stats.tir.timeBelowLow
            score += max(25.0 - belowPenalty * 5.0, 0)

            // CV component (max 20 points)
            let cv = stats.glucoseStdDev / max(stats.averageGlucose, 1) * 100
            score += cv < 36 ? 20.0 : max(20.0 - (cv - 36.0) * 2.0, 0)

            // GMI component (max 15 points) — target 6.5-7.0%
            let gmiScore: Double
            if stats.gmi >= 6.0 && stats.gmi <= 7.0 {
                gmiScore = 15
            } else if stats.gmi < 6.0 {
                gmiScore = max(15.0 - (6.0 - stats.gmi) * 5.0, 0)
            } else {
                gmiScore = max(15.0 - (stats.gmi - 7.0) * 3.0, 0)
            }
            score += gmiScore

            let finalScore = min(max(Int(score), 0), 100)

            let grade: SettingsScore.Grade
            switch finalScore {
            case 80...: grade = .excellent
            case 60..<80: grade = .good
            case 40..<60: grade = .fair
            default: grade = .needsWork
            }

            return SettingsScore(
                score: finalScore,
                grade: grade,
                tir: stats.tir.timeInRange,
                gmi: stats.gmi,
                timeBelowRange: stats.tir.timeBelowLow,
                cv: stats.glucoseStdDev / max(stats.averageGlucose, 1) * 100
            )
        }

        // MARK: - Prompt Engineering

        private var therapySystemPrompt: String {
            """
            You are a clinical diabetes therapy advisor analyzing data from a Trio (OpenAPS) closed-loop system.

            ROLE: Provide specific, time-block-level therapy setting adjustment suggestions.

            \(AIInsights.responseLanguageInstruction())

            OUTPUT FORMAT - respond ONLY with a valid JSON object:
            {
              "suggestions": [
                {
                  "settingType": "Basal Rate" | "Insulin Sensitivity Factor" | "Carb Ratio",
                  "timeBlock": "03:00 - 07:00",
                  "currentValue": "0.85 U/hr",
                  "proposedValue": "0.95 U/hr",
                  "reasoning": "Dawn phenomenon detected: average glucose 3-7 AM is 180 mg/dL vs 130 mg/dL overnight. Increasing basal by 12% should reduce morning highs.",
                  "confidence": 0.75
                }
              ],
              "overallAssessment": "Short summary of the data quality and main pattern."
            }

            SAFETY RULES:
            - Never suggest changes exceeding ±20% from current values
            - Basal changes must stay within 10% of the current value
            - ISF and Carb Ratio changes must stay within 20% of the current value
            - Conservative bias: under-adjust rather than over-adjust
            - If data is insufficient (<3 days or sparse CGM coverage), respond with {"suggestions":[],"overallAssessment":"Insufficient data."}
            - Return zero suggestions if the actual data does not justify a therapy setting change
            - Do not use generic diabetes ranges. Use only the user's actual Trio data and settings.
            - Generate "reasoning" and "overallAssessment" in the user's app language.
            - Keep "settingType" values exactly as the allowed English enum values so the app can apply them.
            - Confidence should be 0.0-1.0 based on data quality and pattern strength
            - Include reasoning that references specific data points
            - Consider recent applied therapy changes as part of the current treatment context. Do not repeat the same setting change direction for the same time block unless newer data clearly supports it.
            """
        }

        private func buildTherapyPrompt(
            stats: AggregatedStats,
            settingType: Suggestion.SettingType?,
            treatmentContext: String,
            therapyChangeContext: String
        ) -> String {
            let unitsStr = provider.units.rawValue
            let settingFilter = settingType.map { "Focus ONLY on \($0.rawValue) suggestions." } ?? "Analyze all three setting types: Basal Rate, ISF, and Carb Ratio."

            return """
            \(settingFilter)

            DATA PERIOD: \(stats.periodDays) days (from \(stats.startDate.formatted(.dateTime.month().day())) to \(stats.endDate.formatted(.dateTime.month().day())))

            GLUCOSE STATISTICS:
            - CGM readings: \(stats.glucoseReadings.count)
            - Average: \(String(format: "%.1f", stats.averageGlucose)) \(unitsStr)
            - Std Dev: \(String(format: "%.1f", stats.glucoseStdDev)) \(unitsStr)
            - TIR: \(String(format: "%.1f", stats.tir.timeInRange))%
            - Time Below Low: \(String(format: "%.1f", stats.tir.timeBelowLow))%
            - Time Above High: \(String(format: "%.1f", stats.tir.timeAboveHigh))%
            - GMI: \(String(format: "%.1f", stats.gmi))%
            - Carb entries: \(stats.carbEntries)
            - Average daily carbs: \(String(format: "%.0f", stats.averageDailyCarbs)) g

            DETECTED PATTERNS: \(stats.detectedPatterns.map(\.rawValue).joined(separator: ", "))

            HOURLY GLUCOSE AVERAGES:
            \(stats.hourlyGlucoseAverage.map { h in String(format: "%02d:00 — Avg: %.1f, Min: %.1f, Max: %.1f (%d readings)", h.hour, h.average, h.min, h.max, h.count) }.joined(separator: "\n"))

            CURRENT THERAPY SETTINGS:
            - Basal Profile:
            \(stats.currentBasalProfile)
            - ISF: \(stats.currentISF)
            - Carb Ratio: \(stats.currentCR)
            - Target: \(stats.currentTarget)

            RECENT TREATMENT CONTEXT:
            \(treatmentContext)

            RECENT AI THERAPY CHANGE CONTEXT:
            \(therapyChangeContext)

            Respond ONLY with the JSON object. No markdown, no explanation outside the JSON.
            """
        }

        private func buildTreatmentContext(from carbs: [CarbsEntry]) -> String {
            let recent = carbs
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(20)

            guard !recent.isEmpty else {
                return String(localized: "No recent carb or meal entries were available for this period.", comment: "Therapy prompt no treatment context")
            }

            return recent.map { entry in
                let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty ?? "-"
                return String(
                    format: "%@ — %@g carbs, %@g fat, %@g protein, note: %@",
                    entry.createdAt.formatted(.dateTime.month().day().hour().minute()),
                    NSDecimalNumber(decimal: entry.carbs).stringValue,
                    NSDecimalNumber(decimal: entry.fat ?? 0).stringValue,
                    NSDecimalNumber(decimal: entry.protein ?? 0).stringValue,
                    note
                )
            }.joined(separator: "\n")
        }

        private func buildTherapyChangeContext() -> String {
            let records = suggestionHistory
                .filter { $0.status == .applied }
                .prefix(12)

            guard !records.isEmpty else {
                return String(localized: "No recent applied AI therapy changes are recorded.", comment: "Therapy prompt no AI changes")
            }

            return records.map { record in
                "\(record.appliedAt.formatted(.dateTime.month().day().hour().minute())) — \(record.suggestion.settingType.rawValue), \(record.suggestion.timeBlock): \(record.suggestion.currentValue) -> \(record.suggestion.proposedValue). \(record.suggestion.reasoning)"
            }.joined(separator: "\n")
        }

        // MARK: - Response Parsing

        private func parseSuggestions(from text: String, settingType focusedSettingType: Suggestion.SettingType?) -> [Suggestion] {
            guard let jsonText = extractJSONFragment(from: text),
                  let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return []
            }

            let rawSuggestions: [Any]
            if let array = json as? [Any] {
                rawSuggestions = array
            } else if let object = json as? [String: Any],
                      let suggestions = object["suggestions"] as? [Any]
            {
                rawSuggestions = suggestions
            } else {
                return []
            }

            return rawSuggestions.flatMap { raw -> [Suggestion] in
                guard let object = raw as? [String: Any] else { return [] }

                let type = parseSettingType(
                    stringValue(from: object, keys: ["settingType", "setting_type", "type", "category"]),
                    fallback: focusedSettingType
                )
                let reasoning = stringValue(from: object, keys: ["reasoning", "reason", "rationale", "explanation"])
                    ?? String(localized: "No reasoning provided.", comment: "Therapy suggestion missing reasoning")
                let confidence = confidenceValue(object["confidence"])
                let unit = valueUnit(for: type)

                if let blocks = object["time_blocks"] as? [[String: Any]]
                    ?? object["timeBlocks"] as? [[String: Any]]
                {
                    return blocks.compactMap { block in
                        let current = valueString(
                            block["current_value"] ?? block["currentValue"] ?? object["currentValue"] ?? object["current_value"],
                            unit: unit
                        )
                        let proposed = valueString(
                            block["proposed_value"] ?? block["proposedValue"] ?? object["proposedValue"] ?? object["proposed_value"],
                            unit: unit
                        )
                        guard !current.isEmpty, !proposed.isEmpty else { return nil }
                        return Suggestion(
                            settingType: type,
                            timeBlock: timeBlockString(from: block, fallback: String(localized: "General", comment: "General therapy time block")),
                            currentValue: current,
                            proposedValue: proposed,
                            reasoning: reasoning,
                            confidence: confidence,
                            createdAt: Date()
                        )
                    }
                }

                let current = valueString(object["currentValue"] ?? object["current_value"], unit: unit)
                let proposed = valueString(object["proposedValue"] ?? object["proposed_value"], unit: unit)
                guard !current.isEmpty, !proposed.isEmpty else { return [] }

                return [Suggestion(
                    settingType: type,
                    timeBlock: stringValue(from: object, keys: ["timeBlock", "time_block", "timeRange", "time_range"])
                        ?? String(localized: "General", comment: "General therapy time block"),
                    currentValue: current,
                    proposedValue: proposed,
                    reasoning: reasoning,
                    confidence: confidence,
                    createdAt: Date()
                )]
            }
        }

        private func extractJSONFragment(from text: String) -> String? {
            let cleaned = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if cleaned.first == "{" || cleaned.first == "[" {
                return cleaned
            }

            if let objectStart = cleaned.firstIndex(of: "{"),
               let objectEnd = cleaned.lastIndex(of: "}"),
               objectStart < objectEnd
            {
                let object = String(cleaned[objectStart ... objectEnd])
                if object.contains("\"suggestions\"") {
                    return object
                }
            }

            if let arrayStart = cleaned.firstIndex(of: "["),
               let arrayEnd = cleaned.lastIndex(of: "]"),
               arrayStart < arrayEnd
            {
                return String(cleaned[arrayStart ... arrayEnd])
            }

            return nil
        }

        private func parseSettingType(_ value: String?, fallback: Suggestion.SettingType?) -> Suggestion.SettingType {
            let normalized = (value ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            switch normalized {
            case let s where s.contains("basal"):
                return .basalRate
            case let s where s.contains("sensitivity") || s.contains("isf"):
                return .isf
            case let s where s.contains("carb") || s.contains("ratio") || s == "cr":
                return .carbRatio
            default:
                return fallback ?? .basalRate
            }
        }

        private func stringValue(from object: [String: Any], keys: [String]) -> String? {
            for key in keys {
                if let string = object[key] as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return string
                }
            }
            return nil
        }

        private func valueString(_ value: Any?, unit: String) -> String {
            if let string = value as? String {
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let number = value as? NSNumber {
                return "\(formatNumber(number.doubleValue)) \(unit)"
            }
            if let double = value as? Double {
                return "\(formatNumber(double)) \(unit)"
            }
            return ""
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

        private func valueUnit(for type: Suggestion.SettingType) -> String {
            switch type {
            case .basalRate:
                return "U/hr"
            case .isf:
                return "\(provider.units.rawValue)/U"
            case .carbRatio:
                return "g/U"
            }
        }

        private func timeBlockString(from block: [String: Any], fallback: String) -> String {
            if let timeBlock = stringValue(from: block, keys: ["timeBlock", "time_block", "timeRange", "time_range"]) {
                return timeBlock
            }

            let startSeconds = doubleValue(block["start_seconds"] ?? block["startSeconds"])
            let endSeconds = doubleValue(block["end_seconds"] ?? block["endSeconds"])

            if let startSeconds, let endSeconds {
                return "\(formatSeconds(startSeconds)) - \(formatSeconds(endSeconds))"
            }

            return fallback
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

        private func formatSeconds(_ seconds: Double) -> String {
            let totalMinutes = Int(seconds / 60) % (24 * 60)
            return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
        }

        private func formatNumber(_ value: Double) -> String {
            value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
        }
    }
}
