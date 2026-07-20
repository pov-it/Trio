//
//  AIInsights_PeriodicRecap.swift
//  Trio
//
//  Periodic AI-generated recap of OBSERVATIONS (no advice).
//
//  Schedule:
//    - If any AI therapy change has been applied in the last 7 days, recaps run
//      WEEKLY (every 7 days from the previous recap).
//    - Otherwise recaps run MONTHLY (every 30 days).
//
//  Context fed to the AI:
//    - Last 30 days of chat conversation titles + last message snippets
//    - All applied therapy suggestions in the last 30 days
//    - Tracker context (caffeine, alcohol)
//    - Meal context (FoodFinder)
//    - AutoPresets activity log
//
//  The AI is instructed to produce a SHORT bullet list of observed patterns —
//  NOT advice. The user can ask follow-up questions in the chat.
//

import Foundation

extension AIInsights {

    struct RecapEntry: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        let date: Date
        let title: String
        let body: String
        let cadence: Cadence
        /// Number of applied therapy suggestions covered in this recap.
        let appliedSuggestionCount: Int

        enum Cadence: String, Codable {
            case weekly
            case monthly
        }
    }

    final class PeriodicRecapService {

        static let shared = PeriodicRecapService()

        private static let storageKey = "ai_insights_periodic_recaps"
        private static let lastRecapKey = "ai_insights_periodic_recap_last"
        private static let maxStored = 12

        private static let weeklyInterval: TimeInterval = 7 * 24 * 3600
        private static let monthlyInterval: TimeInterval = 30 * 24 * 3600

        private init() {}

        // MARK: - Storage

        func loadHistory() -> [RecapEntry] {
            guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
                  let saved = try? JSONDecoder().decode([RecapEntry].self, from: data)
            else { return [] }
            return saved
        }

        private func save(_ entries: [RecapEntry]) {
            let toSave = Array(entries.prefix(Self.maxStored))
            if let data = try? JSONEncoder().encode(toSave) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }

        var lastRecapDate: Date? {
            UserDefaults.standard.object(forKey: Self.lastRecapKey) as? Date
        }

        private func markLastRecap(_ date: Date) {
            UserDefaults.standard.set(date, forKey: Self.lastRecapKey)
        }

        func clearHistory() {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            UserDefaults.standard.removeObject(forKey: Self.lastRecapKey)
        }

        // MARK: - Scheduling

        /// Returns the cadence that should run *now*, or nil if no recap is due.
        func dueCadence(at now: Date = Date()) -> RecapEntry.Cadence? {
            let last = lastRecapDate ?? .distantPast
            let history = AIInsights.SuggestionHistoryStore.load()
            let weekCutoff = now.addingTimeInterval(-Self.weeklyInterval)
            let recentApplied = history.contains { $0.status == .applied && $0.appliedAt >= weekCutoff }

            if recentApplied, now.timeIntervalSince(last) >= Self.weeklyInterval {
                return .weekly
            }
            if now.timeIntervalSince(last) >= Self.monthlyInterval {
                return .monthly
            }
            return nil
        }

        // MARK: - Generation

        struct GenerationConfig {
            let provider: AIProvider
            let apiKey: String
            let baseURL: String
            let model: String
            let clinicalContext: String
        }

        /// Build the AI prompt body (without the system message) using last-30-day
        /// data. The chat conversations + therapy changes + tracker context are
        /// included so the AI can spot patterns it would not see otherwise.
        private func buildContext(conversations: [ChatConversation], now: Date, clinicalContext: String) -> String {
            let cutoff = now.addingTimeInterval(-Self.monthlyInterval)
            var ctx = "## PERIODIC RECAP CONTEXT (last 30 days)\n\n"

            if !clinicalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ctx += clinicalContext + "\n"
            }

            // 1. Therapy changes
            let history = AIInsights.SuggestionHistoryStore.load()
                .filter { $0.appliedAt >= cutoff }
            ctx += "### Therapy Changes (\(history.count)):\n"
            if history.isEmpty {
                ctx += "- None applied.\n"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                for record in history.prefix(15) {
                    let when = formatter.string(from: record.appliedAt)
                    let setting = record.suggestion.settingType.rawValue
                    let tb = record.suggestion.timeBlock
                    let before = record.suggestion.currentValue
                    let after = record.suggestion.proposedValue
                    ctx += "- \(when): \(setting) \(tb) \(before) → \(after) [\(record.status.rawValue)]\n"
                }
            }
            ctx += "\n"

            // 2. Chat conversation summaries (titles + last message)
            let recentConvos = conversations
                .filter { $0.updatedAt >= cutoff }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(10)
            ctx += "### Recent Chats (\(recentConvos.count)):\n"
            if recentConvos.isEmpty {
                ctx += "- No chats in this window.\n"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                for convo in recentConvos {
                    let when = formatter.string(from: convo.updatedAt)
                    let lastUserMsg = convo.messages.last(where: \.isUser)?.content ?? ""
                    let snippet = String(lastUserMsg.prefix(100))
                    ctx += "- \(when) — \"\(convo.title)\" — user asked: \"\(snippet)\"\n"
                }
            }
            ctx += "\n"

            // 3. Trackers
            let caffeine = AIInsights_CaffeineTracker.shared.buildCaffeinePromptContext(at: now, lookbackHours: 24 * 30)
            if !caffeine.isEmpty { ctx += caffeine + "\n" }
            let alcohol = AIInsights_AlcoholTracker.shared.buildAlcoholPromptContext(at: now, lookbackHours: 24 * 30)
            if !alcohol.isEmpty { ctx += alcohol + "\n" }
            let meals = AIInsights.FoodFinderStateModel.buildMealPromptContext(at: now, lookbackHours: 24 * 30)
            if !meals.isEmpty { ctx += meals + "\n" }

            // 4. AutoPresets
            ctx += AutoPresetsCoordinator.shared.buildAutoPresetsPromptContext(at: now, lookbackHours: 24 * 30)

            return ctx
        }

        private func buildSystemPrompt(cadence: RecapEntry.Cadence) -> String {
            """
            You are writing a \(cadence == .weekly ? "weekly" : "monthly") OBSERVATIONS recap for a Type-1 diabetic Trio user.

            \(AIInsights.responseLanguageInstruction())

            The instruction language is English by design. Do not answer in Dutch unless the response-language instruction says the user's current app language is Dutch.

            The recap must read like a complete, coherent month report, not like a clipped note. Use full sentences and never end mid-value, mid-time-block, or mid-sentence.

            STRUCTURE — produce ALL of the following sections, in this order, each prefixed with a Markdown header on its own line:

            **Overview**
            Write 2–3 sentences of plain prose summarizing the past period. Mention what changed, what stayed stable, and the general feel of the user's data.

            **Glucose and carbs**
            Bullet list of concrete glucose statistics, time-of-day patterns, carb logging, and meal observations from FoodFinder.

            **Therapy settings and changes**
            Bullet list of the current therapy setting snapshot and every therapy setting adjusted in this window. For changes, name the setting, time block, and before -> after values.

            **Food, caffeine, alcohol, and activity**
            Bullet list of concrete behavioral/context patterns from FoodFinder, caffeine, alcohol, and AutoPresets. State when a data source had no entries.

            **Therapy changes**
            Bullet list of EVERY therapy setting that was adjusted in this window. For each, name the setting (Basal, ISF, Carb Ratio, Target, etc.), the time block if relevant, and the before → after values. If no changes were applied, write a single bullet saying so.

            **Patterns**
            3–5 bullet observations about recurring questions, tracker usage, meal timing, AutoPreset activations, glucose-affecting behaviors. Be concrete; name times of day or specific triggers where the data shows them. EXPLICITLY check for caffeine→post-intake hyperglycemia and alcohol→delayed (next-morning) hypoglycemia patterns when the tracker data shows them — and if a pattern is consistent across multiple events, note whether the user already has the corresponding AutoPreset auto-override enabled or not.

            **Summary**
            One closing sentence, prefixed with "Summary:" (no bullet), that captures the period's headline.

            RULES:
            - Observations ONLY. Do NOT give advice or recommend changes.
            - Each bullet ≤ 25 words. Use complete sentences. Do not output fragments.
            - Mention therapy settings by name and value (no implicit "you should also...").
            - If trackers (caffeine / alcohol / FoodFinder / AutoPresets) reveal a behavioral pattern, name it concretely.
            - Use lightweight Markdown: **bold** for setting names, `-` bullets, headers with `**Section**`.
            - NEVER include therapy-suggestion blocks or knowledge-base blocks. This is pure prose.

            OUTPUT FORMAT — CRITICAL:
            - Output ONLY the final recap. No preamble, no JSON, no code fences.
            - Do NOT show your reasoning, drafts, self-checks, or planning steps.
            - Do NOT include word counts like "(20 words)" or annotations like "-> ...".
            - Do NOT include lines such as "Review against Rules", "Self-check", "Draft:", "Final draft", "Check:", "Observations ONLY?", "Each bullet <= 25 words?", or any other meta-commentary on the rules above.
            - Do NOT restate or reference the structure/rules in the output.
            - The first character of your response must be the `**Overview**` header. The last line must be the `Summary:` line.
            """
        }

        /// Generates a recap synchronously over the AI API. Caller is responsible
        /// for being on a Task. Returns nil and silently no-ops if no cadence is due.
        @discardableResult
        func generateRecapIfDue(
            config: GenerationConfig,
            conversations: [ChatConversation],
            at now: Date = Date()
        ) async throws -> RecapEntry? {
            guard let cadence = dueCadence(at: now) else { return nil }
            return try await forceGenerate(config: config, cadence: cadence, conversations: conversations, at: now)
        }

        /// Generate a recap on demand (user tapped "Generate Now"). Bypasses the
        /// scheduler but still updates `lastRecapDate`.
        @discardableResult
        func forceGenerate(
            config: GenerationConfig,
            cadence: RecapEntry.Cadence,
            conversations: [ChatConversation],
            at now: Date = Date()
        ) async throws -> RecapEntry {
            let systemPrompt = buildSystemPrompt(cadence: cadence)
            let userContext = buildContext(
                conversations: conversations,
                now: now,
                clinicalContext: config.clinicalContext
            )

            let request = AIServiceAdapter.AIRequest(
                model: config.model,
                messages: [
                    AIServiceAdapter.ChatMessagePayload(role: .system, content: systemPrompt),
                    AIServiceAdapter.ChatMessagePayload(role: .user, content: userContext)
                ],
                temperature: 0.4,
                topP: 0.9,
                topK: nil,
                maxTokens: 4096
            )

            let response = try await AIServiceAdapter.send(
                request: request,
                provider: config.provider,
                baseURL: config.baseURL,
                apiKey: config.apiKey
            )
            let rawText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let recapBody = Self.sanitizeRecapBody(rawText)
            guard recapBody.count >= 120 else {
                throw AIServiceAdapter.AIError.parsingError("The generated recap was incomplete. Please try again.")
            }

            let cutoff = now.addingTimeInterval(-Self.monthlyInterval)
            let appliedCount = AIInsights.SuggestionHistoryStore.load()
                .filter { $0.appliedAt >= cutoff && $0.status == .applied }
                .count

            let titleFormatter = DateFormatter()
            titleFormatter.dateStyle = .medium
            let titlePrefix = cadence == .weekly
                ? String(localized: "Weekly recap", comment: "Periodic recap title prefix")
                : String(localized: "Monthly recap", comment: "Periodic recap title prefix")
            let title = "\(titlePrefix) — \(titleFormatter.string(from: now))"

            let entry = RecapEntry(
                date: now,
                title: title,
                body: recapBody,
                cadence: cadence,
                appliedSuggestionCount: appliedCount
            )

            var history = loadHistory()
            history.insert(entry, at: 0)
            save(history)
            markLastRecap(now)
            return entry
        }

        // MARK: - Sanitization

        /// Strip chain-of-thought / self-review artifacts from the raw AI
        /// output so the persisted recap is the clean final report only.
        ///
        /// Targets observed Gemini/OpenAI failure modes:
        ///   - Word-count annotations: "(20 words)", "(19 words) ->"
        ///   - Meta headers: "Review against Rules:", "Final draft:",
        ///     "Self-check:", "Draft:", "Check:"
        ///   - Self-Q&A: "Observations ONLY? Yes.", "Each bullet <= 25 words?"
        ///   - Preamble before the first `**Section**` header
        ///   - Stray empty bullets like "* " or "- "
        ///   - Triple+ blank lines collapsed to a single blank
        static func sanitizeRecapBody(_ raw: String) -> String {
            // Normalize bullet markers: the prompt asks for `-`, but the LLM
            // often emits `*`. Convert leading `* ` into `- ` so downstream
            // markdown rendering is consistent.
            var text = raw
            // Drop fenced code blocks if any leaked in
            text = text.replacingOccurrences(
                of: "```[a-zA-Z]*\\n",
                with: "",
                options: .regularExpression
            )
            text = text.replacingOccurrences(of: "```", with: "")

            // Phrases that mark a line as meta-commentary (case-insensitive)
            let metaContains: [String] = [
                "review against rules",
                "self-check",
                "observations only?",
                "<=25 words", "<= 25 words", "25 words?",
                "each bullet", "each bullet <=",
                "final draft", "draft:",
                "no advice.",
                "rules check", "rule check",
                "scratchpad", "scratch pad",
                "(words)"
            ]

            // Regex for parenthetical word counts: "(20 words)" or "(20 word)"
            let wordCountRegex = try? NSRegularExpression(
                pattern: #"\(\s*\d+\s*words?\s*\)"#,
                options: [.caseInsensitive]
            )

            var lines = text.components(separatedBy: .newlines)

            // 1. Drop lines that look like meta-commentary
            lines = lines.compactMap { (line: String) -> String? in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                // Drop pure word-count annotations
                if let regex = wordCountRegex {
                    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                    let stripped = regex.stringByReplacingMatches(
                        in: trimmed,
                        options: [],
                        range: range,
                        withTemplate: ""
                    ).trimmingCharacters(in: .whitespaces)
                    // If after removing the annotation the line is now empty
                    // or just an arrow / punctuation, drop it.
                    if stripped.isEmpty
                        || stripped == "->"
                        || stripped == "→"
                        || stripped.allSatisfy({ "-> →•*-:".contains($0) })
                    {
                        return nil
                    }
                    trimmed = stripped
                }
                // Drop bullet lines whose content is meta-commentary
                let lower = trimmed.lowercased()
                for phrase in metaContains where lower.contains(phrase) {
                    return nil
                }
                // Drop "* Summary" or "* Draft" style leftover headers
                if lower.hasPrefix("* draft") || lower.hasPrefix("- draft")
                    || lower.hasPrefix("* review") || lower.hasPrefix("- review")
                    || lower.hasPrefix("* check") || lower.hasPrefix("- check")
                {
                    return nil
                }
                // Drop empty bullets like "* " / "- "
                if lower == "*" || lower == "-" || lower == "* " || lower == "- " {
                    return nil
                }
                return trimmed.isEmpty ? "" : trimmed
            }

            // 2. Drop any preamble before the first **Overview** (or any
            //    `**...**` header) — if such a header exists.
            if let firstHeaderIdx = lines.firstIndex(where: { line in
                let s = line.trimmingCharacters(in: .whitespaces)
                return s.hasPrefix("**") && s.hasSuffix("**") && s.count >= 6
            }) {
                lines = Array(lines[firstHeaderIdx...])
            }

            // 3. Normalize `*` bullets to `-`
            lines = lines.map { line -> String in
                let s = line
                // Only transform leading `*` followed by space (not the `**bold**` markers).
                if s.hasPrefix("* ") {
                    return "- " + s.dropFirst(2)
                }
                return s
            }

            // 4. Collapse 3+ consecutive blank lines down to one blank line.
            var collapsed: [String] = []
            var blankRun = 0
            for line in lines {
                if line.isEmpty {
                    blankRun += 1
                    if blankRun <= 1 { collapsed.append(line) }
                } else {
                    blankRun = 0
                    collapsed.append(line)
                }
            }

            return collapsed
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
