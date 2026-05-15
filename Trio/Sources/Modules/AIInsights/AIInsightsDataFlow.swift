import Foundation

enum AIInsights {
    static let defaultOpenFoodFactsBaseURL = "https://world.openfoodfacts.org/api/v2"

    static let defaultSystemPrompt = """
    Analyze glucose and treatment data for a person with Type 1 Diabetes using Trio/OpenAPS.
    Answer naturally in the user's language, cite only provided numbers, and avoid any fixed Observation/Evidence template.
    Keep therapy suggestions conservative and explain the reason in plain language.
    """

    static let defaultChatSystemPrompt = """
    You're a diabetes-savvy friend who can see this person's actual Trio/OpenAPS data.
    They know how diabetes works, so skip textbook explanations.

    RULES:
    - Be brief. Use 2-3 sentences for simple questions and bullets only when the answer is complex.
    - Cite their specific numbers when they matter.
    - Talk like a knowledgeable friend, not a doctor or a manual.
    - Never explain what carb ratio, ISF, basal rate, IOB, COB, or TIR are unless asked.
    - For setting ideas: current value -> suggested value -> why, in one short line.
    - Never fabricate numbers. Only reference the data provided below.
    - If no data is available, say that briefly.
    - Do not force a fixed "Observation / Evidence / Interpretation" format.
    - Do not give unsolicited praise or reassurance.
    """

