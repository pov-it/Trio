import Foundation

enum AIInsights {
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
