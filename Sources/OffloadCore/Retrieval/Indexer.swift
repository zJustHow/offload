import Foundation

/// Writes retrievable content: splits text into chunks, stores them (which also updates the
/// lexical indexes through triggers) and computes vectors. Embedding failures never lose chunks:
/// they simply stay "pending" and `embedPending` retries them later (for example overnight).
public final class Indexer: @unchecked Sendable {
    public let store: KnowledgeStore
    public let embedder: Embedder?
    public var chunker: Chunker

    /// Stored for a text the embedder cannot handle, so it is not retried forever.
    static let noVectorSpace = "none"

    public init(store: KnowledgeStore, embedder: Embedder?, chunker: Chunker = Chunker()) {
        self.store = store
        self.embedder = embedder
        self.chunker = chunker
    }

    /// Replaces the item's chunks with chunks of `text` and embeds them. Returns the chunk ids.
    @discardableResult
    public func indexDocument(itemID: String, text: String) async throws -> [Int64] {
        try await indexChunks(itemID: itemID, texts: chunker.chunk(document: text).map(\.text))
    }

    @discardableResult
    public func indexChunks(itemID: String, texts: [String]) async throws -> [Int64] {
        let ids = try store.replaceChunks(itemID: itemID, texts: texts)
        // Embedding is best-effort here; whatever fails is picked up by `embedPending`.
        _ = try? await embed(ids: ids, texts: texts)
        return ids
    }

    /// Embeds every chunk and note that has no vector yet. Returns how many vectors were stored.
    @discardableResult
    public func embedPending(batchSize: Int = 64, maxBatches: Int = .max) async throws -> Int {
        guard embedder != nil else { return 0 }
        var stored = 0
        var batches = 0
        while batches < maxBatches {
            let pending = try store.chunksNeedingVectors(limit: batchSize)
            if pending.isEmpty { break }
            stored += try await embed(ids: pending.map(\.id), texts: pending.map(\.text))
            batches += 1
        }
        for note in try store.notesNeedingVectors() {
            if let v = try await embedder?.embed([note.title + "\n" + String(note.body.prefix(4000))]).first ?? nil {
                try store.saveNoteVector(path: note.path, vector: v)
                stored += 1
            } else {
                try store.saveNoteVector(path: note.path, vector: EmbeddedVector(space: Self.noVectorSpace, values: []))
            }
        }
        return stored
    }

    /// Embeds already-stored chunks. Safe to call repeatedly; failures leave them pending.
    @discardableResult
    public func embed(ids: [Int64], texts: [String]) async throws -> Int {
        guard let embedder, !ids.isEmpty else { return 0 }
        let vectors = try await embedder.embed(texts)
        var pairs: [(chunkID: Int64, vector: EmbeddedVector)] = []
        for (i, id) in ids.enumerated() {
            let v = i < vectors.count ? vectors[i] : nil
            pairs.append((id, v ?? EmbeddedVector(space: Self.noVectorSpace, values: [])))
        }
        try store.saveChunkVectors(pairs)
        return pairs.count
    }

    /// Mirrors a vault note into the search index (no-op when the content hash is unchanged).
    public func indexNote(path: String, body: String, mtime: Date = Date()) async throws {
        let title = Self.title(of: body, fallbackPath: path)
        try store.upsertNote(NoteRecord(path: path, title: title, body: body, hash: Hashing.sha256Hex(body), mtime: mtime))
    }

    /// First `# Heading` of a note, else the file name without extension.
    public static func title(of body: String, fallbackPath: String) -> String {
        for line in body.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return ((fallbackPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
