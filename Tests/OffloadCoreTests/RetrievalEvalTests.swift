import XCTest
@testable import OffloadCore

final class RetrievalEvalTests: XCTestCase {
    func testCompareConfigurations() async throws {
        let apple = AppleSentenceEmbedder()
        let ctx = AppleContextualEmbedder()
        let hash = HashingEmbedder()
        let configs: [RetrievalEval.Config] = [
            .init(label: "lexical (no bigrams)", embedder: nil, mode: .lexicalOnly, bigrams: false),
            .init(label: "lexical (+CJK bigrams)", embedder: nil, mode: .lexicalOnly),
            .init(label: "exact (trigram) only", embedder: nil, mode: .exactOnly),
            .init(label: "vector: hashing", embedder: hash, mode: .vectorOnly),
            .init(label: "vector: apple sentence", embedder: apple, mode: .vectorOnly),
            .init(label: "vector: apple contextual", embedder: ctx, mode: .vectorOnly),
            .init(label: "HYBRID: hashing", embedder: hash, mode: .hybrid),
            .init(label: "HYBRID: apple sentence", embedder: apple, mode: .hybrid),
            .init(label: "HYBRID: apple contextual", embedder: ctx, mode: .hybrid),
        ]
        let rows = try await RetrievalEval().run(configs: configs)
        print("\n===== RETRIEVAL EVAL (synthetic corpus: \(EvalCorpus.docs.count) docs, \(EvalCorpus.queries.count) queries) =====\n" + RetrievalEval.format(rows) + "=====\n")
        XCTAssertEqual(rows.count, configs.count)

        func row(_ label: String) -> RetrievalEval.Row { rows.first { $0.label == label }! }
        let lexical = row("lexical (+CJK bigrams)")
        let vector = row("vector: apple contextual")
        let hybrid = row("HYBRID: apple contextual")
        try XCTSkipIf(vector.overall.recallAt5 == 0, "Apple contextual embedding assets are unavailable on this machine")

        // The point of hybrid retrieval, as invariants rather than magic numbers:
        XCTAssertGreaterThanOrEqual(hybrid.overall.mrr, lexical.overall.mrr, "hybrid must not rank worse than lexical alone")
        XCTAssertGreaterThanOrEqual(hybrid.overall.mrr, vector.overall.mrr, "hybrid must not rank worse than vectors alone")
        XCTAssertGreaterThan(hybrid.overall.recallAt5, lexical.overall.recallAt5, "vectors must recover answers BM25 misses")
        XCTAssertGreaterThan(hybrid.byCategory[.paraphrase]!.mrr, lexical.byCategory[.paraphrase]!.mrr)
        // ...without giving up what lexical retrieval is good at:
        XCTAssertGreaterThanOrEqual(hybrid.byCategory[.identifier]!.recallAt3, 1.0)
        XCTAssertGreaterThanOrEqual(hybrid.byCategory[.keyword]!.recallAt3, 1.0)
    }
}
