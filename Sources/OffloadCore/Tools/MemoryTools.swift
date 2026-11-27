import Foundation

/// The tools that read the knowledge base. The agent and the MCP server use the same ones, so a
/// fix or a limit applies to both.
public enum MemoryTools {
    static let maxFilesPerCall = 50
    static let maxResponseChars = 256_000

    public static func searchMemory(_ memory: MemoryService) -> Tool {
        FunctionTool(ToolSpec(
            name: "search_memory",
            description: "Search what is known about the user (notes, and excerpts of their files and messages) by meaning and by exact terms (names, ids, amounts). Use it when you do not know which note holds an answer.",
            inputSchema: JSONSchema.object(["query": JSONSchema.string("what to look for"), "limit": JSONSchema.integer("how many results, 1 to 10", minimum: 1, maximum: 10)], required: ["query"]),
            promptExample: #"{"query": "...", "limit": 5}"#
        ), describe: { "search_memory(query=\($0.string("query") ?? ""))" }) { args in
            guard let q = args.string("query"), !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error("query is required") }
            var opts = SearchOptions()
            opts.limit = min(10, max(1, args.int("limit") ?? 5))
            return .ok(MemoryService.render(try await memory.search(q, options: opts)))
        }
    }

    public static func readItem(_ memory: MemoryService) -> Tool {
        FunctionTool(ToolSpec(
            name: "read_item",
            description: "The original text behind a search result (its id is shown as item=...), with its summary and where it came from.",
            inputSchema: JSONSchema.object(["id": JSONSchema.string("the item id from a search result")], required: ["id"]),
            promptExample: #"{"id": "..."}"#
        )) { args in
            guard let id = args.string("id"), let item = try memory.item(id: id) else { return .error("item not found") }
            return .ok("\(item.title) (\(item.kind.rawValue)) \(item.uri)\nSummary: \(item.summary ?? "-")\nOriginal text:\n\(item.rawText)")
        }
    }

    /// One note by path; the agent's singular counterpart of `get_files`.
    public static func readNote(_ memory: MemoryService) -> Tool {
        FunctionTool(ToolSpec(
            name: "read_note",
            description: "Read one note of the knowledge base by its path.",
            inputSchema: JSONSchema.object(["path": JSONSchema.string("vault-relative path, for example Folder/Note.md")], required: ["path"]),
            promptExample: #"{"path": "Folder/Note.md"}"#
        )) { args in
            guard let p = args.string("path"), let body = try memory.note(path: p) else { return .error("note not found") }
            return .ok(body)
        }
    }

    public static func getStructure(_ memory: MemoryService) -> Tool {
        FunctionTool(ToolSpec(
            name: "get_structure",
            description: "Get the user's personal knowledge base: the folder tree plus the README portrait of who they are. Call this first whenever personal context would help (who the user is, their projects, people, plans, preferences).",
            inputSchema: JSONSchema.none
        )) { _ in .ok(try memory.structure()) }
    }

    public static func getFiles(_ memory: MemoryService) -> Tool {
        FunctionTool(ToolSpec(
            name: "get_files",
            description: "Fetch notes by vault-relative path exactly as shown by get_structure, e.g. [\"README.md\", \"Work/Acme.md\"]. At most \(maxFilesPerCall) per call; fetch only what you need.",
            inputSchema: JSONSchema.object(["paths": JSONSchema.array(of: JSONSchema.string(), "vault-relative note paths")], required: ["paths"])
        )) { args in
            var paths = (args["paths"]?.asArray ?? []).compactMap(\.asString)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !paths.isEmpty else { return .ok("(no paths given)") }

            var notices: [String] = []
            if paths.count > maxFilesPerCall {
                notices.append("(only the first \(maxFilesPerCall) of \(paths.count) paths were fetched; call again for the rest)")
                paths = Array(paths.prefix(maxFilesPerCall))
            }
            let all = try memory.workspace.readAll()
            var chunks: [String] = []
            var size = 0
            for p in paths {
                let text: String
                if let found = memory.resolveNote(p, in: all) { text = "=== \(found.path) ===\n\(found.body)" }
                else {
                    let guesses = suggestions(for: p, in: Array(all.keys))
                    text = "=== \(p) ===\n(not found)" + (guesses.isEmpty ? "" : " Did you mean: " + guesses.joined(separator: ", ") + "?")
                }
                if size + text.count > maxResponseChars {
                    notices.append("(response truncated at the size cap; call get_files again with fewer paths)")
                    break
                }
                size += text.count
                chunks.append(text)
            }
            return .ok((chunks + notices).joined(separator: "\n\n"))
        }
    }

    /// Notes whose file name resembles a path the model guessed.
    static func suggestions(for query: String, in paths: [String]) -> [String] {
        let q = ((query as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        guard !q.isEmpty else { return [] }
        return paths.filter { p in
            let stem = ((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            return stem.contains(q) || q.contains(stem)
        }.sorted().prefix(3).map { $0 }
    }
}
