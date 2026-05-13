import Foundation

// MARK: - AI Service Adapter

/// Provider-agnostic HTTP client for AI API calls.
/// Supports Google Gemini, OpenAI, Anthropic, and custom OpenAI-compatible endpoints.
extension AIInsights {
    enum AIServiceAdapter {
        // MARK: - Request/Response Types

        struct AIRequest {
            let model: String
            let messages: [ChatMessagePayload]
            let temperature: Double?
            let topP: Double?
            let topK: Int?
            let maxTokens: Int?
            var imageData: Data? = nil
            var responseFormat: [String: Any]? = nil
        }

        struct ChatMessagePayload {
            let role: Role
            let content: String

            enum Role: String {
                case system
                case user
                case assistant
            }
        }

        struct AIResponse {
            let text: String
            let model: String?
            let usage: Usage?

            struct Usage {
                let promptTokens: Int?
                let completionTokens: Int?
                let totalTokens: Int?
            }
        }

        enum AIError: LocalizedError {
            case invalidURL
            case noAPIKey
            case httpError(statusCode: Int, body: String)
            case parsingError(String)
            case noContent
            case rateLimited(retryAfter: Double?)
            case networkError(Error)

            var errorDescription: String? {
                switch self {
                case .invalidURL:
                    return String(localized: "Invalid API URL", comment: "AI error message")
                case .noAPIKey:
                    return String(localized: "API key is missing", comment: "AI error message")
                case let .httpError(statusCode, body):
                    return String(localized: "API error (\(statusCode)): \(body)", comment: "AI error with status code")
                case let .parsingError(detail):
                    return String(localized: "Could not parse response: \(detail)", comment: "AI error message")
                case .noContent:
                    return String(localized: "No content in response", comment: "AI error message")
                case let .rateLimited(retryAfter):
                    if let retryAfter {
                        return String(localized: "Rate limited. Try again in \(Int(retryAfter))s.", comment: "AI rate limit error")
                    }
                    return String(localized: "Rate limited. Please try again later.", comment: "AI rate limit error")
                case let .networkError(error):
                    return String(localized: "Network error: \(error.localizedDescription)", comment: "AI network error")
                }
            }
        }

        // MARK: - Main Send Method

        static func send(
            request: AIRequest,
            provider: AIProvider,
            baseURL: String,
            apiKey: String
        ) async throws -> AIResponse {
            guard !apiKey.isEmpty else { throw AIError.noAPIKey }

            switch provider {
            case .google:
                return try await sendGemini(request: request, baseURL: baseURL, apiKey: apiKey)
            case .openai, .custom:
                return try await sendOpenAICompatible(request: request, baseURL: baseURL, apiKey: apiKey)
            case .anthropic:
                return try await sendAnthropic(request: request, baseURL: baseURL, apiKey: apiKey)
            }
        }

        // MARK: - Test Connection

        static func testConnection(
            provider: AIProvider,
            model: String,
            baseURL: String,
            apiKey: String
        ) async throws -> Bool {
            let testRequest = AIRequest(
                model: model,
                messages: [
                    ChatMessagePayload(role: .user, content: "Say 'OK' if you can read this.")
                ],
                temperature: 0,
                topP: nil,
                topK: nil,
                maxTokens: 10
            )
            _ = try await send(request: testRequest, provider: provider, baseURL: baseURL, apiKey: apiKey)
            return true
        }

        // MARK: - Google Gemini

        private static func sendGemini(
            request: AIRequest,
            baseURL: String,
            apiKey: String
        ) async throws -> AIResponse {
            // Build the URL: baseURL should end with the model-specific endpoint
            // e.g. https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent
            let urlString: String
            if baseURL.contains(":generateContent") || baseURL.contains(":streamGenerateContent") {
                urlString = "\(baseURL)?key=\(apiKey)"
            } else {
                // Construct from base: baseURL/model:generateContent
                let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                urlString = "\(trimmed)/\(request.model):generateContent?key=\(apiKey)"
            }

            guard let url = URL(string: urlString) else { throw AIError.invalidURL }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")

            // Build Gemini request body
            var contents: [[String: Any]] = []
            // Gemini uses "user" role for all messages; system prompt goes in systemInstruction
            for msg in request.messages {
                if msg.role == .system { continue } // handled separately
                let role = msg.role == .assistant ? "model" : "user"
                var parts: [[String: Any]] = [["text": msg.content]]

                // Attach image to the last user message if available
                if msg.role == .user && request.imageData != nil {
                    if let imgData = request.imageData {
                        parts.insert([
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": imgData.base64EncodedString()
                            ]
                        ], at: 0)
                    }
                }

                contents.append([
                    "role": role,
                    "parts": parts
                ])
            }

            var body: [String: Any] = ["contents": contents]

            // System instruction from system messages
            let systemMessages = request.messages.filter { $0.role == .system }
            if let systemMsg = systemMessages.first {
                body["systemInstruction"] = ["parts": [["text": systemMsg.content]]]
            }

