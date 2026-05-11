import Foundation
import Observation
import Swinject

extension AIInsights {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var isGenerating: Bool = false
        var insightsResult: String = ""
        var apiKey: String = ""
        var providerType: AIProvider = .google
        var model: String = AIProvider.google.defaultModel
        var baseURL: String = AIProvider.google.defaultBaseURL
        var systemPrompt: String = AIInsights.defaultSystemPrompt
        
        override func subscribe() {
            if let savedKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") {
                self.apiKey = savedKey
            }

            providerType = provider.settings.aiProvider
            model = provider.settings.aiModel
            baseURL = provider.settings.aiBaseURL
            systemPrompt = provider.settings.aiSystemPrompt
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
            provider.settings = settings
        }
        
        func resetToDefaults() {
            baseURL = providerType.defaultBaseURL
            model = providerType.defaultModel
            saveSettings()
        }
        
        @MainActor
        func generateInsights() async {
            guard provider != nil else {
                insightsResult = "Error: AI Insights is not ready yet."
                return
            }

            guard !apiKey.isEmpty else {
                insightsResult = "Error: API Key is missing."
                return
            }
            
            isGenerating = true
            defer { isGenerating = false }
            
            do {
                let glucose = await provider.fetchGlucose(since: Date().addingTimeInterval(-24 * 3600))
                let carbs = await provider.fetchCarbs()
                
                let dataContext = """
                Glucose (last 24h): \(glucose.map { "\($0.dateString): \($0.sgv ?? 0) \($0.direction?.rawValue ?? "")" }.joined(separator: "\n"))
                Carbs: \(carbs.map { "\($0.createdAt): \($0.carbs)g" }.joined(separator: "\n"))
                """
                
                let fullPrompt = "\(systemPrompt)\n\nData:\n\(dataContext)"
                
                switch providerType {
                case .google:
                    try await callGemini(prompt: fullPrompt)
                case .openai, .custom:
                    try await callOpenAICompatible(prompt: fullPrompt)
                }
                
            } catch {
                insightsResult = "Error generating insights: \(error.localizedDescription)"
            }
        }
        
        private func callGemini(prompt: String) async throws {
            let urlString = "\(baseURL)?key=\(apiKey)"
            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "contents": [[
                    "parts": [[
                        "text": prompt
                    ]]
                ]]
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                insightsResult = "Error from Gemini API (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(errorBody)"
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
        }
        
        private func callOpenAICompatible(prompt: String) async throws {
            guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                insightsResult = "Error from API (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(errorBody)"
                return
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                insightsResult = content
            } else {
                insightsResult = "Error: Could not parse response from API."
            }
        }
    }
}
