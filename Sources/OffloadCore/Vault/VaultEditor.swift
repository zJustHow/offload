import Foundation

public enum VaultEditorError: Error, CustomStringConvertible {
    case invalidName, readOnly, notFound, exists
    public var description: String {
        switch self {
        case .invalidName: return "That name can't be used for a note."
        case .readOnly: return "The Overview is written by Offload and can't be edited."
        case .notFound: return "That note no longer exists."
        case .exists: return "A note with that name already exists."
        }
    }
}

/// The user's own edits to the knowledge base. Notes are plain files, so editing means writing the
/// file and keeping the search index in step. An edit changes the vault's fingerprint, which is what
/// makes a concurrent overnight update abort its swap rather than overwrite the edit.
public final class VaultEditor: @unchecked Sendable {
    private let workspace: VaultWorkspace
    private let store: KnowledgeStore
    private let indexer: Indexer
    private let trash: @Sendable (URL) throws -> Void

    public init(workspace: VaultWorkspace, store: KnowledgeStore, indexer: Indexer,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.workspace = workspace; self.store = store; self.indexer = indexer; self.trash = trash
    }

    /// Characters that break file names or links are replaced; the result is never empty.
    public static func fileName(for title: String) -> String? {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^").union(.controlCharacters)
        let cleaned = title.components(separatedBy: bad).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }

    /// Creates `folder/title.md` seeded with a heading. Returns the new note's path.
    @discardableResult
    public func create(folder: String, title: String) async throws -> String {
        guard let name = Self.fileName(for: title) else { throw VaultEditorError.invalidName }
        let relative = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty ? "Notes/\(name).md" : "\(folder)/\(name).md"
        guard let path = VaultOps.normalizePath(relative), path != "README.md" else { throw VaultEditorError.invalidName }
        let existing = try workspace.readAll()
        if existing[path] != nil || existing.keys.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) { throw VaultEditorError.exists }
        let body = "# \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        try write(body, to: path)
        try await indexer.indexNote(path: path, body: body)
        return path
    }

    /// Saves an edited note. Atomic, so a crash never leaves a half-written file.
    public func save(path: String, body: String) async throws {
        guard let safe = VaultOps.normalizePath(path) else { throw VaultEditorError.invalidName }
        if safe == "README.md" { throw VaultEditorError.readOnly }
        let url = workspace.root.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultEditorError.notFound }
        try write(body, to: safe)
        try await indexer.indexNote(path: safe, body: body)
    }

    /// Writes a note whose content has already been validated (an edit the user approved) and
    /// indexes it. Creating and replacing are the same call; `README.md` is never written.
    public func put(path: String, body: String) async throws {
        guard let safe = VaultOps.normalizePath(path) else { throw VaultEditorError.invalidName }
        if safe == "README.md" { throw VaultEditorError.readOnly }
        try write(body, to: safe)
        try await indexer.indexNote(path: safe, body: body)
    }

    /// Moves a note to the Trash (recoverable) and forgets it.
    public func delete(path: String) throws {
        guard let safe = VaultOps.normalizePath(path) else { throw VaultEditorError.invalidName }
        if safe == "README.md" { throw VaultEditorError.readOnly }
        let url = workspace.root.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultEditorError.notFound }
        try trash(url)
        try store.deleteNote(path: safe)
    }

    private func write(_ body: String, to path: String) throws {
        try workspace.write([path: body], paths: [path], into: workspace.root)
    }
}
