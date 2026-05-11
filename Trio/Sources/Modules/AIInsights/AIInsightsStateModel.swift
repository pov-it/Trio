import Foundation
import Observation
import Swinject

extension AIInsights {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var isGenerating: Bool = false
        var insightsResult: String = ""
        var apiKey: String = ""
        var baseURL: String = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent"
        var model: String = "gemini-1.5-flash"
        
        var zglucoData: String = ""
        
        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }
        }
        
        func saveAPIKey() {
            provider.keychain.setValue(apiKey, forKey: "ai_insights_api_key")
        }
        
        @MainActor
        func generateInsights() async {
            guard !apiKey.isEmpty else {
                insightsResult = "Error: API Key is missing."
                return
            }
            
            isGenerating = true
            defer { isGenerating = false }
            
            do {
                // Fetch data from Nightscout
                let glucose = await provider.fetchGlucose(since: Date().addingTimeInterval(-24 * 3600))
                let carbs = await provider.fetchCarbs()
                
                let promptText = """
                Analyze the following glucose and treatment data for a person with Type 1 Diabetes.
                Format your response strictly using this structure:
                Observation: [Summary of the situation]
                Evidence: [Specific data points supporting the observation]
                Interpretation: [What this means for the treatment]
                Candidate Adjustment: [Proposed changes to settings like basal, ISF, or CR]
                Evaluation: [What to watch for after making changes]
                
                Data:
                Glucose (last 24h): \(glucose.map { "\($0.dateString): \($0.sgv) \($0.direction ?? "")" }.joined(separator: "\n"))
                Carbs: \(carbs.map { "\($0.createdAt): \($0.carbs)g" }.joined(separator: "\n"))
                
                Additional Context (zGluco):
                \(zglucoData)
                """
                
                let urlString = "\(baseURL)?key=\(apiKey)"
                guard let url = URL(string: urlString) else { throw URLError(.badURL) }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let body: [String: Any] = [
                    "contents": [[
                        "parts": [[
                            "text": promptText
                        ]]
                    ]]
                ]
                
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    insightsResult = "Error from Gemini API: \(errorBody)"
                    return
                }
                
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let text = firstPart["text"] as? String {
                    insightsResult = text
                } else {
                    insightsResult = "Error: Could not parse response from Gemini."
                }
                
            } catch {
                insightsResult = "Error generating insights: \(error.localizedDescription)"
            }
        }
    }
}
