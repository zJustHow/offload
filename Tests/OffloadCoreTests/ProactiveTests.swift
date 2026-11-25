import XCTest
@testable import OffloadCore

final class ProactiveTests: XCTestCase {
    var base: URL!
    var store: KnowledgeStore!
    var memory: MemoryService!
    let now = Date()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-pro-\(UUID().uuidString)")
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        store = try T.store()
        let notes = ["README.md": "# About\nA founder.", "Work/Acme.md": "# Acme\nTerm sheet from Orion Capital sent; waiting on the liquidation preference review by legal.\n"]
        let staging = try ws.makeStaging()
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)
        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        for (p, b) in notes { try await indexer.indexNote(path: p, body: b) }
        func item(_ id: String, _ kind: SourceKind, _ title: String, _ summary: String, daysAgo: Double) throws {
            try store.upsertItem(ItemRecord(id: id, bucket: "b", kind: kind, uri: id, title: title, itemDate: now.addingTimeInterval(-daysAgo * 86_400), fingerprint: id, summary: summary, verdict: .survivor, trust: .correspondence))
        }
        try item("m1", .mail, "Orion follow-up", "Orion Capital asked the user to confirm the term sheet by Friday.", daysAgo: 1)
        try item("old", .mail, "Ancient mail", "Something from last year.", daysAgo: 400)
        try item("cal", .calendar, "Board call", "Board call scheduled next week.", daysAgo: -5)
        memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func model(judge: String, prepare: @escaping @Sendable (String) -> String, prompts: Box<[String]>? = nil) -> MockModel {
        MockModel(contextChars: 40_000) { req in
            let sys = req.messages.first!.text, user = req.messages.last!.text
            prompts?.mutate { $0.append(user) }
            return sys.contains("decide what a personal assistant") ? judge : prepare(user)
        }
    }

    func testJudgeThenGroundedPreparationProducesReviewableCards() async throws {
        let prompts = Box<[String]>([])
        let m = model(
            judge: ##"{"candidates":[{"kind":"reply","title":"Confirm term sheet with Orion","why":"Orion asked for confirmation by Friday.","query":"Orion term sheet"},{"kind":"research","title":"Stale thing","why":"x","query":"nothing"}]}"##,
            prepare: { user in
                user.contains("Stale thing")
                    ? ##"{"verdict":"stale","prepared_content":"x","confidence":"high","sources":[1]}"##
                    : ##"{"verdict":"confirmed","prepared_content":"Hi, confirming the term sheet. Legal is reviewing the liquidation preference; I will revert by [confirm date].","confidence":"high","sources":[1]}"##
            }, prompts: prompts)
        let cards = try await ProactivePlanner(store: store, memory: memory, model: m).run(now: now)

        XCTAssertEqual(cards.count, 1, "the stale candidate is dropped")
        let c = cards[0]
        XCTAssertEqual(c.kind, .reply)
        XCTAssertEqual(c.status, "ready")
        XCTAssertTrue(c.preparedContent.contains("[confirm date]"), "missing details stay placeholders")
        XCTAssertEqual(c.confidence, .high)
        XCTAssertEqual(c.sources, ["Work/Acme.md"], "sources are the evidence it was grounded in")
        XCTAssertEqual(try store.cards().map(\.title), ["Confirm term sheet with Orion"])

        let judgeInput = prompts.value[0]
        XCTAssertTrue(judgeInput.contains("Orion follow-up") && judgeInput.contains("Board call"))
        XCTAssertFalse(judgeInput.contains("Ancient mail"), "only recent and upcoming items go to the judge")
        XCTAssertTrue(prompts.value[1].contains("liquidation preference"), "preparation sees retrieved evidence, not just summaries")
    }

    func testUngroundedOrUnverifiedCardsAreNeverConfident() async throws {
        let m = model(
            judge: ##"{"candidates":[{"kind":"booking","title":"Book flights","why":"A trip seems planned.","query":"flights zzzz"}]}"##,
            prepare: { _ in ##"{"verdict":"unverified","prepared_content":"1. Pick dates [confirm date]\n2. Compare fares","confidence":"high","sources":[]}"## })
        let cards = try await ProactivePlanner(store: store, memory: memory, model: m).run(now: now)
        XCTAssertEqual(cards.first?.confidence, .low, "an unverified card cannot claim high confidence")
        XCTAssertEqual(cards.first?.sources, [])
    }

    func testDeckReplacementKeepsDismissedCardsAndHandlesGarbage() async throws {
        let m1 = model(judge: ##"{"candidates":[{"kind":"reminder","title":"First","why":"w","query":"Orion"}]}"##, prepare: { _ in ##"{"verdict":"confirmed","prepared_content":"do it","confidence":"medium","sources":[1]}"## })
        let first = try await ProactivePlanner(store: store, memory: memory, model: m1).run(now: now)
        try store.setCardStatus(id: first[0].id, status: "dismissed")
        let m2 = model(judge: ##"{"candidates":[{"kind":"reminder","title":"Second","why":"w","query":"Orion"}]}"##, prepare: { _ in ##"{"verdict":"confirmed","prepared_content":"do that","confidence":"medium","sources":[1]}"## })
        _ = try await ProactivePlanner(store: store, memory: memory, model: m2).run(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(try store.cards().map(\.title), ["Second"], "yesterday's ready cards are replaced")
        XCTAssertEqual(try store.cards(status: "dismissed").map(\.title), ["First"], "dismissals are remembered")

        let broken = model(judge: "I have no suggestions today!", prepare: { _ in "" })
        let none = try await ProactivePlanner(store: store, memory: memory, model: broken).run(now: now)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(try store.cards().isEmpty, "an empty judgment clears the old deck instead of leaving stale cards")
    }

    func testNothingRecentMeansNoModelCalls() async throws {
        let empty = try T.store()
        let calls = Box<[String]>([])
        let m = MockModel { req in calls.append("call"); return "{}" }
        let ws = VaultWorkspace(root: base.appendingPathComponent("empty-vault"))
        let mem = MemoryService(store: empty, searcher: HybridSearcher(store: empty, embedder: nil), workspace: ws)
        let cards = try await ProactivePlanner(store: empty, memory: mem, model: m).run(now: now)
        XCTAssertTrue(cards.isEmpty)
        XCTAssertTrue(calls.value.isEmpty)
    }
}
