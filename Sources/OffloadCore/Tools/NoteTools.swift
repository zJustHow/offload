import Foundation

/// Lets the assistant change the user's notes, one approved edit at a time.
///
/// The rule the knowledge builder follows (the model proposes, code validates, nothing the model
/// says touches a file directly) applies here too: an edit goes through `VaultOps.apply`, the same
/// checks as the nightly builder (safe path, size limits, no shrinking rewrites, no duplicate
/// titles), is shown to the user, and is written only if they approve. A note changed this way changes
/// the vault's fingerprint, so a nightly update that was running does not overwrite it.
public enum NoteTools {
    public static func proposeEdit(memory: MemoryService, editor: VaultEditor) -> Tool {
        FunctionTool(ToolSpec(
            name: "propose_note_edit",
            description: "Propose adding to or changing a note in the user's knowledge base. The user sees the change and must approve it; nothing is written before that.",
            inputSchema: JSONSchema.object([
                "path": JSONSchema.string("vault-relative path such as Folder/Note.md; the folder is required"),
                "operation": JSONSchema.string("create a new note, append to one, or rewrite one", enum: ["create", "append", "rewrite"]),
                "content": JSONSchema.string("the text to add (append), or the whole note (create, rewrite)"),
            ], required: ["path", "operation", "content"]),
            tier: .write, approval: .always,
            promptExample: #"{"path": "Folder/Note.md", "operation": "append", "content": "..."}"#
        ), describe: { a in
            "Edit the note \(a.string("path") ?? "?") (\(a.string("operation") ?? "?")): " + String((a.string("content") ?? "").replacingOccurrences(of: "\n", with: " ").prefix(300))
        }, preflight: { a in
            await check(a, memory: memory).problem
        }) { a in
            let plan = await check(a, memory: memory)
            if let problem = plan.problem { return .error(problem) }
            guard let path = plan.path, let body = plan.body else { return .error("nothing to write") }
            try await editor.put(path: path, body: body)
            return .ok("Saved \(path) (\(plan.verb)).")
        }
    }

    struct Plan { var problem: String?; var path: String?; var body: String?; var verb = "" }

    /// What the edit would produce, or why it is refused.
    static func check(_ a: JSONObject, memory: MemoryService) async -> Plan {
        guard let rawPath = a.string("path"), let opName = a.string("operation"), let content = a.string("content"),
            let kind = VaultOperation.Kind(rawValue: opName.lowercased())
        else { return Plan(problem: "path, operation (create, append or rewrite) and content are required") }
        guard var notes = try? memory.workspace.readAll() else { return Plan(problem: "the knowledge base could not be read") }
        let result = VaultOps.apply([VaultOperation(kind: kind, path: rawPath, content: content)], to: &notes)
        if let rejected = result.rejected.first { return Plan(problem: "not allowed: " + explain(rejected.reason)) }
        guard let applied = result.applied.first, let body = notes[applied.path] else { return Plan(problem: "nothing to change") }
        let verb: String
        switch applied.kind { case .create: verb = "created"; case .append: verb = "added to"; case .rewrite: verb = "rewritten" }
        return Plan(problem: nil, path: applied.path, body: VaultOps.cleanLinks(in: body, existing: notes), verb: verb)
    }

    static func explain(_ r: OpRejection) -> String {
        switch r {
        case .invalidPath: return "that path cannot be used. Use Folder/Note.md; README.md is written by Offload itself."
        case .rootNote: return "a note must be inside a folder, for example Home/Note.md."
        case .tooDeep: return "the folder is nested too deeply."
        case .tooManyNotes: return "the knowledge base is full."
        case .tooManyFolders: return "there are too many folders; use an existing one."
        case .emptyContent: return "there is nothing new to add (the note already says this, or the text is empty)."
        case .shrinksTooMuch: return "a rewrite may not remove most of a note; append instead."
        case .duplicateTitle: return "a note with that title already exists; append to it instead."
        case .tooLong: return "the note would be too long."
        case .redactedPlaceholder: return "the text contains a [REDACTED] placeholder, which would overwrite a real value."
        }
    }
}
