import Foundation
@testable import OffloadCore

enum T {
    static func store() throws -> KnowledgeStore { try KnowledgeStore(db: Database.inMemory()) }

    static func item(
        _ id: String, kind: SourceKind = .file, title: String = "", date: Date? = nil,
        trust: Trust = .saved, verdict: Verdict = .survivor, fingerprint: String = "fp"
    ) -> ItemRecord {
        ItemRecord(
            id: id, bucket: "test", kind: kind, uri: "/tmp/\(id).txt", title: title.isEmpty ? id : title,
            itemDate: date, fingerprint: fingerprint, summary: "summary of \(id)", verdict: verdict, trust: trust)
    }

    /// Stores each (id, text) as a survivor item with indexed chunks.
    @discardableResult
    static func ingest(_ docs: [(String, String)], into store: KnowledgeStore, embedder: Embedder?) async throws -> Indexer {
        let indexer = Indexer(store: store, embedder: embedder)
        for (id, text) in docs {
            try store.upsertItem(item(id))
            try await indexer.indexDocument(itemID: id, text: text)
        }
        return indexer
    }
}
