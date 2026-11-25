import Foundation

/// The knowledge base on disk: a plain folder of Markdown notes the user can open in any editor.
/// This type owns the rules for touching it safely: edits are staged in a sibling directory and
/// swapped in atomically, and a content fingerprint detects edits the user made in the meantime.
public struct VaultWorkspace: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Offload Knowledge", isDirectory: true)
    }

    /// Every visible `.md` file under `dir` as `relative path -> contents`. Hidden files and
    /// folders (for example the writing-style snapshot) and symlinks are never read.
    public func readAll(in dir: URL? = nil) throws -> [String: String] {
        let base = (dir ?? root).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: base.path) else { return [:] }
        var out: [String: String] = [:]
        for url in try markdownFiles(in: base) {
            let rel = Self.relativePath(of: url, under: base)
            if let text = try? String(contentsOf: url, encoding: .utf8) { out[rel.precomposedStringWithCanonicalMapping] = text }
        }
        return out
    }

    /// Changes whenever any visible note is added, removed, resized or modified.
    public func fingerprint(of dir: URL? = nil) throws -> String {
        let base = (dir ?? root).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: base.path) else { return "empty" }
        var lines: [String] = []
        for url in try markdownFiles(in: base) {
            let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let rel = Self.relativePath(of: url, under: base)
            lines.append("\(rel)|\(v.fileSize ?? 0)|\(Int((v.contentModificationDate ?? .distantPast).timeIntervalSince1970))")
        }
        return Hashing.sha256Hex(lines.sorted().joined(separator: "\n"))
    }

    /// A copy of the live vault in a sibling directory (same volume, so the later swap is atomic).
    public func makeStaging() throws -> URL {
        let parent = root.deletingLastPathComponent()
        try sweepStaging()
        let staging = parent.appendingPathComponent(".offload-staging-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.copyItem(at: root, to: staging)
        } else {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        return staging
    }

    public enum WriteError: Error, CustomStringConvertible {
        case unsafePath(String)
        public var description: String { if case .unsafePath(let p) = self { return "refusing to write outside the knowledge base: \(p)" } else { return "" } }
    }

    /// Writes notes into `dir`, creating folders as needed. Each file is replaced atomically.
    /// Every path is validated before anything is written, and an unsafe path is an error, not a
    /// silent skip: a safety check that quietly drops data is worse than one that complains.
    public func write(_ notes: [String: String], paths: [String], into dir: URL) throws {
        let base = dir.resolvingSymlinksInPath()
        var plan: [(URL, String)] = []
        for path in paths {
            guard let body = notes[path] else { continue }
            guard let safe = VaultOps.normalizePath(path) else { throw WriteError.unsafePath(path) }
            // `safe` has no "..", is relative and is not hidden, so containment is structural; the
            // prefix check is a second, independent guard.
            let url = base.appendingPathComponent(safe)
            guard url.path.hasPrefix(base.path + "/") else { throw WriteError.unsafePath(path) }
            plan.append((url, body))
        }
        for (url, body) in plan {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Path of `url` relative to `base`, tolerant of `/tmp` vs `/private/tmp` style differences.
    static func relativePath(of url: URL, under base: URL) -> String {
        let full = url.resolvingSymlinksInPath().path
        return full.hasPrefix(base.path + "/") ? String(full.dropFirst(base.path.count + 1)) : url.lastPathComponent
    }

    /// Replaces the live vault with the staged one in a single atomic step.
    public func swap(staging: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            _ = try FileManager.default.replaceItemAt(root, withItemAt: staging, backupItemName: nil, options: [])
        } else {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: root)
        }
    }

    public func discard(staging: URL) { try? FileManager.default.removeItem(at: staging) }

    /// Removes staging directories left behind by a crashed run.
    func sweepStaging() throws {
        let parent = root.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [])) ?? []
        for e in entries where e.lastPathComponent.hasPrefix(".offload-staging-") { try? FileManager.default.removeItem(at: e) }
    }

    private func markdownFiles(in base: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if v?.isRegularFile == true, url.pathExtension.lowercased() == "md" { urls.append(url) }
        }
        return urls
    }
}

public enum VaultREADME {
    /// The README is a portrait (written by the model) plus a map generated by code, so the map
    /// is always accurate and every link in it resolves.
    public static func render(portrait: String, notes: [String: String]) -> String {
        var tree: [String: [(title: String, path: String, line: String)]] = [:]
        for (path, body) in notes where path != "README.md" {
            let folder = (path as NSString).deletingLastPathComponent
            tree[folder, default: []].append((VaultOps.title(of: body, path: path), path, firstLine(of: body)))
        }
        var out = "# About\n\n" + portrait.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Map\n"
        for folder in tree.keys.sorted() {
            out += "\n### \(folder)\n"
            for n in tree[folder]!.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
                out += "- [[\(n.title)]]" + (n.line.isEmpty ? "" : " — \(n.line)") + "\n"
            }
        }
        return out
    }

    /// The first sentence-like line of a note body (skipping the heading), clipped.
    public static func firstLine(of body: String, limit: Int = 110) -> String {
        for line in body.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("---") { continue }
            let clean = t.trimmingCharacters(in: CharacterSet(charactersIn: "-*> ")).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
        }
        return ""
    }
}
