import Foundation

/// An MCP server (stdio, newline-delimited JSON-RPC) that owns no tools. It relays `tools/list` and
/// `tools/call` to the Offload process that started the task, over a `ToolHost` socket, and returns
/// what that process answers. `claude` runs it as a child (`offload mcp --host <socket>`); the token
/// arrives in the environment (`OFFLOAD_HOST_TOKEN`), never on the command line.
///
/// Nothing here can run a tool, change a permission or approve anything: the process on the other end
/// of the socket decides, with its own policy, prompts and hooks.
public final class MCPBridge: @unchecked Sendable {
    private let client: ToolHostClient

    public init(client: ToolHostClient) { self.client = client }

    public convenience init(socketPath: String, token: String) throws {
        try self.init(client: ToolHostClient(socketPath: socketPath, token: token))
    }

    public func runStdio() async {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let response = await handle(line) { FileHandle.standardOutput.write(Data((response + "\n").utf8)) }
        }
    }

    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MCPServer.error(id: NSNull(), code: -32700, message: "Parse error")
        }
        let id = obj["id"]
        guard let method = obj["method"] as? String else { return id == nil ? nil : MCPServer.error(id: id!, code: -32600, message: "Invalid Request") }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            guard let id else { return nil }
            return MCPServer.result(id: id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": MCPServer.serverName, "version": MCPServer.serverVersion],
            ])
        case "ping":
            return id.map { MCPServer.result(id: $0, [:]) } ?? nil
        case "tools/list":
            guard let id else { return nil }
            do {
                let tools = try await blocking { try self.client.list() }
                let listed = tools.map { t -> [String: Any] in
                    let readOnly = (t["tier"] as? String) == AccessTier.readOnly.rawValue
                    return [
                        "name": t["name"] as? String ?? "", "description": t["description"] as? String ?? "",
                        "inputSchema": t["inputSchema"] ?? ["type": "object", "properties": [String: Any]()],
                        "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false],
                    ]
                }
                return MCPServer.result(id: id, ["tools": listed])
            } catch { return MCPServer.error(id: id, code: -32603, message: "\(error)") }
        case "tools/call":
            guard let id else { return nil }
            guard let name = params["name"] as? String else { return MCPServer.error(id: id, code: -32602, message: "Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let r = try await blocking { try self.client.call(name, arguments: arguments) }
                var content: [[String: Any]] = [["type": "text", "text": r.text]]
                if let image = r.image { content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": image.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg"]) }
                return MCPServer.result(id: id, ["content": content, "isError": r.isError])
            } catch {
                // The app is gone or the task was stopped: say so as a tool error, so the model can finish.
                return MCPServer.result(id: id, ["content": [["type": "text", "text": "Offload is not reachable: \(error)"]], "isError": true])
            }
        default:
            if method.hasPrefix("notifications/") { return nil }
            return id.map { MCPServer.error(id: $0, code: -32601, message: "Method not found: \(method)") } ?? nil
        }
    }

    /// The socket calls block (an approval can take as long as the user does), so they run off the cooperative pool.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try work() }) }
        }
    }
}
