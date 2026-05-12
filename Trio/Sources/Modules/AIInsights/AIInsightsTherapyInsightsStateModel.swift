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

            // 1. Capture BEFORE snapshot
            let basalProfile = await provider.getBasalProfile()
            let isf = await provider.getISF()
            let cr = await provider.getCR()
            let target = await provider.getTarget()

            let beforeSnapshot = TherapySnapshot(
                basalProfile: basalProfile,
                isfSensitivity: isf,
                carbRatio: cr,
                target: target,
                capturedAt: Date()
            )

            // 2. Write the new value (only the specific setting type)
            // NOTE: This is a simplified write. Real implementation should parse
            // the proposed value and write per time-block.
            // For safety, we log the suggestion as applied without auto-writing.
            // The user can use the "proposed value" to manually tune in Trio settings.

            // 3. Capture AFTER snapshot (same as before since we log-only for now)
            let afterSnapshot = TherapySnapshot(
                basalProfile: basalProfile,
                isfSensitivity: isf,
                carbRatio: cr,
                target: target,
                capturedAt: Date()
            )

            // 4. Record in history
            let record = SuggestionHistoryRecord(
                suggestion: suggestion,
                appliedAt: Date(),
                status: .applied,
                beforeSnapshot: beforeSnapshot,
                afterSnapshot: afterSnapshot
            )
            SuggestionHistoryStore.append(record)
            suggestionHistory = SuggestionHistoryStore.load()

            // 5. Remove from active suggestions
            suggestions.removeAll { $0.id == suggestion.id }
            saveSuggestions()
        }

        func cancelApply() {
            showApplyDisclaimer = false
            pendingApplySuggestion = nil
        }

        /// Dismiss a suggestion without applying
        func dismissSuggestion(_ suggestion: Suggestion) {
            let basalProfile: [BasalProfileEntry] = []
            let snapshot = TherapySnapshot(
                basalProfile: basalProfile,
                isfSensitivity: 0,
                carbRatio: 0,
                target: 0,
                capturedAt: Date()
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
        func revertSuggestion(_ record: SuggestionHistoryRecord) {
            // Mark the record as reverted
            SuggestionHistoryStore.updateStatus(for: record.id, to: .reverted)
            suggestionHistory = SuggestionHistoryStore.load()
            // NOTE: Actual settings revert (writing beforeSnapshot back to storage)
            // should be done here once direct therapy writes are enabled.
        }

        func clearHistory() {
            SuggestionHistoryStore.clear()
            suggestionHistory = []
        }

        // MARK: - Analysis

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
                let glucose = await provider.fetchGlucose(since: Date().addingTimeInterval(-Double(analysisPeriodDays) * 24 * 3600))
                let carbs = await provider.fetchCarbs()
                let basalProfile = await provider.getBasalProfile()
                let isf = await provider.getISF()
                let cr = await provider.getCR()
                let target = await provider.getTarget()

                let aggregated = DataAggregator.aggregate(
                    glucose: glucose,
                    carbs: carbs,
                    basalProfile: basalProfile,
                    isf: isf,
                    cr: cr,
                    target: target,
                    units: provider.units,
                    iob: provider.currentIOB,
                    cob: nil,
                    periodDays: analysisPeriodDays,
                    lowThreshold: provider.settings.low,
                    highThreshold: provider.settings.high
                )

                self.stats = aggregated

                // 2. Compute Settings Score
                settingsScore = computeSettingsScore(from: aggregated)

                // 3. Build the therapy-specific prompt
                let prompt = buildTherapyPrompt(stats: aggregated, settingType: settingType)

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

            OUTPUT FORMAT — respond ONLY with a valid JSON array of suggestion objects:
            [
              {
                "settingType": "Basal Rate" | "Insulin Sensitivity Factor" | "Carb Ratio",
                "timeBlock": "03:00 AM - 07:00 AM",
                "currentValue": "0.85 U/hr",
                "proposedValue": "0.95 U/hr",
                "reasoning": "Dawn phenomenon detected: average glucose 3-7 AM is 180 mg/dL vs 130 mg/dL overnight. Increasing basal by 12% should reduce morning highs.",
                "confidence": 0.75
              }
            ]

            SAFETY RULES:
            - Never suggest changes exceeding ±20% from current values
            - Conservative bias: under-adjust rather than over-adjust
            - If data is insufficient (<3 days), respond with an empty array []
            - Confidence should be 0.0–1.0 based on data quality and pattern strength
            - Include reasoning that references specific data points
            """
        }

        private func buildTherapyPrompt(stats: AggregatedStats, settingType: Suggestion.SettingType?) -> String {
            let unitsStr = provider.units.rawValue
            let settingFilter = settingType.map { "Focus ONLY on \($0.rawValue) suggestions." } ?? "Analyze all three setting types: Basal Rate, ISF, and Carb Ratio."

            return """
            \(settingFilter)

            DATA PERIOD: \(stats.periodDays) days (from \(stats.startDate.formatted(.dateTime.month().day())) to \(stats.endDate.formatted(.dateTime.month().day())))

            GLUCOSE STATISTICS:
            - Average: \(String(format: "%.1f", stats.averageGlucose)) \(unitsStr)
            - Std Dev: \(String(format: "%.1f", stats.glucoseStdDev)) \(unitsStr)
            - TIR: \(String(format: "%.1f", stats.tir.timeInRange))%
            - Time Below Low: \(String(format: "%.1f", stats.tir.timeBelowLow))%
            - Time Above High: \(String(format: "%.1f", stats.tir.timeAboveHigh))%
            - GMI: \(String(format: "%.1f", stats.gmi))%

            DETECTED PATTERNS: \(stats.detectedPatterns.map(\.rawValue).joined(separator: ", "))

            HOURLY GLUCOSE AVERAGES:
            \(stats.hourlyGlucoseAverage.map { h in String(format: "%02d:00 — Avg: %.1f, Min: %.1f, Max: %.1f (%d readings)", h.hour, h.average, h.min, h.max, h.count) }.joined(separator: "\n"))

            CURRENT THERAPY SETTINGS:
            - Basal Profile:
            \(stats.currentBasalProfile)
            - ISF: \(stats.currentISF)
            - Carb Ratio: \(stats.currentCR)
            - Target: \(stats.currentTarget)

            Respond ONLY with the JSON array. No markdown, no explanation outside the JSON.
            """
        }

        // MARK: - Response Parsing

        private func parseSuggestions(from text: String, settingType _: Suggestion.SettingType?) -> [Suggestion] {
            // Try to extract JSON from AI response
            let cleanedText = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = cleanedText.data(using: .utf8) else { return [] }

            struct RawSuggestion: Codable {
                let settingType: String
                let timeBlock: String
                let currentValue: String
                let proposedValue: String
                let reasoning: String
                let confidence: Double
            }

            guard let raw = try? JSONDecoder().decode([RawSuggestion].self, from: data) else {
                // If we can't parse JSON, create a single catch-all suggestion with the AI text
                return [Suggestion(
                    settingType: .basalRate,
                    timeBlock: "General",
                    currentValue: "—",
                    proposedValue: "—",
                    reasoning: text,
                    confidence: 0.0,
                    createdAt: Date()
                )]
            }

            return raw.map { r in
                let type: Suggestion.SettingType
                switch r.settingType.lowercased() {
                case let s where s.contains("basal"): type = .basalRate
                case let s where s.contains("sensitivity") || s.contains("isf"): type = .isf
                case let s where s.contains("carb") || s.contains("cr"): type = .carbRatio
                default: type = .basalRate
                }

                return Suggestion(
                    settingType: type,
                    timeBlock: r.timeBlock,
                    currentValue: r.currentValue,
                    proposedValue: r.proposedValue,
                    reasoning: r.reasoning,
                    confidence: min(max(r.confidence, 0), 1),
                    createdAt: Date()
                )
            }
        }
    }
}
