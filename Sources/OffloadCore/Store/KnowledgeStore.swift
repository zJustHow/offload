import Foundation

/// The single persistence facade: items, raw chunks (with lexical + vector indexes), vault notes
/// and the provenance links between them. All index maintenance happens here so that callers
/// cannot leave the lexical tables out of sync with the content tables.
public final class KnowledgeStore: @unchecked Sendable {
    public let db: Database
    public let tokenizer: LexicalTokenizer

    /// Bumped on every write that can change vector search results; `VectorIndex` uses it to
    /// know when its in-memory matrices are stale.
    public private(set) var vectorGeneration = 0
    private let genLock = NSLock()

    public init(db: Database, tokenizer: LexicalTokenizer? = nil) throws {
        self.db = db
        try Schema.apply(to: db)
        // The tokenizer configuration is part of the index format: indexed text and queries must
        // be produced by the same one. The first one used is pinned in the database.
        if let stored = try db.scalarText("SELECT value FROM meta WHERE key='tokenizer.bigrams'") {
            self.tokenizer = LexicalTokenizer(includeCJKBigrams: stored == "1")
        } else {
            let t = tokenizer ?? LexicalTokenizer()
            try db.run("INSERT INTO meta(key,value) VALUES('tokenizer.bigrams', ?)", [.text(t.includeCJKBigrams ? "1" : "0")])
            self.tokenizer = t
        }
        // Databases from before read markers existed: whatever they already hold counts as read,
        // once. After that a source is read only when a full read of it says so.
        if try db.scalarText("SELECT value FROM meta WHERE key='migrate.read-markers'") == nil {
            try db.run("INSERT OR IGNORE INTO meta(key,value) SELECT 'read.' || bucket, '1' FROM items GROUP BY bucket")
            try db.run("INSERT INTO meta(key,value) VALUES('migrate.read-markers', '1')")
        }
    }

    public convenience init(path: String) throws { try self.init(db: Database(path: path)) }

    private func bumpGeneration() { genLock.lock(); vectorGeneration += 1; genLock.unlock() }

    // MARK: - Items

    public func item(id: String) throws -> ItemRecord? {
        try db.query(Self.itemSelect + " WHERE id = ?", [.text(id)], Self.readItem).first
    }

    public func items(bucket: String) throws -> [ItemRecord] {
        try db.query(Self.itemSelect + " WHERE bucket = ?", [.text(bucket)], Self.readItem)
    }

