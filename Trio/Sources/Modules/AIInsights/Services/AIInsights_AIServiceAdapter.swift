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
            /// Single primary image (kept for backward compatibility with
            /// existing call sites). When sending multiple images, populate
            /// `additionalImageData` with the rest — the provider serializers
            /// will attach `imageData` first, followed by all of
            /// `additionalImageData`, to the final user message.
            var imageData: Data? = nil
            var additionalImageData: [Data] = []
            var responseFormat: [String: Any]? = nil

            /// All images this request carries, in order — convenience for the
            /// provider serializers.
            var allImages: [Data] {
                var out: [Data] = []
                if let imageData { out.append(imageData) }
                out.append(contentsOf: additionalImageData)
                return out
            }
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

        private static func addTemperaturePreferredSampling(
            from request: AIRequest,
            to body: inout [String: Any],
            topPKey: String
        ) {
            if let temp = request.temperature {
                body["temperature"] = temp
            } else if let topP = request.topP {
                body[topPKey] = topP
            }
        }

        private static func addAnthropicSampling(
            from request: AIRequest,
            to body: inout [String: Any]
        ) {
            if let temp = request.temperature {
                body["temperature"] = temp
                return
            }

            if let topP = request.topP { body["top_p"] = topP }
            if let topK = request.topK { body["top_k"] = topK }
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

        // MARK: - Audio Transcription

        static func transcribeAudio(
            audioData: Data,
            mimeType: String,
            provider: AIProvider,
            model: String,
            baseURL: String,
            apiKey: String,
            languageHint: String
        ) async throws -> String {
            guard !apiKey.isEmpty else { throw AIError.noAPIKey }

            switch provider {
            case .google:
                return try await transcribeGeminiAudio(
                    audioData: audioData,
                    mimeType: mimeType,
                    model: model,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    languageHint: languageHint
                )
            case .openai, .custom:
                return try await transcribeOpenAICompatibleAudio(
                    audioData: audioData,
                    mimeType: mimeType,
                    model: model,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    languageHint: languageHint
                )
            case .anthropic:
                throw AIError.parsingError("Anthropic does not support audio transcription in this FoodFinder flow.")
            }
        }

        private static func transcribeGeminiAudio(
            audioData: Data,
            mimeType: String,
            model: String,
            baseURL: String,
            apiKey: String,
            languageHint: String
        ) async throws -> String {
            let urlString: String
            if baseURL.contains(":generateContent") || baseURL.contains(":streamGenerateContent") {
                urlString = "\(baseURL)?key=\(apiKey)"
            } else {
                let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                urlString = "\(trimmed)/\(model):generateContent?key=\(apiKey)"
            }

            guard let url = URL(string: urlString) else { throw AIError.invalidURL }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")

            let prompt = """
            Transcribe this short spoken FoodFinder meal description.
            Language hint: \(languageHint).
            Return only the transcript. Do not translate, summarize, add punctuation notes, or wrap it in JSON.
            """
            let body: [String: Any] = [
                "contents": [[
                    "role": "user",
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": mimeType,
                                "data": audioData.base64EncodedString()
                            ]
                        ],
                        ["text": prompt]
                    ]
                ]],
                "generationConfig": [
                    "temperature": 0,
                    "maxOutputTokens": 512
                ]
            ]
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await performRequest(urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError.parsingError("Invalid response type")
            }
            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]]
            else {
                throw AIError.parsingError("Could not parse Gemini transcription response")
            }

            let transcript = parts
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw AIError.noContent }
            return transcript
        }

        private static func transcribeOpenAICompatibleAudio(
            audioData: Data,
            mimeType: String,
            model: String,
            baseURL: String,
            apiKey: String,
            languageHint: String
        ) async throws -> String {
            guard let url = openAITranscriptionURL(from: baseURL) else { throw AIError.invalidURL }

            let boundary = "Boundary-\(UUID().uuidString)"
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = multipartBody(
                boundary: boundary,
                fields: [
                    "model": model,
                    "response_format": "json",
                    "prompt": "Transcribe this FoodFinder meal description in the same language the user spoke. Language hint: \(languageHint)."
                ],
                fileField: "file",
                fileName: "foodfinder-dictation.m4a",
                mimeType: mimeType,
                fileData: audioData
            )

            let (data, response) = try await performRequest(urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError.parsingError("Invalid response type")
            }
            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String
            {
                let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else { throw AIError.noContent }
                return transcript
            }

            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                return text
            }

            throw AIError.parsingError("Could not parse transcription response")
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
            let userMessages = request.messages.filter { $0.role == .user }
            let lastUserIndex = userMessages.indices.last
            var userMessageCounter = -1
            for msg in request.messages {
                if msg.role == .system { continue } // handled separately
                let role = msg.role == .assistant ? "model" : "user"
                var parts: [[String: Any]] = [["text": msg.content]]

                // Attach any images to the LAST user message so the model sees
                // them in context of the most recent prompt.
                if msg.role == .user {
                    userMessageCounter += 1
                    if userMessageCounter == lastUserIndex {
                        for img in request.allImages {
                            parts.insert([
                                "inline_data": [
                                    "mime_type": "image/jpeg",
                                    "data": img.base64EncodedString()
                                ]
                            ], at: 0)
                        }
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

            // OpenAI-compatible providers expect images attached to the LAST
            // user message. Find that index up front so we don't accidentally
            // attach images to earlier user turns.
            let userIndices: [Int] = request.messages.enumerated().compactMap {
                $0.element.role == .user ? $0.offset : nil
            }
            let lastUserIndex = userIndices.last
            let images = request.allImages

            var messagesPayload: [[String: Any]] = []
            for (idx, msg) in request.messages.enumerated() {
                if msg.role == .user, idx == lastUserIndex, !images.isEmpty {
                    // Multimodal: send images + text as a content array.
                    var contentParts: [[String: Any]] = images.map { img in
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]
                        ]
                    }
                    contentParts.append([
                        "type": "text",
                        "text": msg.content
                    ])
                    messagesPayload.append(["role": msg.role.rawValue, "content": contentParts] as [String: Any])
                } else {
                    messagesPayload.append(["role": msg.role.rawValue, "content": msg.content])
                }
            }

            var body: [String: Any] = [
                "model": request.model,
                "messages": messagesPayload
            ]
            addTemperaturePreferredSampling(from: request, to: &body, topPKey: "top_p")
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

            // Attach images to the LAST user message only — Anthropic counts
            // each image block toward the prompt token cost.
            let lastUserIdx = chatMessages.lastIndex(where: { $0.role == .user })
            let images = request.allImages

            var messagesPayload: [[String: Any]] = []
            for (idx, msg) in chatMessages.enumerated() {
                if msg.role == .user, idx == lastUserIdx, !images.isEmpty {
                    var contentBlocks: [[String: Any]] = images.map { img in
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": img.base64EncodedString()
                            ]
                        ]
                    }
                    contentBlocks.append([
                        "type": "text",
                        "text": msg.content
                    ])
                    messagesPayload.append(["role": msg.role.rawValue, "content": contentBlocks])
                } else {
                    messagesPayload.append(["role": msg.role.rawValue, "content": msg.content])
                }
            }

            var body: [String: Any] = [
                "model": request.model,
                "messages": messagesPayload,
                "max_tokens": request.maxTokens ?? 4096
            ]

            if let systemContent = systemMessages.first?.content {
                body["system"] = systemContent
            }
            addAnthropicSampling(from: request, to: &body)

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
                  let contentArray = json["content"] as? [[String: Any]]
            else {
                throw AIError.parsingError("Could not parse Anthropic response")
            }

            let text = contentArray
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            guard !text.isEmpty else {
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

        private static func openAITranscriptionURL(from baseURL: String) -> URL? {
            var trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed.hasSuffix("/chat/completions") {
                trimmed = String(trimmed.dropLast("/chat/completions".count)) + "/audio/transcriptions"
            } else if trimmed.hasSuffix("/responses") {
                trimmed = String(trimmed.dropLast("/responses".count)) + "/audio/transcriptions"
            } else if !trimmed.hasSuffix("/audio/transcriptions") {
                trimmed += "/audio/transcriptions"
            }
            return URL(string: trimmed)
        }

        private static func multipartBody(
            boundary: String,
            fields: [String: String],
            fileField: String,
            fileName: String,
            mimeType: String,
            fileData: Data
        ) -> Data {
            var body = Data()
            let lineBreak = "\r\n"

            for (name, value) in fields {
                body.appendString("--\(boundary)\(lineBreak)")
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
                body.appendString("\(value)\(lineBreak)")
            }

            body.appendString("--\(boundary)\(lineBreak)")
            body.appendString("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\(lineBreak)")
            body.appendString("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
            body.append(fileData)
            body.appendString(lineBreak)
            body.appendString("--\(boundary)--\(lineBreak)")
            return body
        }

        private static func performRequest(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
            do {
                return try await URLSession.shared.data(for: urlRequest)
            } catch {
                throw AIError.networkError(error)
            }
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
