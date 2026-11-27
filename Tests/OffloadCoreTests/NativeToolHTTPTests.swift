import XCTest
@testable import OffloadCore

/// Answers every request from a closure and remembers what was sent, so the request a provider
/// would receive can be inspected without a network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var sent: [(request: URLRequest, body: Data)] = []

    static func session(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, Data)) -> URLSession {
        Self.handler = handler; Self.sent = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        Self.sent.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NativeToolHTTPTests: XCTestCase {
    let toolSpecs: [ToolSpec] = [
        ToolSpec(name: "search_memory", description: "search", inputSchema: JSONSchema.object(["query": JSONSchema.string()], required: ["query"])),
        ToolSpec(name: "click", description: "click", inputSchema: JSONSchema.object(["x": JSONSchema.integer()], required: ["x"]), tier: .act),
    ]

    var conversation: [ChatMessage] {
        [
            .system("You are an assistant."),
            .user("THE TASK: find the landlord"),
            .assistant("looking", toolCalls: [ModelToolCall(id: "toolu_1", name: "search_memory", arguments: ["query": "landlord"])]),
            .toolResults([ToolResultBlock(toolCallID: "toolu_1", name: "search_memory", text: "NOTE Home/Apartment.md", images: [Data([0x89, 0x50, 0x4E, 0x47])], isError: false)]),
        ]
    }

    func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    // MARK: Anthropic

    func testAnthropicSendsToolsAndCachesTheStablePrefix() async throws {
        let reply = #"{"content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_2","name":"click","input":{"x":10}}],"stop_reason":"tool_use"}"#
        let session = StubURLProtocol.session { _, _ in (200, Data(reply.utf8)) }
        let model = AnthropicModel(model: "claude-test", apiKey: "k", session: session)
        XCTAssertTrue(model.capabilities.nativeTools)
        let r = try await model.completeWithTools(CompletionRequest(messages: conversation, temperature: 0.2, maxTokens: 500), tools: toolSpecs)

        XCTAssertEqual(r.text, "Checking.")
        XCTAssertEqual(r.toolCalls, [ModelToolCall(id: "toolu_2", name: "click", arguments: ["x": 10])])

        let sent = try XCTUnwrap(StubURLProtocol.sent.first)
        XCTAssertEqual(sent.request.url?.path, "/v1/messages")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), "k")
        let body = json(sent.body)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["search_memory", "click"])
        XCTAssertNotNil(tools[0]["input_schema"], "the schema goes in input_schema")

        let system = try XCTUnwrap(body["system"] as? [[String: Any]], "the system prompt is a block so it can be cached")
        XCTAssertNotNil(system[0]["cache_control"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistantBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.map { $0["type"] as? String }, ["text", "tool_use"])
        XCTAssertEqual(assistantBlocks[1]["id"] as? String, "toolu_1")
        XCTAssertEqual((assistantBlocks[1]["input"] as? [String: Any])?["query"] as? String, "landlord")
        let resultBlocks = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(resultBlocks[0]["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlocks[0]["tool_use_id"] as? String, "toolu_1")
        let resultContent = try XCTUnwrap(resultBlocks[0]["content"] as? [[String: Any]])
        XCTAssertEqual(resultContent.map { $0["type"] as? String }, ["text", "image"], "a screenshot travels inside the tool result")
        XCTAssertNotNil(resultBlocks.last?["cache_control"], "the newest message is a cache breakpoint")
    }

    func testPromptCachingCanBeTurnedOff() async throws {
        let session = StubURLProtocol.session { _, _ in (200, Data(#"{"content":[{"type":"text","text":"done"}]}"#.utf8)) }
        let model = AnthropicModel(model: "m", apiKey: "k", promptCaching: false, session: session)
        _ = try await model.completeWithTools(CompletionRequest(messages: conversation), tools: toolSpecs)
        let raw = String(decoding: try XCTUnwrap(StubURLProtocol.sent.first).body, as: UTF8.self)
        XCTAssertFalse(raw.contains("cache_control"))
        XCTAssertTrue(json(Data(raw.utf8))["system"] is String)
    }

    func testPlainCompletionsAreNotCacheMarkedAndErrorsSurface() async throws {
        let ok = StubURLProtocol.session { _, _ in (200, Data(#"{"content":[{"type":"text","text":"hi"}]}"#.utf8)) }
        let text = try await AnthropicModel(model: "m", apiKey: "k", session: ok).complete(system: "s", user: "u")
        XCTAssertEqual(text, "hi")
        XCTAssertFalse(String(decoding: StubURLProtocol.sent[0].body, as: UTF8.self).contains("cache_control"), "one-shot calls (triage, notes) do not pay for cache writes")

        let bad = StubURLProtocol.session { _, _ in (429, Data("rate limited".utf8)) }
        do { _ = try await AnthropicModel(model: "m", apiKey: "k", session: bad).completeWithTools(CompletionRequest(messages: conversation), tools: toolSpecs); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("429")) }
    }

    // MARK: OpenAI-compatible

    func testOpenAICompatibleToolCallsRoundTrip() async throws {
        let reply = #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call_9","type":"function","function":{"name":"click","arguments":"{\"x\": 7}"}},{"id":"call_10","type":"function","function":{"name":"search_memory","arguments":"not json"}}]}}]}"#
        let session = StubURLProtocol.session { _, _ in (200, Data(reply.utf8)) }
        let model = OpenAICompatibleModel(baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen", vision: true, nativeTools: true, session: session)
        XCTAssertTrue(model.capabilities.nativeTools)
        let r = try await model.completeWithTools(CompletionRequest(messages: conversation), tools: toolSpecs)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.toolCalls.map(\.name), ["click", "search_memory"])
        XCTAssertEqual(r.toolCalls[0].arguments, ["x": 7], "arguments arrive as a JSON string and are parsed")
        XCTAssertEqual(r.toolCalls[1].arguments, [:], "malformed arguments become empty, and the tool says what is missing")

        let body = json(try XCTUnwrap(StubURLProtocol.sent.first).body)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual((tools[0]["function"] as? [String: Any])?["name"] as? String, "search_memory")
        XCTAssertNotNil((tools[0]["function"] as? [String: Any])?["parameters"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "user"], "the screenshot follows the tool message as a user message")
        let call = try XCTUnwrap((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["id"] as? String, "toolu_1")
        let arguments = try XCTUnwrap((call["function"] as? [String: Any])?["arguments"] as? String)
        XCTAssertEqual(JSONValue(jsonText: arguments), ["query": "landlord"], "arguments are sent as a JSON string")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "toolu_1")
        XCTAssertEqual(messages[3]["content"] as? String, "NOTE Home/Apartment.md")
    }

    func testNativeToolsAreOptInForOpenAICompatibleProfiles() throws {
        let off = try Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "http://localhost:11434/v1", model: "m"))
        XCTAssertFalse(off.capabilities.nativeTools, "a local model may not support tools: the text protocol is the default")
        let on = try Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "http://localhost:11434/v1", model: "m", nativeTools: true))
        XCTAssertTrue(on.capabilities.nativeTools)
        let decoded = try JSONDecoder().decode(ModelProfile.self, from: Data(#"{"provider":"apple"}"#.utf8))
        XCTAssertNil(decoded.nativeTools)
    }

    // MARK: What current models require

    func testAnthropicNeverSendsSamplingParametersAndLeavesRoomForThinking() async throws {
        // Current models (and every model on API version 2026-10-21) answer 400 to `temperature`.
        let session = StubURLProtocol.session { _, _ in (200, Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8)) }
        let model = AnthropicModel(model: "m", apiKey: "k", session: session)
        _ = try await model.complete(CompletionRequest(messages: [.system("s"), .user("u")], temperature: 0.2, maxTokens: 900))
        _ = try await model.completeWithTools(CompletionRequest(messages: conversation, temperature: 0.2, maxTokens: 900), tools: toolSpecs)
        for sent in StubURLProtocol.sent {
            let body = json(sent.body)
            XCTAssertNil(body["temperature"], "temperature must not be sent")
            XCTAssertNil(body["top_p"]); XCTAssertNil(body["top_k"])
            XCTAssertEqual(body["max_tokens"] as? Int, 4_096, "a small cap is raised: thinking counts toward it")
        }
        XCTAssertEqual(AnthropicModel.tokenLimit(8_000), 8_000, "a larger cap is left alone")
    }

    func testThinkingBlocksAreKeptAndSentBackUnchanged() async throws {
        let reply = #"{"content":[{"type":"thinking","thinking":"","signature":"SIG=="},{"type":"text","text":"Looking."},{"type":"tool_use","id":"toolu_7","name":"click","input":{"x":3}}],"stop_reason":"tool_use","usage":{"input_tokens":120,"output_tokens":30,"cache_creation_input_tokens":100,"cache_read_input_tokens":0}}"#
        let session = StubURLProtocol.session { _, _ in (200, Data(reply.utf8)) }
        let model = AnthropicModel(model: "m", apiKey: "k", session: session)
        let r = try await model.completeWithTools(CompletionRequest(messages: conversation), tools: toolSpecs)
        XCTAssertEqual(r.stopReason, "tool_use")
        XCTAssertEqual(r.usage, ModelUsage(inputTokens: 120, outputTokens: 30, cacheCreationInputTokens: 100, cacheReadInputTokens: 0))
        XCTAssertEqual(r.providerBlocks.count, 3)
        XCTAssertEqual(r.providerBlocks[0]["type"], "thinking")
        XCTAssertEqual(r.providerBlocks[0]["signature"], "SIG==")

        // The next request carries that assistant turn exactly as it came, thinking block first.
        var history = conversation
        history.append(.assistant(r.text, toolCalls: r.toolCalls, providerBlocks: r.providerBlocks))
        history.append(.toolResults([ToolResultBlock(toolCallID: "toolu_7", name: "click", text: "clicked")]))
        _ = try await model.completeWithTools(CompletionRequest(messages: history), tools: toolSpecs)
        let messages = try XCTUnwrap(json(StubURLProtocol.sent[1].body)["messages"] as? [[String: Any]])
        let replayed = try XCTUnwrap(messages[3]["content"] as? [[String: Any]])
        XCTAssertEqual(replayed.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(replayed[0]["signature"] as? String, "SIG==")
        XCTAssertEqual(replayed[2]["id"] as? String, "toolu_7")
    }

    func testRefusalAndCutOffRepliesAreReportedNotRunAsTools() async throws {
        let session = StubURLProtocol.session { _, _ in (200, Data(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#.utf8)) }
        let r = try await AnthropicModel(model: "m", apiKey: "k", session: session).completeWithTools(CompletionRequest(messages: conversation), tools: toolSpecs)
        XCTAssertEqual(r.stopReason, "refusal")
        XCTAssertTrue(r.toolCalls.isEmpty)
    }

    func testOpenAIsOwnEndpointsGetTheModernParametersAndOthersKeepTheClassicOnes() async throws {
        let ok = #"{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":40}}}"#
        func body(host: String, forced: Bool? = nil) async throws -> [String: Any] {
            let session = StubURLProtocol.session { _, _ in (200, Data(ok.utf8)) }
            let m = OpenAICompatibleModel(baseURL: URL(string: "https://\(host)/v1")!, model: "m", modernParameters: forced, session: session)
            _ = try await m.complete(CompletionRequest(messages: [.user("u")], temperature: 0.2, maxTokens: 900))
            return json(StubURLProtocol.sent[0].body)
        }
        let openai = try await body(host: "api.openai.com")
        XCTAssertEqual(openai["max_completion_tokens"] as? Int, 2_048, "reasoning counts toward the cap, so it is not left small")
        XCTAssertNil(openai["max_tokens"]); XCTAssertNil(openai["temperature"])
        let azure = try await body(host: "myres.openai.azure.com")
        XCTAssertNotNil(azure["max_completion_tokens"])
        let other = try await body(host: "openrouter.ai")
        XCTAssertEqual(other["max_tokens"] as? Int, 900)
        XCTAssertEqual(other["temperature"] as? Double, 0.2)
        XCTAssertNil(other["max_completion_tokens"])
        let forced = try await body(host: "openrouter.ai", forced: true)
        XCTAssertNotNil(forced["max_completion_tokens"], "the profile can force the modern form")
    }

    func testOpenAIStopReasonsAndCachedTokensAreNormalized() async throws {
        func reply(_ json: String) async throws -> ModelReply {
            let session = StubURLProtocol.session { _, _ in (200, Data(json.utf8)) }
            return try await OpenAICompatibleModel(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m", nativeTools: true, session: session)
                .completeWithTools(CompletionRequest(messages: conversation), tools: toolSpecs)
        }
        let a = try await reply(#"{"choices":[{"message":{"content":"x"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":8}}}"#)
        XCTAssertEqual(a.stopReason, "max_tokens")
        XCTAssertEqual(a.usage, ModelUsage(inputTokens: 10, outputTokens: 2, cacheReadInputTokens: 8))
        let b = try await reply(#"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(b.stopReason, "refusal")
        let c = try await reply(#"{"choices":[{"message":{"content":"","tool_calls":[{"id":"1","type":"function","function":{"name":"click","arguments":"{\"x\":1}"}}]},"finish_reason":"tool_calls"}]}"#)
        XCTAssertEqual(c.stopReason, "tool_use")
        XCTAssertEqual(c.toolCalls.count, 1)
    }

    func testRedactionLeavesSignedThinkingAloneButScrubsTheRest() async throws {
        let inner = NativeMockModel([ModelReply(text: "ok")])
        let blocks: [JSONValue] = [
            ["type": "thinking", "thinking": "", "signature": "SIG=="],
            ["type": "text", "text": "paying with 4111 1111 1111 1111"],
            ["type": "tool_use", "id": "1", "name": "type", "input": ["text": "4111 1111 1111 1111"]],
        ]
        let messages: [ChatMessage] = [.system("s"), .user("t"), .assistant("x", toolCalls: [], providerBlocks: blocks)]
        _ = try await RedactingModel(inner).completeWithTools(CompletionRequest(messages: messages), tools: [])
        let seen = inner.requests[0].request.messages[2].providerBlocks
        XCTAssertEqual(seen[0], blocks[0], "the signed block is untouched")
        XCTAssertFalse("\(seen)".contains("4111"))
        XCTAssertTrue("\(seen[1])".contains("[REDACTED:card]"))
    }

    // MARK: Redaction on the way out

    func testHostedToolConversationsAreRedactedIncludingResultsAndArguments() async throws {
        let inner = NativeMockModel([ModelReply(text: "ok")])
        let hosted = RedactingModel(inner)
        let messages: [ChatMessage] = [
            .system("s"), .user("THE TASK: pay with 4111 1111 1111 1111"),
            .assistant("typing", toolCalls: [ModelToolCall(id: "1", name: "type", arguments: ["text": "card 4111 1111 1111 1111"])]),
            .toolResults([ToolResultBlock(toolCallID: "1", name: "type", text: "typed; the page shows card 4111 1111 1111 1111")]),
        ]
        _ = try await hosted.completeWithTools(CompletionRequest(messages: messages), tools: [])
        let seen = inner.requests[0].request.messages
        XCTAssertFalse("\(seen)".contains("4111"), "\(seen)")
        XCTAssertTrue(seen[3].toolResults[0].text.contains("[REDACTED:card]"))
        XCTAssertEqual(seen[2].toolCalls[0].arguments["text"], "card [REDACTED:card]")
        XCTAssertTrue(hosted.capabilities.nativeTools, "capabilities are forwarded unchanged")
    }
}
