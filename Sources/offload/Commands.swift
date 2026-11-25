import Foundation
import OffloadCore

enum Commands {
    // MARK: - Setup

    static func doctor() async throws {
        let paths = AppPaths()
        out("Data directory : \(paths.support.path)")
        let cfg = try paths.loadConfig()
        out("Knowledge base : \((cfg.vaultPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? paths.defaultVault).path)")
        out()
        let fm = AppleOnDeviceModel.availability
        out("\(fm.available ? "OK  " : "WARN") built-in on-device language model: \(fm.reason)")
        let probe = try await AppleContextualEmbedder().embed(["hello world", "你好世界"])
        out("\(probe[0] != nil ? "OK  " : "WARN") embeddings (English): \(probe[0] != nil ? "available" : "unavailable")")
        out("\(probe[1] != nil ? "OK  " : "WARN") embeddings (Chinese): \(probe[1] != nil ? "available" : "unavailable")")
        let fts = (try? Database.inMemory().exec("CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram')")) != nil
        out("\(fts ? "OK  " : "FAIL") SQLite FTS5 with trigram tokenizer")
        out()
        out("\(ComputerPermissions.screenRecording ? "OK  " : "--  ") Screen Recording (needed for screen drafting and the agent)")
        out("\(ComputerPermissions.accessibility ? "OK  " : "--  ") Accessibility (needed for the agent to click and type)")
        let fmgr = FileManager.default
        out("\(fmgr.isReadableFile(atPath: IMessageConnector.defaultDatabase.path) ? "OK  " : "--  ") Messages database readable (needs Full Disk Access for this terminal/app)")
        out("\(fmgr.isReadableFile(atPath: MailConnector.defaultRoot.path) ? "OK  " : "--  ") Mail folder readable")
        out()
        out("triage model    : \(describe(cfg.triage))")
        out("knowledge model : \(describe(cfg.knowledge))")
        out("assistant model : \(describe(cfg.assistant))")
        out("embeddings      : \(cfg.embedding.kind.rawValue)")
        if cfg.knowledge.provider == .apple {
            out()
            out("NOTE: the knowledge base is written by the built-in on-device model. It is fine for reading")
            out("      items one by one but weak at merging many into coherent notes (it misfiles and duplicates).")
            out("      For good notes, configure a stronger model:  offload config model knowledge --provider ...")
        }
        out()
        let claude = await ClaudeCLIModel.authStatus()
        out("\(claude.loggedIn ? "OK  " : "--  ") Claude subscription (`claude` CLI): \(claude.loggedIn ? "logged in via \(claude.method ?? "?")" : claude.detail)")
        let codex = await CodexCLIModel.loginStatus()
        out("\(codex.loggedIn ? "OK  " : "--  ") ChatGPT subscription (`codex` CLI): \(codex.detail)")
        let g = await GoogleAuth().credentials()
        out("\(g != nil ? "OK  " : "--  ") Google: \(g != nil ? "signed in" : "not signed in (offload sources google login)")")
        out("nightly schedule: \(LaunchAgent.isInstalled ? "installed" : "not installed")")
    }

    static func describe(_ p: ModelProfile) -> String {
        switch p.provider {
        case .apple: return "Apple on-device"
        case .openaiCompatible: return "\(p.model ?? "?") @ \(p.baseURL ?? "?")"
        case .anthropic: return "Anthropic API \(p.model ?? "?")"
        case .claudeCLI: return "Claude subscription (claude CLI)\(p.model.map { " " + $0 } ?? "")"
        case .codexCLI: return "ChatGPT subscription (codex CLI)\(p.model.map { " " + $0 } ?? "")"
        }
    }

    static func status() throws {
        let rt = try Runtime()
        let c = try rt.store.counts()
        out("sources     : \(rt.config.folders.count) folder(s), \(rt.config.imessageChats.count) iMessage chat(s), \(rt.config.whatsappChats.count) WhatsApp chat(s), mail \(rt.config.mailEnabled ? "on" : "off"), calendar \(rt.config.calendarEnabled ? "on" : "off")")
        out("read        : \(c["survivor"] ?? 0) kept, \(c["junk"] ?? 0) junk, \(c["sensitive"] ?? 0) sensitive (dropped), \(c["failed"] ?? 0) failed (will retry)")
        out("indexed     : \(c["chunks"] ?? 0) chunks, \(c["vectors"] ?? 0) vectors, \(c["notes"] ?? 0) notes")
        out("pending     : \(try rt.store.unmergedSurvivors().count) item(s) not yet in the knowledge base")
        out("suggestions : \(try rt.store.cards().count) ready")
        out("knowledge   : \(rt.workspace.root.path)")
    }