    static func responseLanguageInstruction() -> String {
        let identifier = Locale.current.identifier
        let languageCode = Locale.current.languageCode ?? "en"
        let language = Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: languageCode)
            ?? "the user's app language"
        return "Respond in \(language) (\(identifier)). Match the user's app language for all prose. Keep JSON keys in English when JSON is requested."
    }

    static func migratingSystemPrompt(_ prompt: String) -> String {
        let oldFormatMarkers = ["Observation:", "Evidence:", "Possible interpretation:", "Candidate adjustment:"]
        guard oldFormatMarkers.allSatisfy({ prompt.contains($0) }) else { return prompt }
        return defaultChatSystemPrompt
    }

    static func foodFinderReducedBolusRecommended(fat: Double, protein: Double) -> Bool {
        let fpuScore = ((max(fat, 0) * 9.0) + (max(protein, 0) * 4.0)) / 100.0
        return fpuScore >= 1.5
    }

    enum AIProvider: String, CaseIterable, Identifiable, Codable, JSON {
        case google = "Google Gemini"
        case openai = "OpenAI"
        case anthropic = "Anthropic"
        case custom = "Custom"

        var id: String { rawValue }

        var defaultBaseURL: String {
            switch self {
            case .google: return "https://generativelanguage.googleapis.com/v1beta/models/"
            case .openai: return "https://api.openai.com/v1/chat/completions"
            case .anthropic: return "https://api.anthropic.com/v1/messages"
            case .custom: return ""
            }
        }

        var defaultModel: String {
            switch self {
            case .google: return "gemini-2.0-flash"
            case .openai: return "gpt-4o"
            case .anthropic: return "claude-sonnet-4-20250514"
            case .custom: return ""
            }
        }

        /// Full endpoint URL for the provider, combining baseURL with the model name.
        /// For Google Gemini, this constructs the generateContent endpoint.
        /// For OpenAI/Anthropic/Custom, the model is sent in the request body.
        var defaultEndpoint: String {
            switch self {
            case .google:
                return "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
            case .openai, .anthropic, .custom:
                return defaultBaseURL
            }
        }
    }

    // MARK: - Chat Hint Chips

    enum HintChip: String, CaseIterable, Identifiable, Codable {
        case nightSettings = "How are my night settings?"
        case endoVisit = "Prepare my endocrinologist visit"
        case postMeal = "Analyze my post-meal patterns"
        case basalReview = "Review my basal rates"
        case isfReview = "Review my insulin sensitivity"
        case crReview = "Review my carb ratios"
        case trends = "What are my glucose trends?"
        case exerciseImpact = "How does exercise affect my glucose?"
        case overallScore = "Give me an overall settings score"

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .nightSettings: return String(localized: "How are my night settings?", comment: "AI chat hint chip")
            case .endoVisit: return String(localized: "Prepare my endo visit", comment: "AI chat hint chip")
            case .postMeal: return String(localized: "Analyze post-meal patterns", comment: "AI chat hint chip")
            case .basalReview: return String(localized: "Review basal rates", comment: "AI chat hint chip")
            case .isfReview: return String(localized: "Review insulin sensitivity", comment: "AI chat hint chip")
            case .crReview: return String(localized: "Review carb ratios", comment: "AI chat hint chip")
            case .trends: return String(localized: "What are my glucose trends?", comment: "AI chat hint chip")
            case .exerciseImpact: return String(localized: "How does exercise affect my glucose?", comment: "AI chat hint chip")
            case .overallScore: return String(localized: "Give me an overall settings score", comment: "AI chat hint chip")
            }
        }

        var icon: String {
            switch self {
            case .nightSettings: return "moon.stars.fill"
            case .endoVisit: return "cross.case.fill"
            case .postMeal: return "fork.knife"
            case .basalReview: return "waveform.path.ecg.rectangle.fill"
            case .isfReview: return "syringe"
            case .crReview: return "bread.fill"
            case .trends: return "chart.line.uptrend.xyaxis"
            case .exerciseImpact: return "figure.run"
            case .overallScore: return "star.circle.fill"
            }
        }
    }

    // MARK: - Chat Message

    struct ChatAction: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        let title: String
        let systemImage: String
        let destination: Destination

        enum Destination: String, Codable {
            case therapyInsights
            case foodFinder
            case aiSettings
            case therapySettings
            case basalSettings
            case isfSettings
            case carbRatioSettings
            case adjustmentSettings
            case risingPattern
            case fallingPattern
        }
    }

    struct ChatMessage: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        let content: String
        let isUser: Bool
        let timestamp: Date
        var hintChip: HintChip?
        var actions: [ChatAction]? = nil
        var therapySuggestions: [Suggestion]? = nil
        var adjustmentSuggestions: [AdjustmentSuggestion]? = nil
    }

    struct ChatConversation: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var title: String
        var messages: [ChatMessage]
        var createdAt: Date
        var updatedAt: Date

        var preview: String {
            messages.last?.content ?? String(localized: "New conversation", comment: "Empty AI chat conversation")
        }
    }

    // MARK: - Suggestion

    struct Suggestion: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        let settingType: SettingType
        let timeBlock: String
        let currentValue: String
        let proposedValue: String
        let reasoning: String
        let confidence: Double
        let createdAt: Date

        enum SettingType: String, Codable, Equatable {
            case basalRate = "Basal Rate"
            case isf = "Insulin Sensitivity Factor"
            case carbRatio = "Carb Ratio"

            var localizedTitle: String {
                switch self {
                case .basalRate: return String(localized: "Basal Rate", comment: "Therapy setting type")
                case .isf: return String(localized: "Insulin Sensitivity Factor", comment: "Therapy setting type")
                case .carbRatio: return String(localized: "Carb Ratio", comment: "Therapy setting type")
                }
            }
        }
    }

    // MARK: - Chat Adjustment Suggestion

    struct AdjustmentSuggestion: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        let kind: Kind
        let name: String
        let durationMinutes: Int
        let targetValue: Decimal?
        let percentage: Double?
        let smbIsOff: Bool
        let isf: Bool
        let cr: Bool
        let reasoning: String
        let confidence: Double
        let createdAt: Date

        enum Kind: String, Codable, Equatable {
            case override
            case tempTarget

            var localizedTitle: String {
                switch self {
                case .override:
                    return String(localized: "Override", comment: "AI adjustment suggestion type")
                case .tempTarget:
                    return String(localized: "Temporary Target", comment: "AI adjustment suggestion type")
                }
            }

            var icon: String {
                switch self {
                case .override:
                    return "slider.horizontal.3"
                case .tempTarget:
                    return "scope"
                }
            }
        }
    }

    enum TherapySuggestionApplyError: LocalizedError {
        case missingProposedValue
        case missingTimeRange
        case missingSnapshot

        var errorDescription: String? {
            switch self {
            case .missingProposedValue:
                return String(localized: "The suggestion does not include a usable proposed value.", comment: "Therapy apply error")
            case .missingTimeRange:
                return String(localized: "The suggestion does not include a usable time range.", comment: "Therapy apply error")
            case .missingSnapshot:
                return String(localized: "The saved history record cannot be reverted because its original settings snapshot is incomplete.", comment: "Therapy apply error")
            }
        }
    }

    // MARK: - Settings Score

    struct SettingsScore {
        let score: Int // 0–100
        let grade: Grade
        let tir: Double
        let gmi: Double
        let timeBelowRange: Double
        let cv: Double

        enum Grade: String {
            case excellent = "Excellent"
            case good = "Good"
            case fair = "Fair"
            case needsWork = "Needs Work"

            var localizedTitle: String {
                switch self {
                case .excellent: return String(localized: "Excellent", comment: "AI settings score grade")
                case .good: return String(localized: "Good", comment: "AI settings score grade")
                case .fair: return String(localized: "Fair", comment: "AI settings score grade")
                case .needsWork: return String(localized: "Needs Work", comment: "AI settings score grade")
                }
            }
        }
    }
}

extension String {
    var aiInsightsNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
