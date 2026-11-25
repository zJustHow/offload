import XCTest
@testable import OffloadCore

final class IngestTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Verdicts keyed off markers in the item text, so tests control what the "model" says.
    func mockModel() -> MockModel {
        MockModel { req in
            let prompt = req.messages.last?.text ?? ""
            if prompt.contains("JUNKME") { return #"{"summary":"","title":"x","junk":true,"sensitive":false}"# }
            if prompt.contains("MEDICALRECORD") { return #"{"summary":"","title":"x","junk":false,"sensitive":true}"# }
            return #"{"summary":"The user keeps notes about their rental and travel plans.","title":"Rental notes","junk":false,"sensitive":false}"#
        }
    }

    func makePipeline(_ model: LanguageModel, store: KnowledgeStore) -> IngestPipeline {
        IngestPipeline(store: store, triager: Triager(model: model), indexer: Indexer(store: store, embedder: HashingEmbedder()))
    }

    func testEndToEndVerdictsRedactionAndIndexing() async throws {
        try write("notes/lease.md", "# Lease\nDeposit is two months. Pay with card 4111 1111 1111 1111 and SSN 123-45-6789 on file. Landlord Alvarez.")
        try write("promo.txt", "JUNKME huge sale this weekend only, fifty percent off everything in the store")
        try write("health.txt", "MEDICALRECORD lab results and diagnosis details for the patient, confidential")
        try write("ignored.bin", "binary-ish content that has an unsupported extension entirely")
        let store = try T.store()
        let model = mockModel()
        let report = try await makePipeline(model, store: store).run(connectors: [FilesConnector(root: dir)])

        XCTAssertEqual(report.listed, 3, "unsupported extensions are not even listed")
        XCTAssertEqual(report.survivors, 1)
        XCTAssertEqual(report.junk, 1)
        XCTAssertEqual(report.sensitive, 1)

        let items = try store.items(bucket: FilesConnector(root: dir).bucket)
        XCTAssertEqual(Set(items.map(\.verdict)), [.survivor, .junk, .sensitive])
        let survivor = items.first { $0.verdict == .survivor }!
        XCTAssertEqual(survivor.trust, .authored, ".md is the user's own writing")
        XCTAssertNotNil(survivor.summary)
        XCTAssertNil(items.first { $0.verdict == .sensitive }!.summary)

        // Raw text: kept for retrieval, but identifiers are scrubbed before they touch the index.
        let chunks = try store.chunks(itemID: survivor.id)
        XCTAssertFalse(chunks.isEmpty)
        let joined = chunks.map(\.text).joined()
        XCTAssertTrue(joined.contains("Alvarez"))
        XCTAssertFalse(joined.contains("4111"))
        XCTAssertFalse(joined.contains("123-45-6789"))
        XCTAssertTrue(joined.contains("[REDACTED:card]"))
        // Junk and sensitive items leave no searchable text behind.
        XCTAssertEqual(try store.counts()["chunks"], chunks.count)
        XCTAssertEqual(try store.counts()["vectors"], chunks.count)
    }

    func testRerunSkipsUnchangedAndReprocessesEditsAndDeletions() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        try write("b.md", "Bravo note with enough text to pass the empty check easily.")
        let store = try T.store()
        let model = mockModel()
        let pipeline = makePipeline(model, store: store)
        let connector = FilesConnector(root: dir)

        _ = try await pipeline.run(connectors: [connector])
        XCTAssertEqual(model.requests.count, 2)

        let second = try await pipeline.run(connectors: [connector])
        XCTAssertEqual(second.skippedUpToDate, 2)
        XCTAssertEqual(model.requests.count, 2, "unchanged files must not be sent to the model again")

        // Edit one file (different size => different fingerprint) and delete the other.
        try write("a.md", "Alpha note, now edited and quite a bit longer than before so the size differs.")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.md"))
        let third = try await pipeline.run(connectors: [connector])
        XCTAssertEqual(third.deleted, 1)
        XCTAssertEqual(third.survivors, 1)
        XCTAssertEqual(model.requests.count, 3)
        XCTAssertEqual(try store.items(bucket: connector.bucket).count, 1)
        XCTAssertEqual(try store.counts()["chunks"], 1, "the deleted file's chunks must be gone")
    }

    func testUnreadableSourceDoesNotDeleteWhatWasLearned() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        let store = try T.store()
        let pipeline = makePipeline(mockModel(), store: store)
        _ = try await pipeline.run(connectors: [FilesConnector(root: dir)])
        // The folder disappears (unmounted drive, revoked permission): that is an error, not "empty".
        let gone = dir.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.md"), to: dir.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString).md"))
        struct Broken: Connector {
            let bucket: String; let kind = SourceKind.file; let listsAllItems = true
            func list() async throws -> [WorkItemRef] { throw ConnectorError.permissionDenied("Full Disk Access revoked") }
            func load(_ ref: WorkItemRef) async throws -> ItemContent { fatalError() }
        }
        let report = try await pipeline.run(connectors: [Broken(bucket: FilesConnector(root: dir).bucket)])
        XCTAssertNotNil(report.sourceErrors.values.first)
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(try store.items(bucket: FilesConnector(root: dir).bucket).count, 1)
        _ = gone
    }

    func testModelFailuresAreRetriedNotRemembered() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        let store = try T.store()
        struct Down: Error {}
        let flaky = FlakyModel(failFirst: 1)
        let pipeline = makePipeline(flaky, store: store)
        let connector = FilesConnector(root: dir)

        let first = try await pipeline.run(connectors: [connector])
        XCTAssertEqual(first.failed, 1)
        XCTAssertEqual(first.survivors, 0)
        let second = try await pipeline.run(connectors: [connector])
        XCTAssertEqual(second.survivors, 1, "a failed item must be picked up again on the next run")
    }

    func testPerSourceBudgetStopsAndResumes() async throws {
        for i in 0..<5 { try write("n\(i).md", "Note number \(i) with enough text to pass the empty check easily.") }
        let store = try T.store()
        let pipeline = makePipeline(mockModel(), store: store)
        let connector = FilesConnector(root: dir)
        let partial = try await pipeline.run(connectors: [connector], maxItemsPerSource: 2)
        XCTAssertEqual(partial.survivors, 2)
        let rest = try await pipeline.run(connectors: [connector])
        XCTAssertEqual(rest.survivors, 3)
        XCTAssertEqual(rest.skippedUpToDate, 2)
    }

    func testHTMLAndEncodingHelpers() throws {
        let html = "<html><style>p{}</style><body><p>Hello&nbsp;<b>World</b></p><script>evil()</script></body></html>"
        let text = HTMLText.strip(html)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("World"))
        XCTAssertFalse(text.contains("evil"))
        XCTAssertFalse(text.contains("<"))
    }
}

final class FlakyModel: LanguageModel, @unchecked Sendable {
    let name = "flaky"
    let capabilities = ModelCapabilities(contextChars: 50_000, isLocal: true)
    private var remainingFailures: Int
    private let lock = NSLock()
    init(failFirst: Int) { remainingFailures = failFirst }
    private func shouldFail() -> Bool { lock.lock(); defer { lock.unlock() }; if remainingFailures > 0 { remainingFailures -= 1; return true }; return false }
    func complete(_ request: CompletionRequest) async throws -> String {
        if shouldFail() { throw LLMError.unavailable("down") }
        return #"{"summary":"The user keeps notes.","title":"Notes","junk":false,"sensitive":false}"#
    }
}