    static func config(_ a: Args) throws {
        let paths = AppPaths()
        var cfg = try paths.loadConfig()
        switch a.positional.first {
        case "show", nil:
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            out(String(decoding: try enc.encode(cfg), as: UTF8.self))
            return
        case "model":
            guard a.positional.count >= 2, let provider = a.flags["provider"] else { fail("usage: config model <triage|knowledge|assistant> --provider <apple|openai|anthropic> ...") }
            let role = a.positional[1]
            var profile: ModelProfile
            switch provider {
            case "apple": profile = .apple
            case "openai", "ollama", "lmstudio":
                profile = ModelProfile(provider: .openaiCompatible, baseURL: a.flags["base-url"] ?? (provider == "ollama" ? "http://localhost:11434/v1" : provider == "lmstudio" ? "http://localhost:1234/v1" : "https://api.openai.com/v1"), model: a.flags["model"], vision: a.has("vision"))
                if profile.model == nil { fail("--model is required") }
            case "anthropic":
                profile = ModelProfile(provider: .anthropic, model: a.flags["model"])
                if profile.model == nil { fail("--model is required") }
            case "claude-cli": profile = ModelProfile(provider: .claudeCLI, model: a.flags["model"])
            case "codex-cli": profile = ModelProfile(provider: .codexCLI, model: a.flags["model"])
            default: fail("unknown provider '\(provider)' (apple, openai, ollama, lmstudio, anthropic, claude-cli, codex-cli)")
            }
            if a.has("key-stdin") {
                let account = "\(role)-\(provider)"
                guard let key = readLine(strippingNewline: true), !key.isEmpty else { fail("no key on stdin") }
                try Keychain.set(key, account: account)
                profile.keyAccount = account
            }
            switch role {
            case "triage": cfg.triage = profile
            case "knowledge": cfg.knowledge = profile
            case "assistant": cfg.assistant = profile
            default: fail("role must be triage, knowledge or assistant")
            }
            if role == "triage", profile.provider != .apple, !(profile.baseURL ?? "").contains("localhost") {
                err("Note: triage reads EVERY item. With a hosted model the text of all your files, mail and messages is sent to that provider. Keep triage on the built-in or a local model unless you intend that.")
            }
        case "embedding":
            guard let kind = a.flags["kind"] else { fail("usage: config embedding --kind <apple-contextual|apple-sentence|hashing|openai> ...") }
            switch kind {
            case "apple-contextual": cfg.embedding = EmbeddingProfile(kind: .appleContextual)
            case "apple-sentence": cfg.embedding = EmbeddingProfile(kind: .appleSentence)
            case "hashing": cfg.embedding = EmbeddingProfile(kind: .hashing)
            case "openai":
                guard let model = a.flags["model"] else { fail("--model is required") }
                var p = EmbeddingProfile(kind: .openaiCompatible, baseURL: a.flags["base-url"] ?? "http://localhost:11434/v1", model: model)
                if a.has("key-stdin"), let key = readLine(strippingNewline: true), !key.isEmpty { try Keychain.set(key, account: "embedding"); p.keyAccount = "embedding" }
                cfg.embedding = p
            default: fail("unknown embedding kind '\(kind)'")
            }
            out("Embedding changed. Existing vectors belong to the old embedder; run `offload reset --yes` and a new cycle to re-index.")
        case "vault":
            guard a.positional.count >= 2 else { fail("usage: config vault <path>") }
            cfg.vaultPath = a.positional[1]
        default: fail("unknown config command")
        }
        try paths.save(cfg)
        out("Saved.")
    }

