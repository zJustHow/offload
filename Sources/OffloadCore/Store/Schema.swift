import Foundation

/// Schema creation and versioning. Version 1 is the first and only shape so far; later versions
/// append `if version < N { ... }` blocks.
enum Schema {
    static let currentVersion = 1

    static func apply(to db: Database) throws {
        let version = Int(try db.scalarInt("PRAGMA user_version;") ?? 0)
        if version >= currentVersion { return }
        try db.transaction {
            try db.exec(v1)
            try db.exec("PRAGMA user_version = \(currentVersion);")
        }
    }

    private static let v1 = """
    CREATE TABLE IF NOT EXISTS meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    -- One row per ingested source item (file, chat window, mail, event...). Provenance anchor.
    CREATE TABLE IF NOT EXISTS items(
        id          TEXT PRIMARY KEY,
        bucket      TEXT NOT NULL,
        kind        TEXT NOT NULL,
        uri         TEXT NOT NULL,
        title       TEXT NOT NULL,
        item_date   REAL,
        fingerprint TEXT NOT NULL,
        summary     TEXT,
        verdict     TEXT NOT NULL,
        reason      TEXT,
        trust       TEXT NOT NULL,
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL,
        merged_at   REAL,
        merge_attempts INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS items_bucket ON items(bucket);
    CREATE INDEX IF NOT EXISTS items_pending ON items(verdict, merged_at);

    -- Raw, privacy-filtered text pieces of survivor items.
    CREATE TABLE IF NOT EXISTS chunks(
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        ord     INTEGER NOT NULL,
        text    TEXT NOT NULL,
        seg     TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS chunks_item ON chunks(item_id, ord);

    -- Lexical indexes (external content: the text lives once, in `chunks`).
    CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
        seg, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS chunk_tri USING fts5(
        text, content='chunks', content_rowid='id', tokenize='trigram'
    );
    CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunk_fts(rowid, seg) VALUES (new.id, new.seg);
        INSERT INTO chunk_tri(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunk_fts(chunk_fts, rowid, seg) VALUES ('delete', old.id, old.seg);
        INSERT INTO chunk_tri(chunk_tri, rowid, text) VALUES ('delete', old.id, old.text);
    END;

    CREATE TABLE IF NOT EXISTS chunk_vec(
        chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
        space    TEXT NOT NULL,
        dim      INTEGER NOT NULL,
        vec      BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS chunk_vec_space ON chunk_vec(space);

    -- The knowledge base mirror: every note in the vault folder, indexed the same way.
    CREATE TABLE IF NOT EXISTS notes(
        path   TEXT PRIMARY KEY,
        title  TEXT NOT NULL,
        body   TEXT NOT NULL,
        seg    TEXT NOT NULL,
        hash   TEXT NOT NULL,
        mtime  REAL NOT NULL
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(
        seg, content='notes', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
        INSERT INTO note_fts(rowid, seg) VALUES (new.rowid, new.seg);
    END;
    CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
        INSERT INTO note_fts(note_fts, rowid, seg) VALUES ('delete', old.rowid, old.seg);
    END;
    CREATE TABLE IF NOT EXISTS note_vec(
        path  TEXT PRIMARY KEY REFERENCES notes(path) ON DELETE CASCADE,
        space TEXT NOT NULL,
        dim   INTEGER NOT NULL,
        vec   BLOB NOT NULL
    );

    -- Which source items support which note (the "zoom in" link from summary to original).
    CREATE TABLE IF NOT EXISTS note_evidence(
        note_path TEXT NOT NULL,
        item_id   TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        PRIMARY KEY(note_path, item_id)
    );
    CREATE INDEX IF NOT EXISTS note_evidence_item ON note_evidence(item_id);

    -- Suggestions prepared overnight, and assistant conversation memory.
    CREATE TABLE IF NOT EXISTS cards(
        id         TEXT PRIMARY KEY,
        created_at REAL NOT NULL,
        kind       TEXT NOT NULL,
        title      TEXT NOT NULL,
        payload    TEXT NOT NULL,
        status     TEXT NOT NULL DEFAULT 'ready'
    );
    CREATE TABLE IF NOT EXISTS conversation(
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at REAL NOT NULL,
        role       TEXT NOT NULL,
        content    TEXT NOT NULL
    );
    """
}
