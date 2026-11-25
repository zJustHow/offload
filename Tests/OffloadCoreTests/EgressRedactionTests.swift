import XCTest
@testable import OffloadCore

/// Everything sent to a hosted model or a remote embedder passes through `PIIScan.redact`,
/// including the paths that never touch the index (triage input, notes, live screen text).
final class EgressRedactionTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("offload-egress-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    // MARK: The wrapper itself

    func testHostedModelSeesRedactedTextAndEverythingElseIsForwarded() async throws {
        let mock = MockModel(vision: true, isLocal: false) { _ in "ok" }
        let model = RedactingModel(mock)
        let image = Data([1, 2, 3])
        let reply = try await model.complete(CompletionRequest(
            messages: [.system("Never repeat 123-45-6789"), .user("card 4111 1111 1111 1111, passport E12345678", images: [image])],
            temperature: 0.3, maxTokens: 50, jsonMode: true))
        XCTAssertEqual(reply, "ok")

        let seen = try XCTUnwrap(mock.requests.first)
        let sent = seen.messages.map(\.text).joined(separator: "\n")
        XCTAssertFalse(sent.contains("4111"))
        XCTAssertFalse(sent.contains("123-45-6789"))
        XCTAssertFalse(sent.contains("E12345678"))
        XCTAssertTrue(sent.contains("[REDACTED:card]") && sent.contains("[REDACTED:ssn]") && sent.contains("[REDACTED:passport]"))
        XCTAssertEqual(seen.messages.map(\.role), [.system, .user])
        XCTAssertEqual(seen.messages[1].images, [image], "images are passed through untouched: regex cannot scan them")
        XCTAssertEqual(seen.temperature, 0.3); XCTAssertEqual(seen.maxTokens, 50); XCTAssertTrue(seen.jsonMode)
        XCTAssertEqual(model.name, "mock", "callers compare model names")
        XCTAssertFalse(model.capabilities.isLocal)
        XCTAssertEqual(model.capabilities.contextChars, mock.capabilities.contextChars)
    }

    func testRedactionIsIdempotentSoDoubleWrappingIsHarmless() {
        let text = "SSN 123-45-6789, card 4111 1111 1111 1111, id 11010519491231002X, passport E12345678, "
            + "key sk-abcdefghijklmnopqrstuvwxyz123456, account 12345678901, password: hunter2xyz."
        let once = PIIScan.redact(text).text
        XCTAssertNotEqual(once, text)
        XCTAssertEqual(PIIScan.redact(once).text, once)
        XCTAssertTrue(PIIScan.findings(in: once).isEmpty, "\(once)")
    }

    func testRedactingTwiceDoesNotEatTextThatFollowsAPlaceholder() {
        // "[REDACTED:account]" contains the keyword "account": a second pass must not treat the
        // placeholder as a label and redact the date that follows it.
        let text = "Account 12345678901 opened 2024-03-15 10:30, passport E12345678 expires 2031-01-01."
        let once = PIIScan.redact(text).text
        XCTAssertTrue(once.contains("2024-03-15 10:30") && once.contains("2031-01-01"), once)
        XCTAssertEqual(PIIScan.redact(once).text, once)
    }

    func testFixedPromptScaffoldingSurvivesRedaction() {
        // The wrapper rewrites whole prompts, so none of our own instructions may trip a rule.
        XCTAssertEqual(PIIScan.redact(Triager.systemPrompt).text, Triager.systemPrompt)
        XCTAssertEqual(PIIScan.redact(VaultBuilder.mergeSystemPrompt).text, VaultBuilder.mergeSystemPrompt)

        let triage = Triager.prompt(
            for: TriageInput(kind: .mail, trust: .correspondence, title: "Re: lease", location: "mail://1", date: Date(timeIntervalSince1970: 1_700_000_000), text: "Hello"),
            budget: 5_000)
        XCTAssertEqual(PIIScan.redact(triage).text, triage)

        let item = ItemRecord(id: "i", bucket: "b", kind: .file, uri: "/a.md", title: "Lease", itemDate: Date(timeIntervalSince1970: 1_700_000_000), fingerprint: "1", summary: "The user rents an apartment.", verdict: .survivor, trust: .authored)
        let evidence = VaultBuilder.render(item, number: 3)
        XCTAssertEqual(PIIScan.redact(evidence).text, evidence)
    }

    // MARK: Paths that never touch the index

    func testTriageInputIsRedactedBeforeItReachesAHostedModel() async throws {
        let mock = MockModel(isLocal: false) { _ in
            #"{"summary":"The user keeps a record of a payment.","title":"Payment","junk":false,"sensitive":false}"#
        }
        let triager = Triager(model: RedactingModel(mock))
        let outcome = await triager.triage(TriageInput(
            kind: .note, trust: .authored, title: "Receipt", location: "/n.md", date: nil,
            text: "Paid with card 4111 1111 1111 1111 on the 3rd, reference LD-55821, thanks."))
        XCTAssertEqual(outcome.verdict, .survivor)

        let prompt = try XCTUnwrap(mock.requests.first?.messages.last?.text)
        XCTAssertFalse(prompt.contains("4111 1111 1111 1111"), "the raw item used to reach triage unscanned")
        XCTAssertTrue(prompt.contains("[REDACTED:card]"))
        XCTAssertTrue(prompt.contains("LD-55821"), "ordinary references are not over-redacted")
    }

    func testEmbedderGetsRedactedTextAndKeepsItsName() async throws {
        let inner = RecordingEmbedder()
        let embedder = RedactingEmbedder(inner)
        let vectors = try await embedder.embed(["note: card 4111 1111 1111 1111", "plain text"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(inner.seen, ["note: card [REDACTED:card]", "plain text"])
        XCTAssertEqual(embedder.name, "recording")
    }

    // MARK: Wiring

    func testRuntimeWrapsHostedModelsAndLeavesLocalOnesAlone() async throws {
        var cfg = OffloadConfig()
        cfg.embedding = EmbeddingProfile(kind: .hashing)
        let hosted = MockModel(name: "hosted", isLocal: false) { _ in "ok" }
        let local = MockModel(name: "local", isLocal: true) { _ in "ok" }
        let rt = try Runtime(paths: AppPaths(support: home), config: cfg, models: (hosted, local, hosted))

        let text = "card 4111 1111 1111 1111"
        _ = try await rt.triageModel.complete(system: "s", user: text)
        _ = try await rt.assistantModel.complete(system: "s", user: text)
        _ = try await rt.knowledgeModel.complete(system: "s", user: text)

        XCTAssertEqual(hosted.requests.map { $0.messages.last?.text }, ["card [REDACTED:card]", "card [REDACTED:card]"])
        XCTAssertEqual(local.requests.first?.messages.last?.text, text, "a model on this Mac is not restricted")
        XCTAssertTrue(rt.triageModel is RedactingModel)
        XCTAssertFalse(rt.knowledgeModel is RedactingModel)
        XCTAssertEqual(rt.triageModel.name, "hosted")
    }

    func testFactoriesWrapRemoteEndpointsOnly() throws {
        let remote = try Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "https://api.openai.com/v1", model: "gpt"))
        let local = try Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "http://localhost:11434/v1", model: "qwen"))
        XCTAssertTrue(remote is RedactingModel)
        XCTAssertFalse(local is RedactingModel)
        XCTAssertEqual(remote.name, "openai-compat:gpt")

        let remoteEmbedder = try Runtime.makeEmbedder(EmbeddingProfile(kind: .openaiCompatible, baseURL: "https://api.openai.com/v1", model: "text-embedding-3-small"))
        let localEmbedder = try Runtime.makeEmbedder(EmbeddingProfile(kind: .openaiCompatible, baseURL: "http://127.0.0.1:11434/v1", model: "bge-m3"))
        XCTAssertTrue(remoteEmbedder is RedactingEmbedder)
        XCTAssertFalse(localEmbedder is RedactingEmbedder)
        XCTAssertTrue(try Runtime.makeEmbedder(EmbeddingProfile(kind: .hashing)) is HashingEmbedder)
    }

    func testWrappingTwiceDoesNotNest() {
        let wrapped = MockModel(isLocal: false) { _ in "" }.redactingIfHosted()
        XCTAssertTrue(wrapped is RedactingModel)
        XCTAssertTrue(wrapped.redactingIfHosted() is RedactingModel)
        XCTAssertNil((wrapped.redactingIfHosted() as? RedactingModel)?.inner as? RedactingModel)
    }
}

private final class RecordingEmbedder: Embedder, @unchecked Sendable {
    let name = "recording"
    private let lock = NSLock()
    private var _seen: [String] = []
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return _seen }

    private func record(_ texts: [String]) { lock.lock(); _seen += texts; lock.unlock() }

    func embed(_ texts: [String]) async throws -> [EmbeddedVector?] {
        record(texts)
        return texts.map { _ in EmbeddedVector(space: "recording", values: [1, 0]) }
    }
}
