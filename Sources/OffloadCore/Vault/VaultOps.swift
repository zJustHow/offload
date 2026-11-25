import Foundation

/// One edit the model proposes to the knowledge base.
public struct VaultOperation: Sendable, Equatable {
    public enum Kind: String, Sendable { case create, append, rewrite }
    public var kind: Kind
    public var path: String
    public var content: String
    /// 1-based indexes into the "new evidence" list the model was shown.
    public var evidence: [Int]

    public init(kind: Kind, path: String, content: String, evidence: [Int] = []) {
        self.kind = kind; self.path = path; self.content = content; self.evidence = evidence
    }
}

public struct VaultLimits: Sendable {
    public var maxNotes = 150
    public var maxRootFolders = 12
    public var maxFolderDepth = 3
    public var maxPathLength = 120
    public var maxNoteChars = 14_000
    /// A rewrite may not shrink a note below this fraction of its size: models are tempted to
    /// "tidy" by silently dropping facts.
    public var minRewriteRatio = 0.6
    public init() {}
}

public enum OpRejection: String, Sendable {
    case invalidPath, rootNote, tooDeep, tooManyNotes, tooManyFolders
    case emptyContent, shrinksTooMuch, duplicateTitle, tooLong
}

/// Parsing, validation and application of model-proposed edits. Everything here is a pure
/// function over an in-memory `[path: body]` map, so the rules are testable without a model, and
/// the model can never touch the filesystem directly.
public enum VaultOps {
    // MARK: Parsing

    public static func parse(_ raw: String) -> [VaultOperation]? { parseReply(raw)?.ops }

