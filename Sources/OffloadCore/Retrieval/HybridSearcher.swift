import Foundation

public enum HitKind: String, Sendable { case note, chunk }

public struct SourceInfo: Sendable, Equatable {
    public let kind: SourceKind
    public let uri: String
    public let title: String
    public let date: Date?
}

/// Which retrievers surfaced a hit, and at what rank (1 = best). Useful for debugging and evals.
public struct HitSignals: Sendable, Equatable {
    public var lexicalRank: Int?
    public var exactRank: Int?
    public var vectorRank: Int?
    public var provenanceBoost: Double = 0
}

public struct SearchHit: Sendable, Identifiable {
    public var id: String
    public var kind: HitKind
    public var title: String
    public var snippet: String
    public var text: String
    public var score: Double
    public var notePath: String?
    public var itemID: String?
    public var chunkID: Int64?
    public var source: SourceInfo?
    /// Vault notes whose evidence includes this hit's source item (summary -> original link).
    public var citedByNotes: [String]
    public var signals: HitSignals
}

public struct SearchOptions: Sendable {
    public enum Mode: Sendable { case hybrid, lexicalOnly, exactOnly, vectorOnly }
    public var limit = 8
    public var mode: Mode = .hybrid
    public var include: Set<HitKind> = [.note, .chunk]
    public var sourceKinds: Set<SourceKind>? = nil
    public var since: Date? = nil
    /// Candidates fetched from each retriever before fusion.
    public var candidatePool = 60
    /// At most this many chunks from one source item (keeps one long document from filling the list).
    public var perItemCap = 2
    /// Newer items get up to this fractional boost, decaying with the given half-life; nil disables.
    public var recencyBoost: Double? = 0.15
    public var recencyHalfLifeDays = 365.0
    /// Weight of the summary<->original link: a chunk gains score when a highly ranked note cites
    /// its item, and a note gains score when its evidence contains highly ranked chunks.
    public var provenanceWeight = 0.35
    public init() {}
}

/// Hybrid retrieval over the raw chunks and the vault notes.
///
/// Four retrievers run per query and are merged with weighted Reciprocal Rank Fusion:
///  1. **lexical** — BM25 over word-segmented text (handles Chinese, and rare terms);
///  2. **exact** — FTS5 trigram substring search for identifiers, quoted phrases, emails (order
///     numbers, contract ids and the like, which neither word tokens nor embeddings match well);
///  3. **vector** — cosine similarity in the embedder's space (paraphrases, vague wording);
///  4. a **provenance** pass that lets the synthesized notes and the raw evidence vouch for each
///     other.
/// Fusion uses ranks, not scores, because BM25 and cosine live on incomparable scales (and the
/// built-in Apple embeddings compress cosine scores into a narrow band).
public final class HybridSearcher: @unchecked Sendable {
    private let store: KnowledgeStore
    private let embedder: Embedder?
    private let vectors: VectorIndex
    private static let rrfK = 60.0

    public init(store: KnowledgeStore, embedder: Embedder?, vectors: VectorIndex? = nil) {
        self.store = store
        self.embedder = embedder
        self.vectors = vectors ?? VectorIndex(store: store)
    }

    // MARK: - Public

    public func search(_ query: String, options: SearchOptions = SearchOptions()) async throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let traits = QueryTraits(q)
        let pool = options.candidatePool
        let useLexical = options.mode == .hybrid || options.mode == .lexicalOnly
        let useExact = options.mode == .hybrid || options.mode == .exactOnly
        let useVector = options.mode == .hybrid || options.mode == .vectorOnly

        var queryVector: EmbeddedVector?
        if useVector, let embedder { queryVector = try await embedder.embed([q]).first ?? nil }

        // Weights: identifier-like queries lean on exact/lexical matching, vague ones on vectors.
        let wLex = traits.identifierLike ? 1.3 : 1.0
        let wExact = traits.identifierLike ? 1.3 : 0.8
        let wVec = traits.identifierLike ? 0.6 : 1.0

