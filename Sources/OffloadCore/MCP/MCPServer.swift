import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0), exposing the
/// knowledge base to MCP clients such as Claude Desktop and Claude Code. Runs locally, as a child
/// process of the client: nothing is uploaded anywhere and there is no hosted relay.
///
/// The client is, by definition, a model outside this app's control, so every call is treated as a
/// hosted audience: the egress policy decides whether raw-text snippets may be returned.
public final class MCPServer: @unchecked Sendable {
    public static let serverName = "offload"
    public static let serverVersion = "0.1.0"
    static let audience = ModelCapabilities(vision: false, contextChars: 200_000, isLocal: false)
    static let maxFilesPerCall = 50
    static let maxResponseChars = 256_000

    private let memory: MemoryService

    public init(memory: MemoryService) { self.memory = memory }

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
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
                "instructions": "A personal knowledge base about the user. Call get_structure first (the folder and file names are the index and the README is a portrait of the user), then get_files for specific notes, or search_memory to find things by meaning or exact term.",
            ])
        case "ping":
            return id.map { Self.result(id: $0, [:]) } ?? nil
        case "tools/list":
            return id.map { Self.result(id: $0, ["tools": Self.tools]) } ?? nil
        case "tools/call":
            guard let id else { return nil }
            guard let name = params["name"] as? String else { return Self.error(id: id, code: -32602, message: "Missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await callTool(name, args)
            return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            if method.hasPrefix("notifications/") { return nil }
            return id.map { Self.error(id: $0, code: -32601, message: "Method not found: \(method)") } ?? nil
        }
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        [
            "name": "get_structure",
            "description": "Get the user's personal knowledge base: the folder tree plus the README portrait of who they are. Call this first whenever personal context would help (who the user is, their projects, people, plans, preferences).",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "get_files",
            "description": "Fetch notes by vault-relative path exactly as shown by get_structure, e.g. [\"README.md\", \"Work/Acme.md\"]. At most 50 per call; fetch only what you need.",
            "inputSchema": ["type": "object", "properties": ["paths": ["type": "array", "items": ["type": "string"]]], "required": ["paths"]],
        ],
        [
            "name": "search_memory",
            "description": "Search the knowledge base by meaning and by exact terms (names, ids, amounts). Returns the best-matching notes. Use this when you do not know which note holds an answer.",
            "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 10]], "required": ["query"]],
        ],
    ]

    func callTool(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
        do {
            switch name {
            case "get_structure":
                return (try memory.structure(), false)
            case "get_files":
                return (try files(args["paths"]), false)
            case "search_memory":
                guard let q = args["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return ("query is required", true) }
                var opts = SearchOptions()
                opts.limit = min(10, max(1, (args["limit"] as? Int) ?? 5))
                let hits = try await memory.search(q, options: opts, audience: Self.audience)
                return (MemoryService.render(hits), false)
            default:
                return ("Unknown tool: \(name)", true)
            }
        } catch {
            return ("Error: \(error)", true)
        }
    }

    private func files(_ raw: Any?) throws -> String {
        var paths: [String] = []
        if let list = raw as? [String] { paths = list }
        else if let s = raw as? String {
            // Models sometimes send a JSON array as a string, or a comma-joined string.
            if let data = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [String] { paths = arr }
            else { paths = [s] }
        }
        paths = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return "(no paths given)" }

        var notices: [String] = []
        if paths.count > Self.maxFilesPerCall {
            notices.append("(only the first \(Self.maxFilesPerCall) of \(paths.count) paths were fetched; call again for the rest)")
            paths = Array(paths.prefix(Self.maxFilesPerCall))
        }
        let all = try memory.workspace.readAll()
        var chunks: [String] = []
        var size = 0
        for p in paths {
            let text: String
            if let found = memory.resolveNote(p, in: all) { text = "=== \(found.path) ===\n\(found.body)" }
            else {
                let guesses = Self.suggestions(for: p, in: Array(all.keys))
                text = "=== \(p) ===\n(not found)" + (guesses.isEmpty ? "" : " Did you mean: " + guesses.joined(separator: ", ") + "?")
            }
            if size + text.count > Self.maxResponseChars {
                notices.append("(response truncated at the size cap; call get_files again with fewer paths)")
                break
            }
            size += text.count
            chunks.append(text)
        }
        return (chunks + notices).joined(separator: "\n\n")
    }

    static func suggestions(for query: String, in paths: [String]) -> [String] {
        let q = ((query as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        guard !q.isEmpty else { return [] }
        return paths.filter { p in
            let stem = ((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            return stem.contains(q) || q.contains(stem)
        }.sorted().prefix(3).map { $0 }
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
