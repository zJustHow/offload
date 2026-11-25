import Foundation

public struct ItemView: Sendable {
    public var id: String
    public var title: String
    public var kind: SourceKind
    public var uri: String
    public var date: Date?
    public var summary: String?
    /// The original text, already redacted by `PIIScan` before it was indexed.
    public var rawText: String
    public var citedByNotes: [String]
}

/// The single doorway through which assistants read memory: hybrid search, notes, and the
/// original text behind a note. Raw excerpts are returned to every caller; what protects them is
/// the `PIIScan.redact` pass applied before they were indexed.
public final class MemoryService: @unchecked Sendable {
    public let store: KnowledgeStore
    public let searcher: HybridSearcher
    public let workspace: VaultWorkspace

    public init(store: KnowledgeStore, searcher: HybridSearcher, workspace: VaultWorkspace) {
        self.store = store; self.searcher = searcher; self.workspace = workspace
    }

    public func search(_ query: String, options: SearchOptions = SearchOptions()) async throws -> [SearchHit] {
        try await searcher.search(query, options: options)
    }

    /// Folder tree plus the README portrait: the cheap "what do you know about me" overview.
    public func structure() throws -> String {
        let notes = try workspace.readAll()
        var out = "Knowledge base: \(notes.count) notes\n\n"
        let paths = notes.keys.sorted()
        var lastFolder = ""
        for p in paths where p != "README.md" {
            let folder = (p as NSString).deletingLastPathComponent
            if folder != lastFolder { out += "\(folder)/\n"; lastFolder = folder }
            out += "  \((p as NSString).lastPathComponent)\n"
        }
        if let readme = notes["README.md"] { out += "\n=== README.md ===\n" + readme }
        return out
    }

    /// A vault note by relative path. Only visible notes inside the vault can be read; the path is
    /// normalized first, so `../` tricks resolve to "not found" instead of another file.
    public func note(path: String) throws -> String? { try resolveNote(path, in: workspace.readAll())?.body }

    /// Exact match first, then a case-insensitive match when it is unambiguous (models often get
    /// the capitalization of a path slightly wrong).
    public func resolveNote(_ path: String, in notes: [String: String]) -> (path: String, body: String)? {
        guard let safe = VaultOps.normalizePath(path)?.precomposedStringWithCanonicalMapping else { return nil }
        if let body = notes[safe] { return (safe, body) }
        let matches = notes.filter { $0.key.caseInsensitiveCompare(safe) == .orderedSame }
        if matches.count == 1, let m = matches.first { return (m.key, m.value) }
        return nil
    }

    public func item(id: String) throws -> ItemView? {
        guard let it = try store.item(id: id), it.verdict == .survivor else { return nil }
        let raw = try store.chunks(itemID: id).map(\.text).joined(separator: "\n\n")
        return ItemView(id: it.id, title: it.title, kind: it.kind, uri: it.uri, date: it.itemDate, summary: it.summary, rawText: raw, citedByNotes: try store.notesCiting(itemID: id))
    }

    /// The only file paths an assistant may ask the OS to open: originals Offload itself indexed.
    public func isKnownSource(uri: String) throws -> Bool {
        try (store.db.scalarInt("SELECT COUNT(*) FROM items WHERE uri = ? AND verdict = 'survivor'", [.text(uri)]) ?? 0) > 0
    }

    /// Search hits rendered for a prompt or tool result, with the provenance an assistant needs to
    /// go and look at the original.
    public static func render(_ hits: [SearchHit], maxChars: Int = 6_000) -> String {
        var out = ""
        for (i, h) in hits.enumerated() {
            var entry: String
            switch h.kind {
            case .note: entry = "[\(i + 1)] NOTE \(h.notePath ?? h.title)\n\(h.snippet)\n"
            case .chunk:
                let src = h.source.map { "\($0.kind.rawValue) · \($0.title)" + ($0.date.map { " · " + Self.day($0) } ?? "") } ?? ""
                entry = "[\(i + 1)] SOURCE item=\(h.itemID ?? "?") \(src)\n\(h.snippet)\n"
                if !h.citedByNotes.isEmpty { entry += "(cited by notes: \(h.citedByNotes.joined(separator: ", ")))\n" }
            }
            if out.count + entry.count > maxChars { break }
            out += entry + "\n"
        }
        return out.isEmpty ? "(no results)" : out
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }
}
