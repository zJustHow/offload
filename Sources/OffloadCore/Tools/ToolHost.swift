import Darwin
import Foundation

/// Lets another program (the `claude` command, through a small MCP bridge) call the assistant's tools
/// **in this process**.
///
/// The tools are not copied into a separate server. They stay here, behind the same `ToolDispatcher`
/// the assistant's own loop uses, so permission rules, approval prompts (the notch), hooks, redaction,
/// the audit log, the screen permissions macOS gave this app, and the "this looks irreversible" backstop
/// all still apply. The bridge is a thin relay: it asks, this process decides.
///
/// Transport: a Unix socket in a private folder (mode 0700; the socket itself 0600) that exists only for
/// one task, with a random token the first message must carry. Messages are one JSON object per line.
public final class ToolHost: @unchecked Sendable {
    public struct Endpoint: Sendable, Equatable {
        public var socketPath: String
        public var token: String
    }

    private let dispatcher: ToolDispatcher
    private let exposed: Set<String>
    /// Names as the bridge sees them -> the registry's name. Providers cap tool names, and the command adds a prefix.
    private var aliasToName: [String: String] = [:]
    private var nameToAlias: [String: String] = [:]

    /// Called before a call is dispatched / after it finished. The assistant uses them for its progress events.
    public var beforeCall: (@Sendable (ToolCall) -> Void)?
    public var afterCall: (@Sendable (ToolResult) -> Void)?
    /// A reason to refuse the call outright (a step limit, a user who has said no twice). Nil lets it through.
    public var gate: (@Sendable (ToolCall) -> String?)?

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var directory: URL?
    private var token = ""
    private var running = false
    private var clients: Set<Int32> = []

    static let maxAliasLength = 48
    /// Short, because a Unix socket's address is limited to about 100 bytes (the per-user temporary folder is too long).
    static var parent = "/tmp"
    static let folderPrefix = "offload-h"

