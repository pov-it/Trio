import Foundation

enum AIInsights {
    static let defaultSystemPrompt = """
    Analyze the following glucose and treatment data for a person with Type 1 Diabetes.
    Format your response strictly using this structure:
    Observation: [Summary of the situation]
    Evidence: [Specific data points supporting the observation]
    Possible interpretation: [What this may mean]
    Candidate adjustment: [Conservative setting change to consider]
    Evaluation plan: [What to watch for after making changes]
    Reasons not to change: [Contraindications or reasons the evidence is weak]
    """

    enum AIProvider: String, CaseIterable, Identifiable, Codable, JSON {
        case google = "Google Gemini"
        case openai = "OpenAI"
        case custom = "Custom"
        
        var id: String { rawValue }
        
        var defaultBaseURL: String {
            switch self {
            case .google: return "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent"
            case .openai: return "https://api.openai.com/v1/chat/completions"
            case .custom: return ""
            }
        }
        
        var defaultModel: String {
            switch self {
            case .google: return "gemini-1.5-flash"
            case .openai: return "gpt-4-turbo"
            case .custom: return ""
            }
        }
    }
}
