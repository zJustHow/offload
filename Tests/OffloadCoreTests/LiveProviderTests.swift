import XCTest
@testable import OffloadCore

/// Calls the real Anthropic and OpenAI-compatible APIs. These spend a few cents at most and need your own
/// key, so they are skipped unless asked for:
///
///     ANTHROPIC_API_KEY=sk-ant-... OFFLOAD_LIVE_ANTHROPIC=1 swift test --filter LiveProviderTests/testAnthropic
///     OPENAI_API_KEY=sk-... OFFLOAD_LIVE_OPENAI=1 OFFLOAD_LIVE_OPENAI_MODEL=<model> swift test --filter LiveProviderTests/testOpenAI
///
/// Optional: `OFFLOAD_LIVE_ANTHROPIC_MODEL` (default `claude-haiku-5-5`, the cheapest current model),
/// `OPENAI_BASE_URL` (default `https://api.openai.com/v1`; point it at Ollama or LM Studio to test a local
/// model, then no key is needed). Each test prints the token usage of every step, so cache hits can be read.
final class LiveProviderTests: XCTestCase {
    var base: URL!
    var memory: MemoryService!
    let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-liveprov-\(UUID().uuidString)")
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        let store = try T.store()
        let staging = try ws.makeStaging()
        let notes = ["README.md": "# About\nA founder.", "Home/Apartment.md": "# Apartment\nLandlord is Mr. Alvarez; rent $3,400.\n"]
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)
        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        for (p, b) in notes { try await indexer.indexNote(path: p, body: b) }
        memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    /// Long enough to be cacheable on any model (the minimum is up to 4,096 tokens), and identical on every call.
    static let longSystemPrompt: String = {
        let paragraph = "You are a careful assistant. Look things up with the tools you are given, never invent facts, and answer in one short sentence. "
        return "Reference notes follow; they are background only.\n" + (0..<260).map { "Note \($0): " + paragraph }.joined(separator: "\n")
    }()

    let lookup = ToolSpec(
        name: "lookup_code", description: "Returns the reference code for a named item.",
        inputSchema: JSONSchema.object(["item": JSONSchema.string("the item name")], required: ["item"]))

    /// Runs the loop a provider needs: send, run the tools it asks for, send the results, until it answers.
    func runToolLoop(_ model: LanguageModel, system: String, question: String) async throws -> (answer: String, usages: [ModelUsage]) {
        var messages: [ChatMessage] = [.system(system), .user(question)]
        var usages: [ModelUsage] = []
        for step in 1...5 {
            let reply = try await model.completeWithTools(CompletionRequest(messages: messages, maxTokens: 4_096), tools: [lookup])
            if let u = reply.usage { usages.append(u); print("step \(step): \(u) stop=\(reply.stopReason ?? "?")") }
            XCTAssertNotEqual(reply.stopReason, "max_tokens", "the reply was cut off")
            if reply.toolCalls.isEmpty { return (reply.text, usages) }
            messages.append(.assistant(reply.text, toolCalls: reply.toolCalls, providerBlocks: reply.providerBlocks))
            messages.append(.toolResults(reply.toolCalls.map { call in
                ToolResultBlock(toolCallID: call.id, name: call.name, text: call.name == "lookup_code" ? "The reference code for \(call.arguments.string("item") ?? "?") is ZX-4417." : "unknown tool", isError: call.name != "lookup_code")
            }))
        }
        XCTFail("the model never answered")
        return ("", usages)
    }

    // MARK: Anthropic

    func testAnthropic() async throws {
        try XCTSkipUnless(env["OFFLOAD_LIVE_ANTHROPIC"] == "1", "set OFFLOAD_LIVE_ANTHROPIC=1 and ANTHROPIC_API_KEY to run")
        let key = try XCTUnwrap(env["ANTHROPIC_API_KEY"], "ANTHROPIC_API_KEY is not set")
        let model = AnthropicModel(model: env["OFFLOAD_LIVE_ANTHROPIC_MODEL"] ?? "claude-haiku-5-5", apiKey: key)

        // 1. A plain call: before the fix, the temperature every caller sent made current models answer 400.
        let pong = try await model.complete(system: "Reply with exactly one word.", user: "Say hello.")
        XCTAssertFalse(pong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // 2 and 3. A tool round trip (thinking blocks replayed unchanged) over a prefix big enough to be cached.
        let (answer, usages) = try await runToolLoop(model, system: Self.longSystemPrompt, question: "What is the reference code for the item 'invoice'? Use the tool.")
        XCTAssertTrue(answer.contains("ZX-4417"), answer)
        XCTAssertGreaterThanOrEqual(usages.count, 2)
        XCTAssertTrue(usages.contains { $0.cacheCreationInputTokens > 0 } || usages.contains { $0.cacheReadInputTokens > 0 }, "no cache activity at all: \(usages)")
        XCTAssertTrue(usages.dropFirst().contains { $0.cacheReadInputTokens > 0 }, "the second step should read what the first wrote: \(usages)")
    }

    func testAnthropicDrivesTheWholeAgent() async throws {
        try XCTSkipUnless(env["OFFLOAD_LIVE_ANTHROPIC"] == "1", "set OFFLOAD_LIVE_ANTHROPIC=1 and ANTHROPIC_API_KEY to run")
        let key = try XCTUnwrap(env["ANTHROPIC_API_KEY"], "ANTHROPIC_API_KEY is not set")
        let model = AnthropicModel(model: env["OFFLOAD_LIVE_ANTHROPIC_MODEL"] ?? "claude-haiku-5-5", apiKey: key)
        XCTAssertTrue(model.capabilities.nativeTools)
        let result = await Agent(model: model, memory: memory, computer: nil, confirm: { _ in true }).run(task: "Who is my landlord? Check my notes, then answer in one sentence.", maxSteps: 8)
        print("agent result:", result)
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.summary.contains("Alvarez"), result.summary)
    }

    // MARK: OpenAI and OpenAI-compatible servers

    func testOpenAI() async throws {
        try XCTSkipUnless(env["OFFLOAD_LIVE_OPENAI"] == "1", "set OFFLOAD_LIVE_OPENAI=1 and OFFLOAD_LIVE_OPENAI_MODEL (and OPENAI_API_KEY) to run")
        let modelName = try XCTUnwrap(env["OFFLOAD_LIVE_OPENAI_MODEL"], "OFFLOAD_LIVE_OPENAI_MODEL is not set")
        let base = URL(string: env["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1")!
        let model = OpenAICompatibleModel(baseURL: base, model: modelName, apiKey: env["OPENAI_API_KEY"], nativeTools: true)

        let pong = try await model.complete(system: "Reply with exactly one word.", user: "Say hello.")
        XCTAssertFalse(pong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let (answer, usages) = try await runToolLoop(model, system: Self.longSystemPrompt, question: "What is the reference code for the item 'invoice'? Use the tool.")
        XCTAssertTrue(answer.contains("ZX-4417"), answer)
        print("openai usage per step (cacheRead is best-effort there):", usages)
    }
}
