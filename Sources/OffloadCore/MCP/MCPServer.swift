import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0), exposing the
/// knowledge base to MCP clients such as Claude Desktop and Claude Code. Runs locally, as a child
/// process of the client: nothing is uploaded anywhere and there is no hosted relay.
///
/// It offers four read-only tools and the notes themselves as resources. Every tool call goes
/// through the same `ToolDispatcher` as the assistant's own calls, under a read-only policy, so a
/// client can never reach a tool that changes anything, and everything returned is redacted (the
/// client is a model this app does not control).
public final class MCPServer: @unchecked Sendable {
    public static let serverName = "offload"
    public static let serverVersion = "0.2.0"
    static let maxFilesPerCall = MemoryTools.maxFilesPerCall
    static let maxResponseChars = MemoryTools.maxResponseChars
    static let maxListedResources = 1_000
    static let noteURIPrefix = "offload://note/"
    /// What this server offers; a test keeps it equal to the registry, because the Claude command-line
    /// model allows exactly these (and nothing else) when it is wired to this server.
    public static let toolNames = ["get_structure", "get_files", "search_memory", "read_item"]

    private let memory: MemoryService
    let registry: ToolRegistry
    private let dispatcher: ToolDispatcher

    public init(memory: MemoryService, observer: (@Sendable (ToolEvent) -> Void)? = nil) {
        self.memory = memory
        let registry = ToolRegistry([
            MemoryTools.getStructure(memory), MemoryTools.getFiles(memory),
            MemoryTools.searchMemory(memory), MemoryTools.readItem(memory),
        ])
        self.registry = registry
        // Chunks were redacted at ingestion, but notes (model-written or edited by the user) were
        // not: everything returned passes through the same scan as text sent to a hosted model.
        self.dispatcher = ToolDispatcher(registry: registry, policy: .readOnly, hooks: [OutputRedactionHook()], observer: observer)
    }

    // MARK: - Transport

    /// Reads requests from stdin until EOF. Diagnostics go to stderr only: stdout is the protocol.
    public func runStdio() async {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let response = await handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Handles one JSON-RPC message; returns the response line, or nil for notifications.
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32700, message: "Parse error")
        }
        let id = obj["id"]            // number, string, or absent (notification)
        guard let method = obj["method"] as? String else {
            return id == nil ? nil : Self.error(id: id!, code: -32600, message: "Invalid Request")
        }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            guard let id else { return nil }
            let version = params["protocolVersion"] as? String ?? "2025-03-26"
            return Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
                "instructions": "A personal knowledge base about the user. Call get_structure first (the folder and file names are the index and the README is a portrait of the user), then get_files for specific notes, or search_memory to find things by meaning or exact term. read_item returns the original text behind a search result. The notes are also available as resources.",
            ])
        case "ping":
            return id.map { Self.result(id: $0, [:]) } ?? nil
        case "tools/list":
            return id.map { Self.result(id: $0, ["tools": Self.toolList(registry.specs)]) } ?? nil
        case "tools/call":
            guard let id else { return nil }
            guard let name = params["name"] as? String else { return Self.error(id: id, code: -32602, message: "Missing tool name") }
            let args = JSONValue(any: params["arguments"] as? [String: Any] ?? [:]).asObject ?? [:]
            let result = await dispatcher.dispatch(ToolCall(name: name, arguments: args))
            return Self.result(id: id, ["content": [["type": "text", "text": result.output.text]], "isError": result.output.isError])
        case "resources/list":
            guard let id else { return nil }
            do { return Self.result(id: id, ["resources": try noteResources()]) }
            catch { return Self.error(id: id, code: -32603, message: "Could not list notes: \(error)") }
        case "resources/templates/list":
            return id.map { Self.result(id: $0, ["resourceTemplates": [[String: Any]]()]) } ?? nil
        case "resources/read":
            guard let id else { return nil }
            guard let uri = params["uri"] as? String else { return Self.error(id: id, code: -32602, message: "Missing uri") }
            do {
                guard let text = try readNote(uri: uri) else { return Self.error(id: id, code: -32002, message: "Resource not found: \(uri)") }
                return Self.result(id: id, ["contents": [["uri": uri, "mimeType": "text/markdown", "text": PIIScan.redact(text).text]]])
            } catch { return Self.error(id: id, code: -32603, message: "Could not read the note: \(error)") }
        default:
            if method.hasPrefix("notifications/") { return nil }
            return id.map { Self.error(id: $0, code: -32601, message: "Method not found: \(method)") } ?? nil
        }
    }

    // MARK: - Tools

    static func toolList(_ specs: [ToolSpec]) -> [[String: Any]] {
        specs.map { spec in
            [
                "name": spec.name,
                "description": spec.description,
                "inputSchema": spec.inputSchema.anyValue,
                "annotations": ["readOnlyHint": spec.tier == .readOnly, "destructiveHint": false, "openWorldHint": false],
            ]
        }
    }

    static func suggestions(for query: String, in paths: [String]) -> [String] { MemoryTools.suggestions(for: query, in: paths) }

    // MARK: - Resources

    private func noteResources() throws -> [[String: Any]] {
        let notes = try memory.workspace.readAll()
        return notes.keys.sorted().prefix(Self.maxListedResources).map { path in
            [
                "uri": Self.noteURI(path),
                "name": path,
                "title": VaultOps.title(of: notes[path] ?? "", path: path),
                "mimeType": "text/markdown",
            ]
        }
    }

    private func readNote(uri: String) throws -> String? {
        guard uri.hasPrefix(Self.noteURIPrefix), let path = String(uri.dropFirst(Self.noteURIPrefix.count)).removingPercentEncoding else { return nil }
        return try memory.note(path: path)
    }

    static func noteURI(_ path: String) -> String {
        noteURIPrefix + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    // MARK: - JSON-RPC helpers

    static func result(id: Any, _ result: [String: Any]) -> String { encode(["jsonrpc": "2.0", "id": id, "result": result]) }
    static func error(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    private static func encode(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