    /// Items of a bucket whose `uri` is `path` itself or lies beneath it (`path/...`).
    public func items(bucket: String, under path: String) throws -> [ItemRecord] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return try db.query(
            Self.itemSelect + " WHERE bucket = ? AND (uri = ? OR substr(uri, 1, ?) = ?)",
            [.text(bucket), .text(path), .int(prefix.unicodeScalars.count), .text(prefix)], Self.readItem)
    }

    /// Inserts or replaces the row; chunks of a replaced item are kept until `replaceChunks`.
    public func upsertItem(_ it: ItemRecord) throws {
        try db.run(
            """
            INSERT INTO items(id,bucket,kind,uri,title,item_date,fingerprint,summary,verdict,reason,trust,created_at,updated_at,merged_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              bucket=excluded.bucket, kind=excluded.kind, uri=excluded.uri, title=excluded.title,
              item_date=excluded.item_date, fingerprint=excluded.fingerprint, summary=excluded.summary,
              verdict=excluded.verdict, reason=excluded.reason, trust=excluded.trust,
              updated_at=CASE WHEN excluded.fingerprint = items.fingerprint AND excluded.verdict = items.verdict
                              THEN items.updated_at ELSE excluded.updated_at END,
              merged_at=CASE WHEN excluded.fingerprint = items.fingerprint AND excluded.verdict = items.verdict
                             THEN items.merged_at ELSE NULL END,
              merge_attempts=CASE WHEN excluded.fingerprint = items.fingerprint AND excluded.verdict = items.verdict
                                  THEN items.merge_attempts ELSE 0 END
            """,
            [
                .text(it.id), .text(it.bucket), .text(it.kind.rawValue), .text(it.uri), .text(it.title),
                .opt(it.itemDate.map(Clock.epoch)), .text(it.fingerprint), .opt(it.summary),
                .text(it.verdict.rawValue), .opt(it.reason), .text(it.trust.rawValue),
                .double(Clock.epoch(it.createdAt)), .double(Clock.epoch(it.updatedAt)), .opt(it.mergedAt.map(Clock.epoch)),
            ])
    }

    public func deleteItem(id: String) throws {
        try db.run("DELETE FROM items WHERE id = ?", [.text(id)])
        bumpGeneration()
    }

    /// Records that a full read of this source ran to the end. Live sync only follows sources the
    /// user has read in full on purpose; this is the one flag it goes by.
    public func markRead(bucket: String) throws {
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?, '1')", [.text("read." + bucket)])
    }

    /// True once a full read of the source has run to the end. A read that was stopped, ran out of
    /// time or was capped does not count, however much of the source it already stored.
    public func hasBeenRead(bucket: String) throws -> Bool {
        try db.scalarText("SELECT value FROM meta WHERE key = ?", [.text("read." + bucket)]) != nil
    }

    /// True when this exact content has already been processed (any verdict except `failed`).
    public func isUpToDate(id: String, fingerprint: String) throws -> Bool {
        let rows = try db.query("SELECT fingerprint, verdict FROM items WHERE id = ?", [.text(id)]) { ($0.text(0), $0.text(1)) }
        guard let r = rows.first else { return false }
        return r.0 == fingerprint && r.1 != Verdict.failed.rawValue
    }

    /// Survivor items whose summary has not been merged into the vault yet (or changed since).
    public func unmergedSurvivors(limit: Int = 100_000) throws -> [ItemRecord] {
        try db.query(
            Self.itemSelect + " WHERE verdict = 'survivor' AND (merged_at IS NULL OR merged_at < updated_at) ORDER BY item_date DESC LIMIT ?",
            [.int(limit)], Self.readItem)
    }

    public func markMerged(ids: [String], at date: Date = Date()) throws {
        try db.transaction {
            for id in ids {
                try db.run("UPDATE items SET merged_at = ? WHERE id = ?", [.double(Clock.epoch(date)), .text(id)])
            }
        }
    }

    /// Records that these items were offered to the knowledge builder but not accounted for.
    /// After `giveUpAfter` attempts an item is considered merged so that a model that keeps
    /// ignoring it cannot make the pipeline retry forever. Returns (still pending, given up).
    @discardableResult
    public func recordMergeAttempt(ids: [String], giveUpAfter: Int = 3, at date: Date = Date()) throws -> (retry: Int, gaveUp: Int) {
        try db.transaction {
            var retry = 0, gaveUp = 0
            for id in ids {
                try db.run("UPDATE items SET merge_attempts = merge_attempts + 1 WHERE id = ?", [.text(id)])
                let attempts = try db.scalarInt("SELECT merge_attempts FROM items WHERE id = ?", [.text(id)]) ?? 0
                if attempts >= giveUpAfter {
                    try db.run("UPDATE items SET merged_at = ? WHERE id = ?", [.double(Clock.epoch(date)), .text(id)])
                    gaveUp += 1
                } else { retry += 1 }
            }
            return (retry, gaveUp)
        }
    }

    /// Survivor items per source, for the dashboard.
    public func survivorCountsByBucket() throws -> [String: Int] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT bucket, COUNT(*) FROM items WHERE verdict = 'survivor' GROUP BY bucket", []) { ($0.text(0), Int($0.int(1))) })
    }

    public func counts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, n) in try db.query("SELECT verdict, COUNT(*) FROM items GROUP BY verdict", [], { ($0.text(0), Int($0.int(1))) }) { out[k] = n }
        out["chunks"] = Int(try db.scalarInt("SELECT COUNT(*) FROM chunks") ?? 0)
        out["vectors"] = Int(try db.scalarInt("SELECT COUNT(*) FROM chunk_vec") ?? 0)
        out["notes"] = Int(try db.scalarInt("SELECT COUNT(*) FROM notes") ?? 0)
        return out
    }

    private static let itemSelect =
        "SELECT id,bucket,kind,uri,title,item_date,fingerprint,summary,verdict,reason,trust,created_at,updated_at,merged_at FROM items"

    private static let readItem: (Row) throws -> ItemRecord = { r in
        ItemRecord(
            id: r.text(0), bucket: r.text(1), kind: SourceKind(rawValue: r.text(2)) ?? .file, uri: r.text(3),
            title: r.text(4), itemDate: r.optDouble(5).map(Clock.date), fingerprint: r.text(6),
            summary: r.optText(7), verdict: Verdict(rawValue: r.text(8)) ?? .failed, reason: r.optText(9),
            trust: Trust(rawValue: r.text(10)) ?? .saved, createdAt: Clock.date(r.double(11)),
            updatedAt: Clock.date(r.double(12)), mergedAt: r.optDouble(13).map(Clock.date))
    }

    /// Saves the item row and its chunks atomically. A crash can therefore never leave an item
    /// marked "processed" without the chunks that make it searchable.
    @discardableResult
    public func commitItem(_ item: ItemRecord, chunkTexts: [String]) throws -> [Int64] {
        try db.transaction {
            try upsertItem(item)
            return try replaceChunks(itemID: item.id, texts: chunkTexts)
        }
    }

    // MARK: - Chunks

    /// Replaces every chunk of the item with `texts`, returning the new chunk ids in order.
    @discardableResult
    public func replaceChunks(itemID: String, texts: [String]) throws -> [Int64] {
        let ids: [Int64] = try db.transaction {
            try db.run("DELETE FROM chunks WHERE item_id = ?", [.text(itemID)])
            var ids: [Int64] = []
            for (i, t) in texts.enumerated() {
                try db.run(
                    "INSERT INTO chunks(item_id,ord,text,seg) VALUES(?,?,?,?)",
                    [.text(itemID), .int(i), .text(t), .text(tokenizer.indexText(t))])
                ids.append(db.lastInsertRowID)
            }
            return ids
        }
        bumpGeneration()
        return ids
    }

    public func chunk(id: Int64) throws -> ChunkRecord? {
        try db.query("SELECT id,item_id,ord,text FROM chunks WHERE id = ?", [.int(id)]) {
            ChunkRecord(id: $0.int(0), itemID: $0.text(1), ord: Int($0.int(2)), text: $0.text(3))
        }.first
    }

    public func chunks(itemID: String) throws -> [ChunkRecord] {
        try db.query("SELECT id,item_id,ord,text FROM chunks WHERE item_id = ? ORDER BY ord", [.text(itemID)]) {
            ChunkRecord(id: $0.int(0), itemID: $0.text(1), ord: Int($0.int(2)), text: $0.text(3))
        }
    }

    // MARK: - Vectors

    public func saveChunkVectors(_ pairs: [(chunkID: Int64, vector: EmbeddedVector)]) throws {
        try db.transaction {
            for p in pairs {
                try db.run(
                    "INSERT OR REPLACE INTO chunk_vec(chunk_id,space,dim,vec) VALUES(?,?,?,?)",
                    [.int(p.chunkID), .text(p.vector.space), .int(p.vector.values.count), .blob(p.vector.values.asData)])
            }
        }
        bumpGeneration()
    }

    /// Chunks that have no vector yet, oldest id first.
    public func chunksNeedingVectors(limit: Int) throws -> [ChunkRecord] {
        try db.query(
            """
            SELECT c.id,c.item_id,c.ord,c.text FROM chunks c
            LEFT JOIN chunk_vec v ON v.chunk_id = c.id
            WHERE v.chunk_id IS NULL ORDER BY c.id LIMIT ?
            """, [.int(limit)]
        ) { ChunkRecord(id: $0.int(0), itemID: $0.text(1), ord: Int($0.int(2)), text: $0.text(3)) }
    }

    public func allChunkVectors(space: String) throws -> [(id: Int64, values: [Float])] {
        try db.query("SELECT chunk_id, vec FROM chunk_vec WHERE space = ?", [.text(space)]) { ($0.int(0), $0.blob(1).asFloats) }
    }

    public func chunkVectorSpaces() throws -> [String] {
        try db.query("SELECT DISTINCT space FROM chunk_vec", []) { $0.text(0) }
    }

    // MARK: - Notes

    public func upsertNote(_ n: NoteRecord) throws {
        try db.transaction {
            let existing = try db.query("SELECT hash FROM notes WHERE path = ?", [.text(n.path)]) { $0.text(0) }.first
            if existing == n.hash {
                try db.run("UPDATE notes SET mtime = ? WHERE path = ?", [.double(Clock.epoch(n.mtime)), .text(n.path)])
                return
            }
            try db.run("DELETE FROM notes WHERE path = ?", [.text(n.path)])
            try db.run(
                "INSERT INTO notes(path,title,body,seg,hash,mtime) VALUES(?,?,?,?,?,?)",
                [.text(n.path), .text(n.title), .text(n.body), .text(tokenizer.indexText(n.title + "\n" + n.body)), .text(n.hash), .double(Clock.epoch(n.mtime))])
        }
        bumpGeneration()
    }

    public func deleteNote(path: String) throws {
        try db.run("DELETE FROM notes WHERE path = ?", [.text(path)])
        try db.run("DELETE FROM note_evidence WHERE note_path = ?", [.text(path)])
        bumpGeneration()
    }

    public func note(path: String) throws -> NoteRecord? {
        try db.query("SELECT path,title,body,hash,mtime FROM notes WHERE path = ?", [.text(path)], Self.readNote).first
    }

    public func allNotes() throws -> [NoteRecord] {
        try db.query("SELECT path,title,body,hash,mtime FROM notes ORDER BY path", [], Self.readNote)
    }

    public func notePaths() throws -> [String] { try db.query("SELECT path FROM notes ORDER BY path", []) { $0.text(0) } }

    private static let readNote: (Row) throws -> NoteRecord = {
        NoteRecord(path: $0.text(0), title: $0.text(1), body: $0.text(2), hash: $0.text(3), mtime: Clock.date($0.double(4)))
    }

    public func saveNoteVector(path: String, vector: EmbeddedVector) throws {
        try db.run(
            "INSERT OR REPLACE INTO note_vec(path,space,dim,vec) VALUES(?,?,?,?)",
            [.text(path), .text(vector.space), .int(vector.values.count), .blob(vector.values.asData)])
        bumpGeneration()
    }

    public func notesNeedingVectors() throws -> [NoteRecord] {
        try db.query(
            """
            SELECT n.path,n.title,n.body,n.hash,n.mtime FROM notes n
            LEFT JOIN note_vec v ON v.path = n.path WHERE v.path IS NULL
            """, [], Self.readNote)
    }

    public func allNoteVectors(space: String) throws -> [(path: String, values: [Float])] {
        try db.query("SELECT path, vec FROM note_vec WHERE space = ?", [.text(space)]) { ($0.text(0), $0.blob(1).asFloats) }
    }

    public func noteVectorSpaces() throws -> [String] {
        try db.query("SELECT DISTINCT space FROM note_vec", []) { $0.text(0) }
    }

    // MARK: - Provenance

    public func addEvidence(notePath: String, itemIDs: [String]) throws {
        try db.transaction {
            for id in Set(itemIDs) {
                try db.run(
                    "INSERT OR IGNORE INTO note_evidence(note_path,item_id) SELECT ?, id FROM items WHERE id = ?",
                    [.text(notePath), .text(id)])
            }
        }
    }

    public func evidenceItems(notePath: String) throws -> [ItemRecord] {
        try db.query(
            Self.itemSelect + " WHERE id IN (SELECT item_id FROM note_evidence WHERE note_path = ?) ORDER BY item_date DESC",
            [.text(notePath)], Self.readItem)
    }

    public func notesCiting(itemID: String) throws -> [String] {
        try db.query("SELECT note_path FROM note_evidence WHERE item_id = ?", [.text(itemID)]) { $0.text(0) }
    }
}
