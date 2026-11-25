import Foundation

/// A one-time snapshot of how the user writes, taken from messages they sent. Stored as a hidden
/// file next to the notes (so it is editable, never shown as a note, never indexed or shared as
/// knowledge) and used only by the reply drafter.
public enum WritingStyle {
    static let fileName = ".writingstyle.md"

    public static func url(in workspace: VaultWorkspace) -> URL { workspace.root.appendingPathComponent(fileName) }

    public static func read(in workspace: VaultWorkspace) -> String? {
        guard let s = try? String(contentsOf: url(in: workspace), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Picks up to `limit` of the user's own chat lines, spread across conversations, skipping
    /// very short, very long and duplicate lines. Nil when there is not enough material.
    public static func samples(from store: KnowledgeStore, limit: Int = 40) throws -> [String]? {
        let chunks = try store.db.query(
            "SELECT c.item_id, c.text FROM chunks c JOIN items i ON i.id = c.item_id WHERE i.kind = 'chat' AND i.verdict = 'survivor' ORDER BY c.id", []
        ) { ($0.text(0), $0.text(1)) }
        var byChat: [String: [String]] = [:]
        var seen = Set<String>()
        for (item, text) in chunks {
            for line in text.components(separatedBy: "\n") where line.hasPrefix("Me: ") {
                let body = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                guard (12...280).contains(body.count), !body.contains("[REDACTED"), seen.insert(body.lowercased()).inserted else { continue }
                byChat[item, default: []].append(body)
            }
        }
        // Round-robin over chats so one talkative conversation does not define the voice.
        var picked: [String] = []
        var index = 0
        let keys = byChat.keys.sorted()
        while picked.count < limit, !keys.isEmpty {
            var added = false
            for k in keys where index < byChat[k]!.count && picked.count < limit { picked.append(byChat[k]![index]); added = true }
            if !added { break }
            index += 1
        }
        return picked.count >= 8 ? picked : nil
    }

    /// Writes the snapshot once. An existing file (including one the user emptied on purpose) is
    /// never overwritten. Returns true when a file was written.
    @discardableResult
    public static func createIfNeeded(workspace: VaultWorkspace, store: KnowledgeStore) throws -> Bool {
        let target = url(in: workspace)
        if FileManager.default.fileExists(atPath: target.path) { return false }
        guard let samples = try samples(from: store) else { return false }
        try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
        let body = "# Writing examples\n\nMessages you sent, used to match your voice when drafting replies. Edit freely.\n\n" + samples.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try body.write(to: target, atomically: true, encoding: .utf8)
        return true
    }
}