        var chunkHits: [String: Builder] = [:]
        var noteHits: [String: Builder] = [:]

        if options.include.contains(.chunk) {
            if useLexical, let fts = store.tokenizer.ftsQuery(q) {
                let ids = try store.db.query(
                    "SELECT rowid FROM chunk_fts WHERE chunk_fts MATCH ? ORDER BY bm25(chunk_fts) LIMIT ?",
                    [.text(fts), .int(pool * 2)]) { $0.int(0) }
                for (i, id) in ids.enumerated() { chunkHits["chunk:\(id)", default: Builder()].add(.lexical, rank: i + 1, weight: wLex) }
            }
            if useExact {
                var best: [Int64: Int] = [:]
                for needle in traits.exactNeedles {
                    let ids = try store.db.query(
                        "SELECT rowid FROM chunk_tri WHERE chunk_tri MATCH ? ORDER BY bm25(chunk_tri) LIMIT ?",
                        [.text(Self.quote(needle)), .int(pool)]) { $0.int(0) }
                    for (i, id) in ids.enumerated() { best[id] = min(best[id] ?? Int.max, i + 1) }
                }
                for (id, rank) in best { chunkHits["chunk:\(id)", default: Builder()].add(.exact, rank: rank, weight: wExact) }
            }
            if let qv = queryVector {
                for (i, h) in try vectors.searchChunks(qv, k: pool * 2).enumerated() {
                    chunkHits["chunk:\(h.id)", default: Builder()].add(.vector, rank: i + 1, weight: wVec)
                }
            }
        }

        if options.include.contains(.note) {
            if useLexical, let fts = store.tokenizer.ftsQuery(q) {
                let paths = try store.db.query(
                    "SELECT n.path FROM note_fts f JOIN notes n ON n.rowid = f.rowid WHERE note_fts MATCH ? ORDER BY bm25(note_fts) LIMIT ?",
                    [.text(fts), .int(pool)]) { $0.text(0) }
                for (i, p) in paths.enumerated() { noteHits["note:\(p)", default: Builder()].add(.lexical, rank: i + 1, weight: wLex) }
            }
            if useExact {
                var best: [String: Int] = [:]
                for needle in traits.exactNeedles {
                    let rows = try store.db.query(
                        "SELECT path FROM notes WHERE instr(lower(body), lower(?)) > 0 OR instr(lower(title), lower(?)) > 0 LIMIT ?",
                        [.text(needle), .text(needle), .int(pool)]) { $0.text(0) }
                    for (i, p) in rows.enumerated() { best[p] = min(best[p] ?? Int.max, i + 1) }
                }
                for (p, rank) in best { noteHits["note:\(p)", default: Builder()].add(.exact, rank: rank, weight: wExact) }
            }
            if let qv = queryVector {
                for (i, h) in try vectors.searchNotes(qv, k: pool).enumerated() {
                    noteHits["note:\(h.path)", default: Builder()].add(.vector, rank: i + 1, weight: wVec)
                }
            }
        }

        // Materialize chunk hits (also applies the source/date filters).
        var hits: [SearchHit] = []
        let chunkIDs = chunkHits.keys.compactMap { Int64($0.dropFirst(6)) }
        let meta = try chunkMetadata(chunkIDs)
        for (key, b) in chunkHits {
            guard let id = Int64(key.dropFirst(6)), let m = meta[id] else { continue }
            if let kinds = options.sourceKinds, !kinds.contains(m.source.kind) { continue }
            if let since = options.since, let d = m.source.date, d < since { continue }
            var score = b.score
            if let boost = options.recencyBoost, let d = m.source.date {
                let ageDays = max(0, Date().timeIntervalSince(d) / 86_400)
                score *= 1 + boost * pow(0.5, ageDays / options.recencyHalfLifeDays)
            }
            hits.append(SearchHit(
                id: key, kind: .chunk, title: m.source.title, snippet: Self.snippet(m.text, tokens: traits.snippetTokens),
                text: m.text, score: score, notePath: nil, itemID: m.itemID, chunkID: id, source: m.source,
                citedByNotes: [], signals: b.signals))
        }
        if options.sourceKinds == nil && options.since == nil {
            let notes = try noteRecords(Array(noteHits.keys.map { String($0.dropFirst(5)) }))
            for (key, b) in noteHits {
                guard let n = notes[String(key.dropFirst(5))] else { continue }
                hits.append(SearchHit(
                    id: key, kind: .note, title: n.title, snippet: Self.snippet(n.body, tokens: traits.snippetTokens),
                    text: n.body, score: b.score, notePath: n.path, itemID: nil, chunkID: nil, source: nil,
                    citedByNotes: [], signals: b.signals))
            }
        }

