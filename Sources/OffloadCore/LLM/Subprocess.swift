import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Lets a caller stop a program that `Subprocess.run` started (when the task that awaits it is cancelled).
public final class ProcessCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}

    func attach(_ p: Process) {
        lock.lock(); process = p; let already = cancelled; lock.unlock()
        if already { p.terminate() }
    }

    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        p?.terminate()
    }
}

/// Runs an external program without a shell (arguments are an array, so nothing a prompt or a
/// path contains can be interpreted as a command), feeding it stdin and collecting both output
/// streams concurrently so a chatty child can never deadlock on a full pipe.
public enum Subprocess {
    public static func run(
        executable: URL, arguments: [String], stdin: Data? = nil, workingDirectory: URL? = nil,
        environment: [String: String]? = nil, timeout: TimeInterval = 300, canceller: ProcessCanceller? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                if let workingDirectory { p.currentDirectoryURL = workingDirectory }
                if let environment { p.environment = environment }
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                canceller?.attach(p)

                var out = Data(), err = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async {
                    if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                    try? inPipe.fileHandleForWriting.close()
                }

                let timedOut = Flag()
                let killer = DispatchWorkItem {
                    timedOut.set()
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                group.wait()
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: out, stderr: err, timedOut: timedOut.isSet))
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// Finds a command-line tool: `PATH` first, then the places installers usually put it.
    public static func locate(_ name: String, extraDirectories: [String] = []) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.claude/local", "\(home)/.bun/bin"] + extraDirectories
        for d in dirs {
            let path = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// A private, empty working directory for one call: the tool starts with nothing to read.
    static func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}