    /// Operations plus the evidence numbers the model explicitly set aside as not durable.
    public static func parseReply(_ raw: String) -> (ops: [VaultOperation], skipped: [Int])? {
        guard let obj = JSONExtract.firstObject(in: raw), let list = obj["operations"] as? [[String: Any]] else { return nil }
        let skipped = (obj["skipped"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") } ?? []
        var ops: [VaultOperation] = []
        for item in list {
            guard let opName = (item["op"] as? String)?.lowercased(),
                let path = item["path"] as? String, let content = item["content"] as? String
            else { continue }
            let kind: VaultOperation.Kind
            switch opName {
            case "create", "new", "add_note": kind = .create
            case "append", "add", "extend": kind = .append
            case "rewrite", "replace", "update": kind = .rewrite
            default: continue
            }
            let evidence = (item["evidence"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") } ?? []
            ops.append(VaultOperation(kind: kind, path: path, content: content, evidence: evidence))
        }
        return (ops, skipped)
    }

    // MARK: Paths and titles

    /// Canonical vault-relative path, or nil when the path is unsafe. This is a security boundary:
    /// the model controls the string, and it must never escape the vault directory.
    public static func normalizePath(_ raw: String) -> String? {
        var p = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasPrefix("/") || p.hasPrefix("~") { return nil }
        if p.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return nil }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty || parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0.hasPrefix(".") }) { return nil }
        var joined = parts.joined(separator: "/")
        if !joined.lowercased().hasSuffix(".md") { joined += ".md" }
        // Characters that are legal on APFS but break links, shells or other file systems.
        if joined.contains(where: { "<>:\"|?*".contains($0) }) { return nil }
        return joined
    }

    public static func title(of body: String, path: String) -> String { Indexer.title(of: body, fallbackPath: path) }

    // MARK: Application

    public struct Result: Sendable {
        public var applied: [VaultOperation] = []
        public var rejected: [(op: VaultOperation, reason: OpRejection)] = []
        public var changedPaths: [String] = []
        /// Operation -> normalized path it ended up affecting (after create/append conversion).
        public var effectivePaths: [Int: String] = [:]
    }

    /// Applies `ops` to `notes` in order, enforcing every limit. Invalid operations are rejected
    /// individually; the rest still apply.
    public static func apply(_ ops: [VaultOperation], to notes: inout [String: String], limits: VaultLimits = VaultLimits()) -> Result {
        var result = Result()
        for (index, original) in ops.enumerated() {
            var op = original
            guard let path = normalizePath(op.path) else { result.rejected.append((original, .invalidPath)); continue }
            op.path = path
            let parts = path.split(separator: "/")
            if parts.count == 1 && path != "README.md" { result.rejected.append((original, .rootNote)); continue }
            if path == "README.md" { result.rejected.append((original, .invalidPath)); continue }  // the portrait is generated, not edited
            if parts.count - 1 > limits.maxFolderDepth { result.rejected.append((original, .tooDeep)); continue }
            if path.count > limits.maxPathLength { result.rejected.append((original, .invalidPath)); continue }

            var content = op.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { result.rejected.append((original, .emptyContent)); continue }
            let exists = notes[path] != nil

            // Be forgiving about the model's choice of verb when the intent is obvious.
            if op.kind == .create && exists {
                op.kind = .append
                content = stripLeadingHeading(content)
                if content.isEmpty { result.rejected.append((original, .emptyContent)); continue }
            } else if op.kind == .append && !exists {
                // "Add this to the note at <path>" where there is no such note: the intent is
                // clear, so create it (with a heading derived from the file name if needed).
                op.kind = .create
            } else if op.kind == .rewrite && !exists {
                op.kind = .create
            }
            if !content.hasPrefix("# ") && op.kind != .append { content = "# \(titleFromPath(path))\n\n" + content }

            switch op.kind {
            case .create:
                if notes.count >= limits.maxNotes { result.rejected.append((original, .tooManyNotes)); continue }
                let root = String(parts[0])
                let roots = Set(notes.keys.compactMap { $0.split(separator: "/").first.map(String.init) }.filter { $0 != "README.md" })
                if !roots.contains(root) && roots.count >= limits.maxRootFolders { result.rejected.append((original, .tooManyFolders)); continue }
                let newTitle = title(of: content, path: path).lowercased()
                if notes.contains(where: { $0.key != path && title(of: $0.value, path: $0.key).lowercased() == newTitle }) {
                    result.rejected.append((original, .duplicateTitle)); continue
                }
                if content.count > limits.maxNoteChars { result.rejected.append((original, .tooLong)); continue }
                notes[path] = content + "\n"
            case .append:
                // Idempotence: models (and retried runs) re-append text the note already has.
                let existing = notes[path] ?? ""
                content = dropParagraphs(of: content, alreadyIn: existing)
                if content.isEmpty { result.rejected.append((original, .emptyContent)); continue }
                let merged = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + content + "\n"
                if merged.count > limits.maxNoteChars { result.rejected.append((original, .tooLong)); continue }
                notes[path] = merged
            case .rewrite:
                let old = notes[path] ?? ""
                if Double(content.count) < Double(old.count) * limits.minRewriteRatio { result.rejected.append((original, .shrinksTooMuch)); continue }
                if content.count > limits.maxNoteChars { result.rejected.append((original, .tooLong)); continue }
                notes[path] = content + "\n"
            }
            op.content = content
            result.applied.append(op)
            result.effectivePaths[index] = path
            if !result.changedPaths.contains(path) { result.changedPaths.append(path) }
        }
        return result
    }

    // MARK: Duplicates

    /// Removes repeated paragraphs and repeated list items, keeping the first occurrence.
    /// Weaker models re-state facts they already wrote; this is deterministic and loses nothing.
    public static func collapseDuplicates(in body: String) -> String {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        var seenParagraphs = Set<String>()
        var seenLines = Set<String>()
        var paragraphs: [String] = []
        for para in body.components(separatedBy: "\n\n") {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || !seenParagraphs.insert(norm(trimmed)).inserted { continue }
            // Inside a paragraph, drop list items or lines already seen elsewhere in the note.
            // Headings and very short lines are always kept.
            let lines = trimmed.components(separatedBy: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || t.hasPrefix("#") || t.count < 12 || seenLines.insert(norm(t)).inserted
            }
            let rebuilt = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rebuilt.isEmpty { paragraphs.append(rebuilt) }
        }
        return paragraphs.joined(separator: "\n\n") + "\n"
    }

    // MARK: Links

    /// Turns `[[Target]]` into plain `Target` when no note with that title or file name exists, so
    /// the vault never contains dangling links. `[[Target|alias]]` and `[[Target#heading]]` are
    /// resolved on `Target`.
    public static func cleanLinks(in body: String, existing notes: [String: String]) -> String {
        var known = Set<String>()
        for (path, text) in notes {
            known.insert(title(of: text, path: path).lowercased())
            known.insert(((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased())
        }
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)\]\]"#) else { return body }
        let ns = body as NSString
        var out = body
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)).reversed() {
            let inner = ns.substring(with: m.range(at: 1))
            let target = inner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? inner
            let base = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
            if known.contains(base.trimmingCharacters(in: .whitespaces).lowercased()) { continue }
            let visible = inner.split(separator: "|", maxSplits: 1).last.map(String.init) ?? base
            out = (out as NSString).replacingCharacters(in: m.range, with: visible)
        }
        return out
    }

    /// Removes paragraphs of `text` that the note already contains (ignoring whitespace and case),
    /// and repeats within `text` itself. Containment, not equality: a note's first paragraph is
    /// usually "# Title" plus its first line, so an exact paragraph match would miss it.
    static func dropParagraphs(of text: String, alreadyIn existing: String) -> String {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        var haystack = norm(existing)
        var kept: [String] = []
        for para in text.components(separatedBy: "\n\n") {
            let key = norm(para)
            if key.isEmpty || (key.count >= 12 && haystack.contains(key)) || haystack.hasSuffix(key) { continue }
            haystack += " " + key
            kept.append(para.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return kept.joined(separator: "\n\n")
    }

    private static func stripLeadingHeading(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleFromPath(_ p: String) -> String { ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
}