    static func sources(_ a: Args) async throws {
        let paths = AppPaths()
        var cfg = try paths.loadConfig()
        let sub = a.positional.first ?? "list"
        switch sub {
        case "list":
            out("folders : " + (cfg.folders.isEmpty ? "(none)" : cfg.folders.joined(separator: ", ")))
            out("iMessage: \(cfg.imessageChats.count) chat(s)   WhatsApp: \(cfg.whatsappChats.count) chat(s)")
            out("mail    : \(cfg.mailEnabled ? "on" : "off")   calendar: \(cfg.calendarEnabled ? "on" : "off")   Apple Notes: \(cfg.appleNotesEnabled ? "on" : "off")")
            out("SiYuan  : \(cfg.siyuanPath ?? "off")")
            out("Google  : Gmail \(cfg.gmailEnabled ? "on" : "off"), Calendar \(cfg.googleCalendarEnabled ? "on" : "off")")
            return
        case "add-folder":
            guard a.positional.count >= 2 else { fail("usage: sources add-folder <path>") }
            let path = URL(fileURLWithPath: (a.positional[1] as NSString).expandingTildeInPath).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { fail("not a folder: \(path)") }
            if !cfg.folders.contains(path) { cfg.folders.append(path) }
        case "remove-folder":
            guard a.positional.count >= 2 else { fail("usage: sources remove-folder <path>") }
            let path = URL(fileURLWithPath: (a.positional[1] as NSString).expandingTildeInPath).standardizedFileURL.path
            cfg.folders.removeAll { $0 == path }
        case "chats":
            guard a.positional.count >= 2 else { fail("usage: sources chats <imessage|whatsapp>") }
            let chats = a.positional[1] == "imessage" ? try IMessageConnector.listChats() : try WhatsAppConnector.listChats()
            for c in chats.prefix(60) { out("\(c.id)\t\(c.name)\t\(c.isGroup ? "group" : "1:1")\t\(c.messageCount) messages") }
            return
        case "select":
            guard a.positional.count >= 3 else { fail("usage: sources select <imessage|whatsapp> <chat-id>...") }
            let ids = Array(a.positional.dropFirst(2))
            if a.positional[1] == "imessage" { cfg.imessageChats = ids } else if a.positional[1] == "whatsapp" { cfg.whatsappChats = ids } else { fail("unknown source") }
        case "mail": cfg.mailEnabled = a.positional.dropFirst().first == "on"
        case "calendar": cfg.calendarEnabled = a.positional.dropFirst().first == "on"
        case "notes": cfg.appleNotesEnabled = a.positional.dropFirst().first == "on"
        case "siyuan":
            guard let arg = a.positional.dropFirst().first else { fail("usage: sources siyuan <path-to-workspace/data | off>") }
            if arg == "off" { cfg.siyuanPath = nil } else {
                let path = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath).standardizedFileURL.path
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { fail("not a folder: \(path)") }
                cfg.siyuanPath = path
            }
        case "gmail": cfg.gmailEnabled = a.positional.dropFirst().first == "on"
        case "gcal": cfg.googleCalendarEnabled = a.positional.dropFirst().first == "on"
        case "google":
            try await google(a, &cfg)
            if a.positional.dropFirst().first == "status" || a.positional.dropFirst().first == "logout" { return }
        default: fail("unknown sources command")
        }
        try paths.save(cfg)
        out("Saved.")
    }

    /// `sources google login|logout|status`. Sign-in uses the user's own OAuth client (see README).
    static func google(_ a: Args, _ cfg: inout OffloadConfig) async throws {
        let auth = GoogleAuth()
        switch a.positional.dropFirst().first {
        case "status":
            if let c = await auth.credentials() {
                out("signed in; Gmail: \(c.scopes.contains(GoogleAuth.gmailScope) ? "yes" : "no"), Calendar: \(c.scopes.contains(GoogleAuth.calendarScope) ? "yes" : "no")")
            } else { out("not signed in") }
        case "logout":
            await auth.signOut(); cfg.gmailEnabled = false; cfg.googleCalendarEnabled = false
            try AppPaths().save(cfg); out("Signed out and removed the stored token. (Revoke access at https://myaccount.google.com/permissions to be thorough.)")
        case "login":
            guard let clientID = a.flags["client-id"] else {
                fail("usage: sources google login --client-id <id> [--client-secret-stdin] [--gmail] [--calendar]\n  Create a *Desktop app* OAuth client in your own Google Cloud project (enable the Gmail and/or Calendar API), see README.")
            }
            var secret = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"] ?? ""
            if a.has("client-secret-stdin") { secret = readLine(strippingNewline: true) ?? "" }
            guard !secret.isEmpty else { fail("provide the client secret with --client-secret-stdin or the GOOGLE_CLIENT_SECRET environment variable") }
            var scopes: [String] = []
            if a.has("gmail") || !a.has("calendar") { scopes.append(GoogleAuth.gmailScope) }
            if a.has("calendar") || !a.has("gmail") { scopes.append(GoogleAuth.calendarScope) }
            try await auth.signIn(clientID: clientID, clientSecret: secret, scopes: scopes, openURL: { url in
                err("Opening your browser to sign in to Google. If nothing opens, visit:\n\(url.absoluteString)\n")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [url.absoluteString]; try? p.run()
            })
            cfg.gmailEnabled = scopes.contains(GoogleAuth.gmailScope); cfg.googleCalendarEnabled = scopes.contains(GoogleAuth.calendarScope)
            out("Signed in. Reading enabled for:" + (cfg.gmailEnabled ? " Gmail" : "") + (cfg.googleCalendarEnabled ? " Calendar" : ""))
        default: fail("usage: sources google <login|logout|status>")
        }
    }

    // MARK: - Use

    static func cycle(_ a: Args, ingestOnly: Bool) async throws {
        if a.has("require-ac"), !Power.isOnACPower() { out("On battery power; skipping (--require-ac)."); return }
        let rt = try Runtime()
        let quiet = a.has("quiet")
        let showProgress: @Sendable (CycleProgress) -> Void = { p in err("  ... \(p.message)" + (p.total > 0 ? " \(p.done)/\(p.total)" : "")) }
        let progress: (@Sendable (CycleProgress) -> Void)? = quiet ? nil : showProgress
        let skipVault: Bool = ingestOnly || a.has("no-vault")
        let skipProactive: Bool = ingestOnly || a.has("no-proactive")
        let maxItems: Int? = a.flags["max"].flatMap { Int($0) }
        let report = await rt.runCycle(skipVault: skipVault, skipProactive: skipProactive, maxItemsPerSource: maxItems, progress: progress)
        let i = report.ingest
        out("read: \(i.listed) listed, \(i.skippedUpToDate) unchanged, \(i.survivors) kept, \(i.junk) junk, \(i.sensitive) sensitive, \(i.failed) failed, \(i.deleted) removed")
        out("knowledge: \(report.vault.created) note(s) created, \(report.vault.changed) changed, \(report.vault.merged) item(s) merged, \(report.vault.deferred) deferred, \(report.vault.notesInVault) in total")
        out("suggestions: \(report.cards)")
        for w in report.warnings { err("warning: \(w)") }
    }

    /// Keeps the index following the chosen folders until interrupted (what the app does when
    /// "Keep search up to date as files change" is on).
    static func watch(_ a: Args) async throws {
        let rt = try Runtime()
        let quiet = a.flags["quiet-period"].flatMap(Double.init) ?? 5
        let sync = LiveSync(runtime: rt, quietPeriod: quiet) { r in
            out("synced: \(r.survivors) kept, \(r.junk) junk, \(r.sensitive) sensitive, \(r.failed) failed, \(r.deleted) removed")
            for (bucket, error) in r.sourceErrors { err("warning: \(bucket): \(error)") }
        }
        guard sync.start() else { fail("no folder to watch. Add one with: offload sources add-folder <path>") }
        out("Watching \(rt.folderConnectors().map(\.root.path).joined(separator: ", ")). Changes are applied after \(Int(quiet))s of quiet. Ctrl-C to stop.")
        while true { try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
    }

    static func search(_ a: Args) async throws {
        let q = a.positional.joined(separator: " ")
        guard !q.isEmpty else { fail("usage: search <query> [--mode hybrid|lexical|exact|vector] [--limit N] [--notes-only]") }
        let rt = try Runtime()
        var opts = SearchOptions()
        opts.limit = a.flags["limit"].flatMap(Int.init) ?? 8
        switch a.flags["mode"] ?? "hybrid" {
        case "hybrid": opts.mode = .hybrid
        case "lexical": opts.mode = .lexicalOnly
        case "exact": opts.mode = .exactOnly
        case "vector": opts.mode = .vectorOnly
        default: fail("--mode must be hybrid, lexical, exact or vector")
        }
        if a.has("notes-only") { opts.include = [.note] }
        let hits = try await rt.memory.search(q, options: opts)
        if hits.isEmpty { out("(no results)"); return }
        for (n, h) in hits.enumerated() {
            let sig = h.signals
            let how = [sig.lexicalRank.map { "bm25#\($0)" }, sig.exactRank.map { "exact#\($0)" }, sig.vectorRank.map { "vec#\($0)" }].compactMap { $0 }.joined(separator: " ")
            switch h.kind {
            case .note: out("\(n + 1). [note] \(h.notePath ?? h.title)  (\(how))")
            case .chunk:
                let kind: String = h.source?.kind.rawValue ?? "item"
                let uri: String = h.source?.uri ?? ""
                let cited: String = h.citedByNotes.isEmpty ? "" : "  <- " + h.citedByNotes.joined(separator: ", ")
                out("\(n + 1). [\(kind)] \(h.title)  \(uri)  (\(how))\(cited)")
            }
            out("   \(h.snippet)")
        }
    }

    static func ask(_ a: Args) async throws {
        let q = a.positional.joined(separator: " ")
        guard !q.isEmpty else { fail("usage: ask <question>") }
        let rt = try Runtime()
        let answer = try await MemoryQA(memory: rt.memory, model: rt.assistantModel).ask(q)
        out(answer.text)
        if !answer.sources.isEmpty { out("\nSources:"); for s in answer.sources { out("  - \(s)") } }
    }

    static func draft(_ a: Args) async throws {
        let rt = try Runtime()
        var visible = ""
        var shot: Data?
        if a.has("screen") {
            let computer = MacComputerController()
            shot = try await computer.screenshot()
            visible = try OCR.recognize(imageData: shot!)
        } else {
            while let line = readLine(strippingNewline: false) { visible += line }
        }
        let ws = rt.workspace
        let drafter = ReplyDrafter(memory: rt.memory, model: rt.assistantModel, writingStyle: { WritingStyle.read(in: ws) })
        let d = try await drafter.draft(visibleText: visible, screenshot: shot, instruction: a.flags["instruction"])
        out(d.text)
        if !d.usedNotes.isEmpty || !d.usedItems.isEmpty { err("(used notes: \(d.usedNotes.joined(separator: ", ")); \(d.usedItems.count) source excerpt(s))") }
    }

    static func agent(_ a: Args) async throws {
        let task = a.positional.joined(separator: " ")
        guard !task.isEmpty else { fail("usage: agent <task> [--computer] [--yes] [--max-steps N]") }
        let rt = try Runtime()
        let auto = a.has("yes")
        let computer: ComputerController? = a.has("computer") ? MacComputerController() : nil
        if computer != nil, !ComputerPermissions.screenRecording || !ComputerPermissions.accessibility {
            err("The agent needs Screen Recording and Accessibility permission for this terminal. Run `offload doctor`.")
            ComputerPermissions.requestScreenRecording(); ComputerPermissions.requestAccessibility()
        }
        let agent = Agent(
            model: rt.assistantModel, memory: rt.memory, computer: computer,
            confirm: { description in
                if auto { err("  (auto-approved) \(description)"); return true }
                err("\nThe assistant wants to do something that cannot be undone:\n  \(description)\nAllow? [y/N] ")
                return (readLine() ?? "").lowercased().hasPrefix("y")
            },
            ask: { q in err("\nThe assistant asks: \(q)"); return readLine() })
        let result = await agent.run(task: task, maxSteps: a.flags["max-steps"].flatMap(Int.init) ?? 25) { event in
            switch event {
            case .step(let n): err("[step \(n)]")
            case .action(let act): err("  \(act.tool) \(act.args.map { "\($0.key)=\($0.value.prefix(60))" }.sorted().joined(separator: " "))  — \(act.thought.prefix(120))")
            case .observation(let o): err("  → \(o.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            default: break
            }
        }
        out("\n\(result.status): \(result.summary)")
    }

    static func suggestions(_ a: Args) throws {
        let rt = try Runtime()
        switch a.positional.first ?? "list" {
        case "list":
            let cards = try rt.store.cards()
            if cards.isEmpty { out("No suggestions. Run `offload cycle`."); return }
            for c in cards {
                out("[\(c.id)] \(c.title)  (\(c.kind.rawValue), confidence \(c.confidence.rawValue))")
                out("  why: \(c.why)")
                out("  \(c.preparedContent.replacingOccurrences(of: "\n", with: "\n  "))")
                if !c.sources.isEmpty { out("  sources: \(c.sources.joined(separator: ", "))") }
                out()
            }
        case "dismiss", "done":
            guard a.positional.count >= 2 else { fail("usage: suggestions \(a.positional[0]) <id>") }
            try rt.store.setCardStatus(id: a.positional[1], status: a.positional[0] == "dismiss" ? "dismissed" : "done")
            out("OK")
        default: fail("usage: suggestions [list|dismiss <id>|done <id>]")
        }
    }

    static func mcp(_ a: Args) async throws {
        let rt = try Runtime()
        err("offload mcp: serving the knowledge base at \(rt.workspace.root.path) on stdio")
        await MCPServer(memory: rt.memory).runStdio()
    }

    static func eval() async throws {
        let apple = AppleSentenceEmbedder(), ctx = AppleContextualEmbedder(), hash = HashingEmbedder()
        let rows = try await RetrievalEval().run(configs: [
            .init(label: "lexical (BM25)", embedder: nil, mode: .lexicalOnly),
            .init(label: "exact (trigram) only", embedder: nil, mode: .exactOnly),
            .init(label: "vector: apple sentence", embedder: apple, mode: .vectorOnly),
            .init(label: "vector: apple contextual", embedder: ctx, mode: .vectorOnly),
            .init(label: "HYBRID: hashing", embedder: hash, mode: .hybrid),
            .init(label: "HYBRID: apple sentence", embedder: apple, mode: .hybrid),
            .init(label: "HYBRID: apple contextual", embedder: ctx, mode: .hybrid),
        ])
        out("Synthetic corpus: \(EvalCorpus.docs.count) documents, \(EvalCorpus.queries.count) queries. A regression harness, not a benchmark.\n")
        out(RetrievalEval.format(rows))
    }

    static func schedule(_ a: Args) throws {
        let paths = AppPaths()
        switch a.positional.first {
        case "install":
            let cfg = try paths.loadConfig()
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let absolute = exe.hasPrefix("/") ? exe : FileManager.default.currentDirectoryPath + "/" + exe
            var env: [String: String] = [:]
            if let home = ProcessInfo.processInfo.environment["OFFLOAD_HOME"] { env["OFFLOAD_HOME"] = home }
            try LaunchAgent.install(executable: absolute, hour: cfg.scheduleHour, logDir: paths.logs.path, environment: env)
            out("Installed: the cycle runs daily at \(String(format: "%02d:00", cfg.scheduleHour)) while the Mac is awake and plugged in.")
            out("launchd does not wake a sleeping Mac. To also wake it each night, run this yourself (needs your password):")
            out("  \(LaunchAgent.wakeCommand(hour: cfg.scheduleHour))")
        case "uninstall":
            try LaunchAgent.uninstall()
            out("Removed. (If you set a wake schedule, clear it with: sudo pmset repeat cancel)")
        case "status", nil: out(LaunchAgent.isInstalled ? "installed (\(LaunchAgent.plistURL.path))" : "not installed")
        default: fail("usage: schedule <install|uninstall|status>")
        }
    }

    static func reset(_ a: Args) throws {
        guard a.has("yes") else { fail("this deletes the search index and read-state (not your notes or source files). Re-run with --yes.") }
        let paths = AppPaths()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: paths.database.path + suffix) }
        out("Index deleted. Your knowledge base folder and source files were not touched.")
    }
}
