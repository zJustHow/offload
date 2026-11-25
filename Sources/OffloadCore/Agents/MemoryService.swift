import Foundation

/// What may leave this Mac when a *hosted* model is the consumer.
///
/// The knowledge base (summaries and notes) is the product's designed-for-sharing layer, so it is
/// always available. The raw-text index is different: it holds the specifics that summaries
/// deliberately drop, so handing snippets of it to a hosted model is a separate, explicit choice.
/// Local models (on-device or on localhost) are never restricted.
public struct EgressPolicy: Sendable, Codable, Equatable {
    public var rawSnippetsToHostedModels: Bool
    public init(rawSnippetsToHostedModels: Bool = false) { self.rawSnippetsToHostedModels = rawSnippetsToHostedModels }
    public func allowsRaw(for audience: ModelCapabilities) -> Bool { audience.isLocal || rawSnippetsToHostedModels }
}

public struct ItemView: Sendable {
    public var id: String
    public var title: String
    public var kind: SourceKind
    public var uri: String
    public var date: Date?
    public var summary: String?
    /// Redacted original text; nil when the audience is not allowed to see raw text.
    public var rawText: String?
    public var citedByNotes: [String]
}

/// The single doorway through which assistants read memory: hybrid search, notes, and the
/// original text behind a note. Every method takes the audience (the model that will see the
/// result) so the egress policy is enforced in one place instead of in each caller.
public final class MemoryService: @unchecked Sendable {
    public let store: KnowledgeStore
    public let searcher: HybridSearcher
    public let workspace: VaultWorkspace
    public var policy: EgressPolicy

    public init(store: KnowledgeStore, searcher: HybridSearcher, workspace: VaultWorkspace, policy: EgressPolicy = EgressPolicy()) {
        self.store = store; self.searcher = searcher; self.workspace = workspace; self.policy = policy
    }

    public func search(_ query: String, options: SearchOptions = SearchOptions(), audience: ModelCapabilities) async throws -> [SearchHit] {
        var opts = options
        if !policy.allowsRaw(for: audience) { opts.include.remove(.chunk) }
        var hits = try await searcher.search(query, options: opts)
        if !policy.allowsRaw(for: audience) { hits.removeAll { $0.kind == .chunk } }
        return hits
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

    public func item(id: String, audience: ModelCapabilities) throws -> ItemView? {
        guard let it = try store.item(id: id), it.verdict == .survivor else { return nil }
        let raw: String? = policy.allowsRaw(for: audience)
            ? try store.chunks(itemID: id).map(\.text).joined(separator: "\n\n") : nil
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
