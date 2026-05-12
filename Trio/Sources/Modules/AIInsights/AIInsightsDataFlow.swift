import Foundation

enum AIInsights {
    static let defaultSystemPrompt = """
    Analyze the following glucose and treatment data for a person with Type 1 Diabetes using an OpenAPS-based algorithm (oref0/oref1).
    Format your response strictly using this structure:
    Observation: [Summary of the situation]
    Evidence: [Specific data points supporting the observation]
    Possible interpretation: [What this may mean]
    Candidate adjustment: [Conservative setting change to consider — note that Trio uses OpenAPS, so adjustments refer to basal rates, ISF, and carb ratios in the profile]
    Evaluation plan: [What to watch for after making changes]
    Reasons not to change: [Contraindications or reasons the evidence is weak]
    """

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

    enum HintChip: String, CaseIterable, Identifiable {
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

    struct ChatMessage: Identifiable {
        var id: UUID = UUID()
        let content: String
        let isUser: Bool
        let timestamp: Date
        var hintChip: HintChip?
    }

    // MARK: - Suggestion

    struct Suggestion: Identifiable, Codable {
        var id: UUID = UUID()
        let settingType: SettingType
        let timeBlock: String
        let currentValue: String
        let proposedValue: String
        let reasoning: String
        let confidence: Double
        let createdAt: Date

        enum SettingType: String, Codable {
            case basalRate = "Basal Rate"
            case isf = "Insulin Sensitivity Factor"
            case carbRatio = "Carb Ratio"
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
        }
    }
}