            // Generation config
            var genConfig: [String: Any] = [:]
            if let temp = request.temperature { genConfig["temperature"] = temp }
            if let topP = request.topP { genConfig["topP"] = topP }
            if let topK = request.topK { genConfig["topK"] = topK }
            if let maxTokens = request.maxTokens { genConfig["maxOutputTokens"] = maxTokens }
            if request.responseFormat != nil { genConfig["responseMimeType"] = "application/json" }
            if !genConfig.isEmpty {
                body["generationConfig"] = genConfig
            }

            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await performRequest(urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError.parsingError("Invalid response type")
            }

            if httpResponse.statusCode == 429 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw AIError.rateLimited(retryAfter: retryAfter)
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
            }

            // Parse Gemini response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String
            else {
                throw AIError.parsingError("Could not parse Gemini response")
            }

            var usage: AIResponse.Usage?
            if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                usage = AIResponse.Usage(
                    promptTokens: usageMetadata["promptTokenCount"] as? Int,
                    completionTokens: usageMetadata["candidatesTokenCount"] as? Int,
                    totalTokens: usageMetadata["totalTokenCount"] as? Int
                )
            }

            return AIResponse(
                text: text,
                model: json["modelVersion"] as? String,
                usage: usage
            )
        }

        // MARK: - OpenAI Compatible

        private static func sendOpenAICompatible(
            request: AIRequest,
            baseURL: String,
            apiKey: String
        ) async throws -> AIResponse {
            guard let url = URL(string: baseURL) else { throw AIError.invalidURL }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            var messagesPayload: [[String: Any]] = []
            for msg in request.messages {
                if msg.role == .user, let imgData = request.imageData {
                    // Multimodal: send image + text as content array
                    let contentParts: [[String: Any]] = [
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(imgData.base64EncodedString())"]
                        ],
                        [
                            "type": "text",
                            "text": msg.content
                        ]
                    ]
                    messagesPayload.append(["role": msg.role.rawValue, "content": contentParts] as [String: Any])
                } else {
                    messagesPayload.append(["role": msg.role.rawValue, "content": msg.content])
                }
            }

            var body: [String: Any] = [
                "model": request.model,
                "messages": messagesPayload
            ]
            if let temp = request.temperature { body["temperature"] = temp }
            if let topP = request.topP { body["top_p"] = topP }
            if let maxTokens = request.maxTokens { body["max_tokens"] = maxTokens }
            if let responseFormat = request.responseFormat { body["response_format"] = responseFormat }

            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await performRequest(urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError.parsingError("Invalid response type")
            }

            if httpResponse.statusCode == 429 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw AIError.rateLimited(retryAfter: retryAfter)
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                throw AIError.parsingError("Could not parse OpenAI response")
            }

            var usage: AIResponse.Usage?
            if let usageData = json["usage"] as? [String: Any] {
                usage = AIResponse.Usage(
                    promptTokens: usageData["prompt_tokens"] as? Int,
                    completionTokens: usageData["completion_tokens"] as? Int,
                    totalTokens: usageData["total_tokens"] as? Int
                )
            }

            return AIResponse(
                text: content,
                model: json["model"] as? String,
                usage: usage
            )
        }

        // MARK: - Anthropic

        private static func sendAnthropic(
            request: AIRequest,
            baseURL: String,
            apiKey: String
        ) async throws -> AIResponse {
            guard let url = URL(string: baseURL) else { throw AIError.invalidURL }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            // Anthropic separates system from messages
            let systemMessages = request.messages.filter { $0.role == .system }
            let chatMessages = request.messages.filter { $0.role != .system }

            var messagesPayload: [[String: String]] = []
            for msg in chatMessages {
                messagesPayload.append(["role": msg.role.rawValue, "content": msg.content])
            }

            var body: [String: Any] = [
                "model": request.model,
                "messages": messagesPayload,
                "max_tokens": request.maxTokens ?? 4096
            ]

            if let systemContent = systemMessages.first?.content {
                body["system"] = systemContent
            }
            if let temp = request.temperature { body["temperature"] = temp }
            if let topP = request.topP { body["top_p"] = topP }
            if let topK = request.topK { body["top_k"] = topK }

            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await performRequest(urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError.parsingError("Invalid response type")
            }

            if httpResponse.statusCode == 429 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw AIError.rateLimited(retryAfter: retryAfter)
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
            }

            // Parse Anthropic response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contentArray = json["content"] as? [[String: Any]],
                  let firstBlock = contentArray.first,
                  let text = firstBlock["text"] as? String
            else {
                throw AIError.parsingError("Could not parse Anthropic response")
            }

            var usage: AIResponse.Usage?
            if let usageData = json["usage"] as? [String: Any] {
                usage = AIResponse.Usage(
                    promptTokens: usageData["input_tokens"] as? Int,
                    completionTokens: usageData["output_tokens"] as? Int,
                    totalTokens: nil
                )
            }

            return AIResponse(
                text: text,
                model: json["model"] as? String,
                usage: usage
            )
        }

        // MARK: - Shared Network Helper

        private static func performRequest(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
            do {
                return try await URLSession.shared.data(for: urlRequest)
            } catch {
                throw AIError.networkError(error)
            }
        }
    }
}
