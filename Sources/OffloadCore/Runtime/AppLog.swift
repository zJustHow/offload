import Foundation
import os

/// A small diagnostic log: every line goes to the unified system log (Console.app, subsystem
/// `dev.offload`) and to `logs/app.log`, which "Show log files" opens. It records events,
/// counts and error text, never note contents or message excerpts. The file stays under ~1 MB by
/// rotating once to `app.log.1`.
public final class AppLog: @unchecked Sendable {
    public enum Level: String, Sendable { case info = "INFO", warning = "WARN", error = "ERROR" }

    public static let shared = AppLog()
    static let maxBytes = 512 * 1024

    private let logger = Logger(subsystem: "dev.offload", category: "app")
    private let queue = DispatchQueue(label: "dev.offload.log")
    private var directory: URL?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    public init() {}

    /// Where `app.log` lives. Until this is called, lines go only to the system log.
    public func configure(directory: URL) { queue.sync { self.directory = directory } }

    public func info(_ message: String) { write(.info, message) }
    public func warning(_ message: String) { write(.warning, message) }
    public func error(_ message: String) { write(.error, message) }

    /// Blocks until everything written so far is on disk (for tests and for quitting).
    public func flush() { queue.sync {} }

    func write(_ level: Level, _ message: String) {
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = "\(formatter.string(from: Date())) \(level.rawValue) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        queue.async { [self] in
            guard let directory else { return }
            let fm = FileManager.default
            let file = directory.appendingPathComponent("app.log")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > Self.maxBytes {
                    let old = directory.appendingPathComponent("app.log.1")
                    try? fm.removeItem(at: old)
                    try fm.moveItem(at: file, to: old)
                }
                if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                logger.error("could not write app.log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