    /// A task that was killed (not stopped) leaves its folder behind. Nothing secret is in it and nothing listens,
    /// but it is tidier to sweep what is clearly abandoned: older than any task can last.
    static func removeStaleFolders(olderThan age: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent) else { return }
        for name in names where name.hasPrefix(folderPrefix) {
            let url = URL(fileURLWithPath: parent).appendingPathComponent(name)
            if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, Date().timeIntervalSince(modified) > age {
                try? fm.removeItem(at: url)
            }
        }
    }

    public init(dispatcher: ToolDispatcher, exposing names: Set<String>) {
        self.dispatcher = dispatcher
        self.exposed = names
        for name in names.sorted() {
            let alias = Self.alias(for: name)
            aliasToName[alias] = name; nameToAlias[name] = alias
        }
    }

    /// The command prefixes every tool with `mcp__offload__` and providers allow 64 characters in all, so a long
    /// name (an external server's tool already carries its own prefix) is shortened, with a hash to keep it unique.
    static func alias(for name: String) -> String {
        guard name.count > maxAliasLength else { return name }
        return String(name.prefix(maxAliasLength - 9)) + "_" + String(Hashing.sha256Hex(name).prefix(8))
    }

    /// Names the command should be allowed to call, as the bridge lists them.
    public var aliases: [String] { exposed.sorted().compactMap { nameToAlias[$0] } }

    // MARK: Lifecycle

    public func start() throws -> Endpoint {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw LLMError.unavailable("the tool host is already running") }
        Self.removeStaleFolders()

        let dir = URL(fileURLWithPath: Self.parent, isDirectory: true).appendingPathComponent("\(Self.folderPrefix)\(Hashing.stableID(UUID().uuidString).prefix(10))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("s").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: dir); throw LLMError.unavailable("could not create a socket (errno \(errno))") }
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno; close(fd); try? FileManager.default.removeItem(at: dir)
            throw LLMError.unavailable("could not listen on the tool socket (errno \(code))")
        }
        chmod(path, 0o600)

        listener = fd; directory = dir; running = true
        token = (0..<4).map { _ in String(UInt64.random(in: 0...UInt64.max), radix: 16) }.joined()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        return Endpoint(socketPath: path, token: token)
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let dir = directory, open = clients
        listener = -1; directory = nil; clients = []
        lock.unlock()
        guard wasRunning else { return }
        // The accept loop notices `running` is false within a moment and closes the listening socket itself.
        for c in open { shutdown(c, SHUT_RDWR) }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    deinit { stop() }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    // MARK: Serving

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while isRunning {
            // Wake up regularly: closing a listening socket does not reliably interrupt a blocked accept on macOS.
            guard poll(&watched, 1, 200) > 0, watched.revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            lock.lock(); let ok = running; if ok { clients.insert(client) }; lock.unlock()
            if !ok { close(client); return }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let writeLock = NSLock()
        init(_ fd: Int32) { self.fd = fd }
        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            writeLock.lock(); defer { writeLock.unlock() }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
    }

    private func serve(_ fd: Int32) {
        let connection = Connection(fd)
        defer { lock.lock(); clients.remove(fd); lock.unlock(); close(fd) }
        var buffer = Data()
        var authenticated = false
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                if !authenticated {
                    // The first message must carry the token; anything else ends the connection without an answer.
                    guard (object["hello"] as? String) == token else { return }
                    authenticated = true
                    connection.send(["hello": "ok"])
                    continue
                }
                handle(object, on: connection)
            }
        }
    }

    private func handle(_ request: [String: Any], on connection: Connection) {
        let id = request["id"] ?? NSNull()
        switch request["op"] as? String {
        case "list":
            let specs = dispatcher.registry.specs.filter { exposed.contains($0.name) }.map { spec -> [String: Any] in
                let model = spec.nativeDefinition()
                return ["name": nameToAlias[spec.name] ?? spec.name, "description": spec.description, "inputSchema": model.inputSchema.anyValue, "tier": spec.tier.rawValue]
            }
            connection.send(["id": id, "tools": specs])
        case "call":
            let alias = request["name"] as? String ?? ""
            let arguments = JSONValue(any: request["arguments"] as? [String: Any] ?? [:]).asObject ?? [:]
            Task.detached { [self] in
                connection.send(["id": id].merging(await perform(alias: alias, arguments: arguments)) { _, new in new })
            }
        default:
            connection.send(["id": id, "text": "unknown request", "isError": true])
        }
    }

    private func perform(alias: String, arguments: JSONObject) async -> [String: Any] {
        guard let name = aliasToName[alias] else { return ["text": "unknown tool \"\(alias)\"", "isError": true] }
        let call = ToolCall(name: name, arguments: arguments)
        if let reason = gate?(call) { return ["text": reason, "isError": true] }
        beforeCall?(call)
        let result = await dispatcher.dispatch(call)
        afterCall?(result)
        var reply: [String: Any] = ["text": result.output.text, "isError": result.output.isError]
        if let image = result.output.image { reply["image"] = image.base64EncodedString() }
        return reply
    }

    // MARK: Addressing

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity - 1) }
            }
        }
        return address
    }
}

/// The other end: what the MCP bridge uses to talk to a `ToolHost`. One request at a time.
public final class ToolHostClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1

    public init(socketPath: String, token: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LLMError.unavailable("could not create a socket") }
        var address = ToolHost.address(socketPath)
        let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { let code = errno; close(fd); throw LLMError.unavailable("could not reach the Offload app (errno \(code)). Is the task still running?") }
        signal(SIGPIPE, SIG_IGN)
        try send(["hello": token])
        guard (try readObject())["hello"] as? String == "ok" else { close(fd); throw LLMError.unavailable("the Offload app refused the connection") }
    }

    deinit { close(fd) }

    /// The tools on offer: name, description, input schema, tier.
    public func list() throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let id = takeID()
        try send(["id": id, "op": "list"])
        return try readObject()["tools"] as? [[String: Any]] ?? []
    }

    public struct Result: Sendable { public var text: String; public var isError: Bool; public var image: Data? }

    public func call(_ name: String, arguments: [String: Any]) throws -> Result {
        lock.lock(); defer { lock.unlock() }
        let id = takeID()
        try send(["id": id, "op": "call", "name": name, "arguments": arguments])
        let reply = try readObject()
        return Result(text: reply["text"] as? String ?? "", isError: reply["isError"] as? Bool ?? true, image: (reply["image"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    private func takeID() -> Int { defer { nextID += 1 }; return nextID }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        if !ok { throw LLMError.unavailable("the Offload app closed the connection") }
    }

    private func readObject() throws -> [String: Any] {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { throw LLMError.badResponse("unreadable reply from the Offload app") }
                return object
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw LLMError.unavailable("the Offload app closed the connection") }
            buffer.append(chunk, count: n)
        }
    }
}
