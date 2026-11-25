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

    public init(root: URL) { self.root = root }

    public func list() async throws -> [WorkItemRef] { try scan() }

    /// Synchronous on purpose: `FileManager.DirectoryEnumerator` may not be iterated from async code.
    func scan() throws -> [WorkItemRef] {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ConnectorError.unreadable("folder not found: \(root.path)") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw ConnectorError.unreadable(root.path) }

        var refs: [WorkItemRef] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let isImage = Self.imageExtensions.contains(ext)
            guard Self.authoredExtensions.contains(ext) || Self.savedTextExtensions.contains(ext) || isImage else { continue }
            let size = values?.fileSize ?? 0
            if size == 0 || size > maxFileBytes { continue }
            let mtime = values?.contentModificationDate
            refs.append(WorkItemRef(
                key: url.path,
                fingerprint: "\(size)-\(Int(mtime?.timeIntervalSince1970 ?? 0))",
                date: mtime, title: url.deletingPathExtension().lastPathComponent, uri: url.path,
                trust: Self.authoredExtensions.contains(ext) ? .authored : .saved))
        }
        return refs
    }

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
