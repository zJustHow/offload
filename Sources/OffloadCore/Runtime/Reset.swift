import Foundation

/// Removing what Offload has stored. Nothing here ever deletes the user's own files: the knowledge
/// base is moved to the Trash, and source files are never touched.
public enum Reset {
    public struct Options: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The search index, read-state and prepared suggestions (everything is rebuilt by the next run).
        public static let index = Options(rawValue: 1 << 0)
        public static let settings = Options(rawValue: 1 << 1)
        /// The knowledge base folder (to the Trash).
        public static let knowledgeBase = Options(rawValue: 1 << 2)
        /// Stored API keys, the Google sign-in, and anything else in the Keychain.
        public static let secrets = Options(rawValue: 1 << 3)
        public static let schedule = Options(rawValue: 1 << 4)
        public static let logs = Options(rawValue: 1 << 5)
        public static let everything: Options = [.index, .settings, .knowledgeBase, .secrets, .schedule, .logs]
    }

    static let keychainAccounts = ["google-oauth", "triage-app", "knowledge-app", "assistant-app", "embedding",
                                   "triage-openai", "knowledge-openai", "assistant-openai", "triage-anthropic", "knowledge-anthropic", "assistant-anthropic"]

    public static func perform(
        _ options: Options, paths: AppPaths, vault: URL,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        removeSchedule: () throws -> Void = { try LaunchAgent.uninstall() },
        removeSecret: (String) -> Void = { Keychain.delete(account: $0) }
    ) throws {
        let fm = FileManager.default
        if options.contains(.index) {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: paths.database.path + suffix) }
            for name in ["gmail-metadata.json", "history.jsonl"] { try? fm.removeItem(at: paths.support.appendingPathComponent(name)) }
        }
        if options.contains(.settings) { try? fm.removeItem(at: paths.config) }
        if options.contains(.knowledgeBase), fm.fileExists(atPath: vault.path) { try trash(vault) }
        if options.contains(.secrets) { keychainAccounts.forEach(removeSecret) }
        if options.contains(.schedule) { try removeSchedule() }
        if options.contains(.logs) { try? fm.removeItem(at: paths.logs) }
    }
}
