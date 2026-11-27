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
    /// OpenAI's own endpoints (and Azure's) take `max_completion_tokens` and refuse a `temperature`
    /// on their newer models; servers that imitate the protocol (Ollama, LM Studio, llama.cpp, vLLM,
    /// OpenRouter) still expect `max_tokens` and accept a temperature.
    let modernParameters: Bool

    /// `isLocal` should be true only for servers on this machine; it marks the model as hosted
    /// otherwise (which triggers the "triage sends every item to a provider" warning).
    /// `nativeTools`: the server and model support the `tools` parameter. Many local models do not,
    /// so it is opt-in; without it the assistant uses its JSON text protocol, which works everywhere.
    public init(
        baseURL: URL, model: String, apiKey: String? = nil, vision: Bool = false,
        contextChars: Int = 60_000, isLocal: Bool? = nil, nativeTools: Bool = false, modernParameters: Bool? = nil, session: URLSession = .shared
    ) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.session = session
        let host = baseURL.host?.lowercased() ?? ""
        self.modernParameters = modernParameters ?? (host == "api.openai.com" || host.hasSuffix(".openai.azure.com"))
        let local = isLocal ?? baseURL.isLoopbackHost
        self.capabilities = ModelCapabilities(vision: vision, contextChars: contextChars, isLocal: local, nativeTools: nativeTools)
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
        applySampling(request, to: &body)
        if request.jsonMode { body["response_format"] = ["type": "json_object"] }

        let obj = try await post(body)
        guard let choice = (obj["choices"] as? [[String: Any]])?.first,
            let message = choice["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LLMError.badResponse("no message content in chat completion") }
        return content
    }

    private func applySampling(_ request: CompletionRequest, to body: inout [String: Any]) {
        if modernParameters {
            // Reasoning counts toward this cap, so leave room for it.
            if let n = request.maxTokens { body["max_completion_tokens"] = max(n, 2_048) }
        } else {
            if let t = request.temperature { body["temperature"] = t }
            if let n = request.maxTokens { body["max_tokens"] = n }
        }
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse("not a JSON object") }
        return obj
    }

    /// Native tool calling in the chat-completions dialect: `tools` as functions, calls in
    /// `tool_calls` (arguments as a JSON string), results as `role: tool` messages.
    public func completeWithTools(_ request: CompletionRequest, tools: [ToolSpec]) async throws -> ModelReply {
        var messages: [[String: Any]] = []
        for m in request.messages {
            if !m.toolResults.isEmpty {
                var pictures: [Data] = []
                for r in m.toolResults {
                    messages.append(["role": "tool", "tool_call_id": r.toolCallID, "content": r.text.isEmpty ? "(empty)" : r.text])
                    pictures += r.images
                }
                // A tool message cannot carry an image in this dialect: it follows as a user message.
                if !pictures.isEmpty, capabilities.vision {
                    var parts: [[String: Any]] = [["type": "text", "text": "Image from the tool result above."]]
                    for img in pictures { parts.append(["type": "image_url", "image_url": ["url": "data:\(Self.mime(img));base64,\(img.base64EncodedString())"]]) }
                    messages.append(["role": "user", "content": parts])
                }
            } else if m.role == .assistant, !m.toolCalls.isEmpty {
                let calls: [[String: Any]] = m.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": JSONValue.object($0.arguments).jsonText]] }
                messages.append(["role": "assistant", "content": m.text, "tool_calls": calls])
            } else if m.images.isEmpty || !capabilities.vision {
                messages.append(["role": m.role.rawValue, "content": m.text])
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                for img in m.images { parts.append(["type": "image_url", "image_url": ["url": "data:\(Self.mime(img));base64,\(img.base64EncodedString())"]]) }
                messages.append(["role": m.role.rawValue, "content": parts])
            }
        }
        var body: [String: Any] = ["model": model, "messages": messages]
        body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.inputSchema.anyValue]] as [String: Any] }
        applySampling(request, to: &body)

        let obj = try await post(body)
        guard let choice = (obj["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else { throw LLMError.badResponse("no message in chat completion") }
        var calls: [ModelToolCall] = []
        for (i, c) in ((message["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
            guard let fn = c["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
            let raw = fn["arguments"] as? String ?? "{}"
            // A malformed argument string becomes an empty object; the tool then reports what is missing.
            let arguments = JSONValue(jsonText: raw)?.asObject ?? [:]
            calls.append(ModelToolCall(id: c["id"] as? String ?? "call_\(i)", name: name, arguments: arguments))
        }
        var stop: String?
        switch choice["finish_reason"] as? String {
        case "stop": stop = "end_turn"
        case "tool_calls", "function_call": stop = "tool_use"
        case "length": stop = "max_tokens"
        case "content_filter": stop = "refusal"
        default: stop = nil
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty, calls.isEmpty { stop = "refusal" }
        let usage = (obj["usage"] as? [String: Any]).map { u in
            ModelUsage(
                inputTokens: u["prompt_tokens"] as? Int ?? 0, outputTokens: u["completion_tokens"] as? Int ?? 0,
                cacheReadInputTokens: (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0)
        }
        return ModelReply(text: message["content"] as? String ?? "", toolCalls: calls, stopReason: stop, usage: usage)
    }

    private static func mime(_ image: Data) -> String { image.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg" }
}

/// Anthropic's Messages API.
public struct AnthropicModel: LanguageModel {
    public let name: String
    public let capabilities: ModelCapabilities
    let model: String
    let apiKey: String
    let baseURL: URL
    let session: URLSession
    /// Mark the stable prefix of a tool conversation (tools, system prompt, history) as cacheable.
    /// An agent run repeats that prefix on every step, so this makes the later steps cheaper and faster.
    let promptCaching: Bool

    public init(
        model: String, apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!,
        contextChars: Int = 400_000, nativeTools: Bool = true, promptCaching: Bool = true, session: URLSession = .shared
    ) {
        self.model = model; self.apiKey = apiKey; self.baseURL = baseURL; self.session = session; self.promptCaching = promptCaching
        self.capabilities = ModelCapabilities(vision: true, contextChars: contextChars, isLocal: false, nativeTools: nativeTools)
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
        // No `temperature`: current models (and every model on API version 2026-10-21) reject sampling
        // parameters, and the default is what they are tuned for.
        var body: [String: Any] = ["model": model, "max_tokens": Self.tokenLimit(request.maxTokens), "messages": messages]
        if !system.isEmpty { body["system"] = system }

        let obj = try await post(body)
        guard let content = obj["content"] as? [[String: Any]] else { throw LLMError.badResponse("no content in Messages response") }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    /// Thinking is on by default on current models and counts toward `max_tokens`, so a cap sized for
    /// a short answer can be used up before the answer starts. A cap only limits; it never lengthens a reply.
    static func tokenLimit(_ requested: Int?) -> Int { max(requested ?? 4_096, 4_096) }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
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
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse("not a JSON object") }
        return obj
    }

    private static func imageBlock(_ img: Data) -> [String: Any] {
        let mime = img.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg"
        return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": img.base64EncodedString()]]
    }

    /// Native tool calling: `tools`, `tool_use` blocks from the model, `tool_result` blocks back.
    public func completeWithTools(_ request: CompletionRequest, tools: [ToolSpec]) async throws -> ModelReply {
        let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        var messages: [[String: Any]] = []
        for m in request.messages where m.role != .system {
            var blocks: [[String: Any]] = []
            if m.role == .assistant, !m.providerBlocks.isEmpty {
                // Exactly what the model sent, signed thinking blocks included.
                blocks = m.providerBlocks.compactMap { $0.anyValue as? [String: Any] }
            } else if !m.toolResults.isEmpty {
                for r in m.toolResults {
                    var content: [[String: Any]] = [["type": "text", "text": r.text.isEmpty ? "(empty)" : r.text]]
                    content += r.images.map(Self.imageBlock)
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": r.toolCallID, "content": content]
                    if r.isError { block["is_error"] = true }
                    blocks.append(block)
                }
            } else if m.role == .assistant {
                if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(["type": "text", "text": m.text]) }
                for c in m.toolCalls { blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": JSONValue.object(c.arguments).anyValue]) }
                if blocks.isEmpty { blocks.append(["type": "text", "text": "(no text)"]) }
            } else {
                blocks += m.images.map(Self.imageBlock)
                blocks.append(["type": "text", "text": m.text])
            }
            messages.append(["role": m.role.rawValue, "content": blocks])
        }

        var toolDefinitions: [[String: Any]] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema.anyValue] }
        var systemField: Any = system
        if promptCaching {
            // Breakpoints: after the system prompt (this also covers the tool definitions before it)
            // and on the newest message, so each step reuses everything the previous step sent.
            if !system.isEmpty { systemField = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]] }
            else if !toolDefinitions.isEmpty { toolDefinitions[toolDefinitions.count - 1]["cache_control"] = ["type": "ephemeral"] }
            if var last = messages.popLast(), var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = blocks
                messages.append(last)
            }
        }
        var body: [String: Any] = ["model": model, "max_tokens": Self.tokenLimit(request.maxTokens), "messages": messages, "tools": toolDefinitions]
        if !system.isEmpty { body["system"] = systemField }

        let obj = try await post(body)
        guard let content = obj["content"] as? [[String: Any]] else { throw LLMError.badResponse("no content in Messages response") }
        var text = "", calls: [ModelToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text": text += block["text"] as? String ?? ""
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                calls.append(ModelToolCall(id: id, name: name, arguments: JSONValue(any: block["input"]).asObject ?? [:]))
            default: break
            }
        }
        let usage = (obj["usage"] as? [String: Any]).map { u in
            ModelUsage(
                inputTokens: u["input_tokens"] as? Int ?? 0, outputTokens: u["output_tokens"] as? Int ?? 0,
                cacheCreationInputTokens: u["cache_creation_input_tokens"] as? Int ?? 0, cacheReadInputTokens: u["cache_read_input_tokens"] as? Int ?? 0)
        }
        // Every content block is kept as it came (thinking blocks included) to be sent back unchanged.
        return ModelReply(text: text, toolCalls: calls, stopReason: obj["stop_reason"] as? String, usage: usage, providerBlocks: content.map { JSONValue(any: $0) })
    }
}