        try applyProvenance(&hits, weight: options.provenanceWeight)
        hits.sort { $0.score > $1.score }
        return Self.capPerItem(hits, cap: options.perItemCap, limit: options.limit)
    }

    // MARK: - Query analysis

    struct QueryTraits {
        let identifierLike: Bool
        let exactNeedles: [String]
        let snippetTokens: [String]

        init(_ q: String) {
            var needles: [String] = []
            // Quoted phrases (straight and curly quotes, plus CJK corner brackets).
            let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』")]
            for (open, close) in quotePairs {
                var rest = Substring(q)
                while let a = rest.firstIndex(of: open) {
                    let after = rest.index(after: a)
                    guard let b = rest[after...].firstIndex(of: close) else { break }
                    let phrase = String(rest[after..<b]).trimmingCharacters(in: .whitespaces)
                    if phrase.count >= 3 { needles.append(phrase) }
                    rest = rest[rest.index(after: b)...]
                }
            }
            // Identifier-shaped words: contain a digit and are long enough, or look like emails/ids.
            let trim = CharacterSet.alphanumerics.inverted
            for raw in q.split(whereSeparator: { $0.isWhitespace }) {
                let w = String(raw).trimmingCharacters(in: trim.subtracting(CharacterSet(charactersIn: "@.-_#/")))
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)(]["))
                let hasDigit = w.contains(where: { $0.isNumber })
                let hasLetter = w.contains(where: { $0.isLetter })
                if w.count >= 4, hasDigit, !w.contains(where: { LexicalTokenizer.isCJK($0.unicodeScalars.first!) }) {
                    needles.append(w.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
                    _ = hasLetter
                } else if w.contains("@"), w.count >= 5 {
                    needles.append(w)
                }
            }
            var seen = Set<String>()
            let unique = needles.filter { seen.insert($0.lowercased()).inserted }
            self.exactNeedles = unique
            self.identifierLike = !unique.isEmpty
            var snip = unique
            snip.append(contentsOf: LexicalTokenizer().queryTokens(q))
            self.snippetTokens = snip
        }
    }

    // MARK: - Fusion

    enum Signal { case lexical, exact, vector }

    struct Builder {
        var score = 0.0
        var signals = HitSignals()
        mutating func add(_ s: Signal, rank: Int, weight: Double) {
            score += weight / (HybridSearcher.rrfK + Double(rank))
            switch s {
            case .lexical: signals.lexicalRank = min(signals.lexicalRank ?? .max, rank)
            case .exact: signals.exactRank = min(signals.exactRank ?? .max, rank)
            case .vector: signals.vectorRank = min(signals.vectorRank ?? .max, rank)
            }
        }
    }

    /// Lets notes and raw chunks corroborate each other through `note_evidence`.
    private func applyProvenance(_ hits: inout [SearchHit], weight: Double) throws {
        guard weight > 0 else { return }
        let noteRanks: [String: Int] = {
            let notes = hits.filter { $0.kind == .note }.sorted { $0.score > $1.score }
            var out: [String: Int] = [:]
            for (i, n) in notes.prefix(5).enumerated() { if let p = n.notePath { out[p] = i + 1 } }
            return out
        }()
        let chunkItemRanks: [String: Int] = {
            let chunks = hits.filter { $0.kind == .chunk }.sorted { $0.score > $1.score }
            var out: [String: Int] = [:]
            for (i, c) in chunks.prefix(8).enumerated() { if let id = c.itemID, out[id] == nil { out[id] = i + 1 } }
            return out
        }()
        // Citations for every chunk hit's item, in one query.
        let itemIDs = Array(Set(hits.compactMap { $0.itemID }))
        var citations: [String: [String]] = [:]
        if !itemIDs.isEmpty {
            let ph = itemIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try store.db.query(
                "SELECT item_id, note_path FROM note_evidence WHERE item_id IN (\(ph))", itemIDs.map { .text($0) }
            ) { ($0.text(0), $0.text(1)) }
            for (item, path) in rows { citations[item, default: []].append(path) }
        }
        for i in hits.indices {
            switch hits[i].kind {
            case .chunk:
                guard let item = hits[i].itemID else { continue }
                let cited = citations[item] ?? []
                hits[i].citedByNotes = cited
                var boost = 0.0
                for path in cited { if let r = noteRanks[path] { boost = max(boost, weight / (Self.rrfK + Double(r))) } }
                hits[i].score += boost
                hits[i].signals.provenanceBoost = boost
            case .note:
                guard let path = hits[i].notePath else { continue }
                var boost = 0.0
                let evidence = try store.db.query("SELECT item_id FROM note_evidence WHERE note_path = ?", [.text(path)]) { $0.text(0) }
                for item in evidence { if let r = chunkItemRanks[item] { boost = max(boost, weight / (Self.rrfK + Double(r))) } }
                hits[i].score += boost
                hits[i].signals.provenanceBoost = boost
            }
        }
    }

    private static func capPerItem(_ hits: [SearchHit], cap: Int, limit: Int) -> [SearchHit] {
        var counts: [String: Int] = [:]
        var out: [SearchHit] = []
        for h in hits {
            if let item = h.itemID {
                if counts[item, default: 0] >= cap { continue }
                counts[item, default: 0] += 1
            }
            out.append(h)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Lookups

    private struct ChunkMeta { let itemID: String; let text: String; let source: SourceInfo }

    private func chunkMetadata(_ ids: [Int64]) throws -> [Int64: ChunkMeta] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: ChunkMeta] = [:]
        for batch in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let ph = batch.map { _ in "?" }.joined(separator: ",")
            let rows = try store.db.query(
                """
                SELECT c.id, c.item_id, c.text, i.kind, i.uri, i.title, i.item_date
                FROM chunks c JOIN items i ON i.id = c.item_id
                WHERE c.id IN (\(ph)) AND i.verdict = 'survivor'
                """, batch.map { .int($0) }
            ) { r -> (Int64, ChunkMeta) in
                (r.int(0), ChunkMeta(
                    itemID: r.text(1), text: r.text(2),
                    source: SourceInfo(kind: SourceKind(rawValue: r.text(3)) ?? .file, uri: r.text(4), title: r.text(5), date: r.optDouble(6).map(Clock.date))))
            }
            for (id, m) in rows { out[id] = m }
        }
        return out
    }

    private func noteRecords(_ paths: [String]) throws -> [String: NoteRecord] {
        var out: [String: NoteRecord] = [:]
        for p in paths { if let n = try store.note(path: p) { out[p] = n } }
        return out
    }

    // MARK: - Text helpers

    private static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func snippet(_ text: String, tokens: [String], radius: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        for t in tokens where t.count >= 2 {
            if let r = flat.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) {
                let lo = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
                let hi = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
                return (lo > flat.startIndex ? "…" : "") + flat[lo..<hi].trimmingCharacters(in: .whitespaces) + (hi < flat.endIndex ? "…" : "")
            }
        }
        return String(flat.prefix(radius * 2)) + (flat.count > radius * 2 ? "…" : "")
    }
}
