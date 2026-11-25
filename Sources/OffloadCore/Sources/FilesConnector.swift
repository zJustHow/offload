import Foundation
import PDFKit

/// Reads documents, notes and images from folders the user chose.
///
/// Text, Markdown and HTML are read directly, PDFs through PDFKit, and images through Vision's
/// text recognition (the built-in on-device language model is text-only, so a screenshot becomes
/// its recognized text; an image with no readable text is not worth keeping).
public struct FilesConnector: Connector {
    public let root: URL
    public let kind: SourceKind = .file
    public var bucket: String { "files:" + root.path }
    public let listsAllItems = true
    public var maxFileBytes = 25 * 1024 * 1024
    public var maxTextChars = 200_000

    static let authoredExtensions: Set<String> = ["md", "markdown", "txt", "org", "text"]
    static let savedTextExtensions: Set<String> = ["html", "htm", "pdf", "csv", "json"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"]
    static let skippedDirectories: Set<String> = ["node_modules", ".git", "Library", "build", "DerivedData", ".build", "__pycache__", "venv", ".venv"]

    /// `root` with every symlink resolved. A directory walk reports items by their real path
    /// (`/private/var/...` for a folder chosen as `/var/...`), and so does FSEvents; item keys are
    /// these real paths, so a path from either source maps to the same item.
    let realRoot: String

    public init(root: URL) {
        self.root = root
        self.realRoot = Self.realPath(root.path)
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func list() async throws -> [WorkItemRef] { try scan() }

    /// Synchronous on purpose: `FileManager.DirectoryEnumerator` may not be iterated from async code.
    func scan() throws -> [WorkItemRef] {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ConnectorError.unreadable("folder not found: \(root.path)") }
        return try walk(root)
    }

    static let fileKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]

    private func walk(_ start: URL) throws -> [WorkItemRef] {
        let keys = Self.fileKeys
        guard let walker = FileManager.default.enumerator(
            at: start, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw ConnectorError.unreadable(start.path) }

        var refs: [WorkItemRef] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, let ref = fileRef(url, values) else { continue }
            refs.append(ref)
        }
        return refs
    }

    /// The ref for one regular file, or nil when its type or size makes it uninteresting.
    private func fileRef(_ url: URL, _ values: URLResourceValues?) -> WorkItemRef? {
        let ext = url.pathExtension.lowercased()
        let isImage = Self.imageExtensions.contains(ext)
        guard Self.authoredExtensions.contains(ext) || Self.savedTextExtensions.contains(ext) || isImage else { return nil }
        let size = values?.fileSize ?? 0
        if size == 0 || size > maxFileBytes { return nil }
        let mtime = values?.contentModificationDate
        return WorkItemRef(
            key: url.path,
            fingerprint: "\(size)-\(Int(mtime?.timeIntervalSince1970 ?? 0))",
            date: mtime, title: url.deletingPathExtension().lastPathComponent, uri: url.path,
            trust: Self.authoredExtensions.contains(ext) ? .authored : .saved)
    }
}

// MARK: - Scoped reads (live sync)

extension FilesConnector: PathScopedConnector {
    public func scopedPath(for path: String) -> String? {
        // Either the folder as the user chose it, or its real path as the file system reports it.
        guard let rel = Self.relative(path, to: realRoot) ?? Self.relative(path, to: root.path) else { return nil }
        let parts = rel.split(separator: "/").map(String.init)
        // Mirrors what the enumerator skips: hidden files and folders, and the folders in
        // `skippedDirectories` (plus everything beneath them).
        if parts.contains(where: { $0.hasPrefix(".") || Self.skippedDirectories.contains($0) }) { return nil }
        return parts.reduce(URL(fileURLWithPath: realRoot)) { $0.appendingPathComponent($1) }.path
    }

    public func refs(under path: String) throws -> [WorkItemRef] {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ConnectorError.unreadable("folder not found: \(root.path)") }
        guard let scoped = scopedPath(for: path) else { return [] }
        let url = URL(fileURLWithPath: scoped)
        // A full scan never reaches anything behind a symlink or inside a package (a .app, .rtfd...).
        for ancestor in Self.ancestors(of: url, below: URL(fileURLWithPath: realRoot)) {
            let v = try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey])
            if v?.isSymbolicLink == true || v?.isPackage == true { return [] }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        let values = try? url.resourceValues(forKeys: Set(Self.fileKeys + [.isPackageKey]))
        if values?.isSymbolicLink == true { return [] }
        if isDirectory.boolValue {
            if url.path != realRoot, values?.isPackage == true { return [] }
            return try walk(url)
        }
        guard values?.isRegularFile == true else { return [] }
        return fileRef(url, values).map { [$0] } ?? []
    }

    /// `path` relative to `base` ("" for the base itself), or nil when it is not inside it.
    private static func relative(_ path: String, to base: String) -> String? {
        if path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// The folders between `root` (exclusive) and `url` (exclusive).
    private static func ancestors(of url: URL, below root: URL) -> [URL] {
        var out: [URL] = []
        var current = url.deletingLastPathComponent()
        while current.path.count > root.path.count, current.path.hasPrefix(root.path) {
            out.append(current)
            current = current.deletingLastPathComponent()
        }
        return out
    }
}

extension FilesConnector {
    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        let url = URL(fileURLWithPath: ref.key)
        let ext = url.pathExtension.lowercased()
        let text: String
        if Self.imageExtensions.contains(ext) {
            text = try OCR.recognize(url: url)
        } else if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ConnectorError.unreadable("not a readable PDF") }
            text = doc.string ?? ""
        } else if ext == "html" || ext == "htm" {
            text = HTMLText.strip(try Self.readString(url))
        } else {
            text = try Self.readString(url)
        }
        return .text(String(text.prefix(maxTextChars)))
    }

    static func readString(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        // GB18030 covers legacy Chinese text files that are not UTF-8.
        let gb = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        if let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(gb))) { return s }
        throw ConnectorError.unreadable("unknown text encoding")
    }
}
