import Foundation

/// Any server speaking the OpenAI chat-completions protocol: OpenAI, OpenRouter, Ollama
/// (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`), llama.cpp server, vLLM.
public struct OpenAICompatibleModel: LanguageModel {
    public let name: String
    public let capabilities: ModelCapabilities
    let baseURL: URL
    let model: String
    let apiKey: String?
    let session: URLSession

    /// `isLocal` should be true only for servers on this machine; it marks the model as hosted
    /// otherwise (which triggers the "triage sends every item to a provider" warning).
    public init(
        baseURL: URL, model: String, apiKey: String? = nil, vision: Bool = false,
        contextChars: Int = 60_000, isLocal: Bool? = nil, session: URLSession = .shared
    ) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.session = session
        let local = isLocal ?? baseURL.isLoopbackHost
        self.capabilities = ModelCapabilities(vision: vision, contextChars: contextChars, isLocal: local)
        self.name = "openai-compat:\(model)"
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        var messages: [[String: Any]] = []
        for m in request.messages {
            if m.images.isEmpty || !capabilities.vision {
                messages.append(["role": m.role.rawValue, "content": m.text])
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                for img in m.images {
                    let mime = img.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg"
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(img.base64EncodedString())"]])
                }
                messages.append(["role": m.role.rawValue, "content": parts])
            }
        }
        var body: [String: Any] = ["model": model, "messages": messages]
        if let t = request.temperature { body["temperature"] = t }
        if let n = request.maxTokens { body["max_tokens"] = n }
        if request.jsonMode { body["response_format"] = ["type": "json_object"] }

        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choice = (obj["choices"] as? [[String: Any]])?.first,
            let message = choice["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LLMError.badResponse("no message content in chat completion") }
        return content
    }
}

/// Anthropic's Messages API.
public struct AnthropicModel: LanguageModel {
    public let name: String
    public let capabilities: ModelCapabilities
    let model: String
    let apiKey: String
    let baseURL: URL
    let session: URLSession

    public init(
        model: String, apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!,
        contextChars: Int = 400_000, session: URLSession = .shared
    ) {
        self.model = model; self.apiKey = apiKey; self.baseURL = baseURL; self.session = session
        self.capabilities = ModelCapabilities(vision: true, contextChars: contextChars, isLocal: false)
        self.name = "anthropic:\(model)"
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        var messages: [[String: Any]] = []
        for m in request.messages where m.role != .system {
            var blocks: [[String: Any]] = []
            for img in m.images {
                let mime = img.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg"
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": img.base64EncodedString()]])
            }
            blocks.append(["type": "text", "text": m.text])
            messages.append(["role": m.role.rawValue, "content": blocks])
        }
        var body: [String: Any] = ["model": model, "max_tokens": request.maxTokens ?? 4096, "messages": messages]
        if !system.isEmpty { body["system"] = system }
        if let t = request.temperature { body["temperature"] = t }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = obj["content"] as? [[String: Any]]
        else { throw LLMError.badResponse("no content in Messages response") }
        return content.compactMap { $0["text"] as? String }.joined()
    }
}
