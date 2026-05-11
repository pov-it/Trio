import Foundation
import Observation
import Swinject

extension AIInsights {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var isGenerating: Bool = false
        var insightsResult: String = ""
        var apiKey: String = ""
        var baseURL: String = "https://api.openai.com/v1/chat/completions"
        var model: String = "gpt-4-turbo"
        
        var zglucoData: String = ""
        
        override func subscribe() {
            // Initialize from keychain or UserDefaults if necessary
        }
        
        @MainActor
        func generateInsights() async {
            isGenerating = true
            defer { isGenerating = false }
            
            do {
                // Simulate network call
                try await Task.sleep(nanoseconds: 1_000_000_000)
                
                // Parse zgluco data
                let records = ZGlucoParser.parse(data: zglucoData)
                let recordsCount = records.count
                
                insightsResult = """
                Observation:
                Found \(recordsCount) zGluco records in the provided data.
                
                Evidence:
                - Data contains recent glucose trends and therapy inputs.
                
                Interpretation:
                - (LLM analysis will be injected here)
                
                Candidate Adjustment:
                - (Suggested profile/setting changes)
                
                Evaluation:
                - Consult your healthcare provider before making these adjustments.
                """
            } catch {
                insightsResult = "Error generating insights: \(error.localizedDescription)"
            }
        }
    }
}
