import Foundation

public struct CycleReport: Sendable {
    public var ingest = IngestReport()
    public var vault = VaultUpdateReport()
    public var cards = 0
    public var vectorsStored = 0
    public var writingStyleCreated = false
    public var cancelled = false
    public var seconds = 0.0
    public var warnings: [String] = []
}

/// Progress is reported from several tasks; this keeps the running totals consistent.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var state = CycleProgress()
    private let sink: (@Sendable (CycleProgress) -> Void)?
    init(sink: (@Sendable (CycleProgress) -> Void)?) { self.sink = sink }
    func update(_ change: (inout CycleProgress) -> Void) {
        lock.lock(); change(&state); let copy = state; lock.unlock()
        sink?(copy)
    }
}

/// Wires configuration into live objects. One `Runtime` is built per process (CLI command, app
/// launch, scheduled run) and owns the database connection.
public final class Runtime: @unchecked Sendable {
    public let paths: AppPaths
    public let config: OffloadConfig
    public let store: KnowledgeStore
    public let embedder: Embedder
    public let triageModel: LanguageModel
    public let knowledgeModel: LanguageModel
    public let assistantModel: LanguageModel
    public let workspace: VaultWorkspace
    public let memory: MemoryService
    public let searcher: HybridSearcher
    public let indexer: Indexer
    public let history: CycleHistory
    /// Why a configured model or embedder was replaced by the built-in one, if it was.
    public let fallbackNotes: [String]
    /// Reading sources is one job at a time: a full cycle and live sync take turns, so a file that
    /// changed during a cycle is not read and triaged by both at once.
    private let ingestGate = AsyncMutex()
    /// The user's MCP servers, connected on first use and kept for the life of this runtime.
    let assistantTools = AssistantToolState()

    /// `models` overrides the configured models; it exists so tests (and embedders of the library)
    /// can supply their own implementations.
    public init(paths: AppPaths = AppPaths(), config: OffloadConfig? = nil, models: (triage: LanguageModel, knowledge: LanguageModel, assistant: LanguageModel)? = nil) throws {
        self.paths = paths
        let cfg = try config ?? paths.loadConfig()
        self.config = cfg
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.store = try KnowledgeStore(path: paths.database.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.database.path)
        // The index holds raw text; keep it out of Time Machine and Spotlight.
        var dir = paths.support
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        FileManager.default.createFile(atPath: paths.support.appendingPathComponent(".metadata_never_index").path, contents: Data())

        // A model that cannot be built (its tool was uninstalled, its key is gone) must not take the
        // whole app down: fall back to the built-in one and say so.
        var notes: [String] = []
        // Claude may look things up itself, or carry out the assistant's tasks, but only in the assistant role:
        // nothing that reads untrusted items or writes notes ever gets either.
        var helper: ClaudeCLIModel.MemoryServer?
        let wantsLookups = cfg.assistant.provider == .claudeCLI && cfg.assistant.memoryTools == true
        let wantsTasks = cfg.assistant.provider == .claudeCLI && cfg.assistant.agentTools == true
        if wantsLookups || wantsTasks {
            helper = ClaudeCLIModel.MemoryServer.locate(home: paths.support)
            if helper == nil { notes.append("Claude cannot use Offload's tools: the `offload` command was not found next to the app. It answers from the excerpts it is given.") }
        }
        func resolve(_ role: String, _ profile: ModelProfile, _ override: LanguageModel?, lookups: ClaudeCLIModel.MemoryServer? = nil, tasks: ClaudeCLIModel.MemoryServer? = nil) -> LanguageModel {
            if let override { return override.redactingIfHosted() }
            do { return try Self.makeModel(profile, memoryServer: lookups, taskServer: tasks) }
            catch { notes.append("\(role) model unavailable (\(error)); using the built-in model"); return AppleOnDeviceModel() }
        }
        self.triageModel = resolve("Triage", cfg.triage, models?.triage)
        self.knowledgeModel = resolve("Knowledge", cfg.knowledge, models?.knowledge)
        self.assistantModel = resolve("Assistant", cfg.assistant, models?.assistant, lookups: wantsLookups ? helper : nil, tasks: wantsTasks ? helper : nil)
        if let e = try? Self.makeEmbedder(cfg.embedding) { self.embedder = e } else {
            notes.append("Embedding model unavailable; using the built-in one")
            self.embedder = AppleContextualEmbedder()
        }
        self.fallbackNotes = notes
        self.workspace = VaultWorkspace(root: cfg.vaultPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? paths.defaultVault)
        self.indexer = Indexer(store: store, embedder: embedder)
        self.history = CycleHistory(url: paths.support.appendingPathComponent("history.jsonl"))
        self.searcher = HybridSearcher(store: store, embedder: embedder)
        self.memory = MemoryService(store: store, searcher: searcher, workspace: workspace)
    }

    // MARK: Factories

    /// Hosted models come back wrapped in `RedactingModel`, so nothing sent to a provider skips
    /// `PIIScan`; local models are returned as they are.
    public static func makeModel(_ p: ModelProfile, memoryServer: ClaudeCLIModel.MemoryServer? = nil, taskServer: ClaudeCLIModel.MemoryServer? = nil) throws -> LanguageModel {
        try buildModel(p, memoryServer: memoryServer, taskServer: taskServer).redactingIfHosted()
    }

    private static func buildModel(_ p: ModelProfile, memoryServer: ClaudeCLIModel.MemoryServer? = nil, taskServer: ClaudeCLIModel.MemoryServer? = nil) throws -> LanguageModel {
        switch p.provider {
        case .apple: return AppleOnDeviceModel()
        case .openaiCompatible:
            guard let base = p.baseURL.flatMap(URL.init(string:)), let model = p.model else { throw LLMError.unavailable("model profile needs baseURL and model") }
            return OpenAICompatibleModel(baseURL: base, model: model, apiKey: p.keyAccount.flatMap { Keychain.get(account: $0) }, vision: p.vision ?? false, nativeTools: p.nativeTools ?? false)
        case .claudeCLI: return try ClaudeCLIModel(model: p.model, memoryServer: memoryServer, taskServer: taskServer)
        case .codexCLI: return try CodexCLIModel(model: p.model)
        case .anthropic:
            guard let model = p.model, let account = p.keyAccount, let key = Keychain.get(account: account) else {
                throw LLMError.unavailable("Anthropic profile needs a model and an API key stored in the Keychain")
            }
            return AnthropicModel(model: model, apiKey: key, nativeTools: p.nativeTools ?? true)
        }
    }

    public static func makeEmbedder(_ p: EmbeddingProfile) throws -> Embedder {
        switch p.kind {
        case .appleContextual: return AppleContextualEmbedder()
        case .appleSentence: return AppleSentenceEmbedder()
        case .hashing: return HashingEmbedder()
        case .openaiCompatible:
            guard let base = p.baseURL.flatMap(URL.init(string:)), let model = p.model else { throw LLMError.unavailable("embedding profile needs baseURL and model") }
            let embedder = OpenAICompatibleEmbedder(baseURL: base, model: model, apiKey: p.keyAccount.flatMap { Keychain.get(account: $0) })
            // A remote endpoint receives every chunk, note and search query: send it redacted text.
            return base.isLoopbackHost ? embedder : RedactingEmbedder(embedder)
        }
    }

    // MARK: Sources

    /// One connector per chosen folder.
    public func folderConnectors() -> [FilesConnector] {
        config.folders.map { FilesConnector(root: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
    }

    public func connectors() -> [Connector] {
        var out: [Connector] = folderConnectors()
        if !config.imessageChats.isEmpty { out.append(IMessageConnector(selectedChatIDs: Set(config.imessageChats))) }
        if !config.whatsappChats.isEmpty { out.append(WhatsAppConnector(selectedChatIDs: Set(config.whatsappChats))) }
        if config.mailEnabled { out.append(MailConnector()) }
        if config.calendarEnabled { out.append(CalendarConnector()) }
        if config.appleNotesEnabled { out.append(AppleNotesConnector()) }
        if let siyuan = config.siyuanPath { out.append(SiYuanConnector(dataDirectory: URL(fileURLWithPath: (siyuan as NSString).expandingTildeInPath))) }
        if config.gmailEnabled || config.googleCalendarEnabled {
            let auth = GoogleAuth()
            if config.gmailEnabled { out.append(GmailConnector(auth: auth, cacheURL: paths.support.appendingPathComponent("gmail-metadata.json"))) }
            if config.googleCalendarEnabled { out.append(CalendarConnector(source: GoogleCalendarSource(auth: auth), bucket: "calendar:google")) }
        }
        return out
    }

    /// Brings the search index in line with the notes on disk (the user may have edited them in
    /// another editor, or an update may have run while the app was closed).
    public func refreshNotesIndex() async throws {
        try await VaultBuilder(store: store, model: knowledgeModel, embedder: embedder, workspace: workspace).syncIndex()
    }

    // MARK: Live sync

    /// Brings the raw index (chunks, keyword and vector indexes) in line with what changed on
    /// disk at `paths` (a folder path means everything beneath it): new and edited files are read and indexed, deleted ones are removed with
    /// their chunks and vectors. It does not touch the knowledge base; notes are updated by the
    /// next cycle, which finds the new items waiting.
    @discardableResult
    public func syncChanged(paths: [String]) async -> IngestReport {
        var total = IngestReport()
        // Only folders the user has already read once: the first read of a folder is a deliberate,
        // visible step (onboarding or a cycle), never something that starts by itself.
        let connectors = folderConnectors().filter { connector in
            paths.contains { connector.scopedPath(for: $0) != nil } && ((try? store.hasBeenRead(bucket: connector.bucket)) ?? false)
        }
        if connectors.isEmpty { return total }
        let pipeline = IngestPipeline(store: store, triager: Triager(model: triageModel), indexer: indexer)
        await ingestGate.withLock {
            for connector in connectors where !Task.isCancelled {
                do { total.absorb(try await pipeline.sync(paths: paths, connector: connector)) }
                catch { total.sourceErrors[connector.bucket] = "\(error)" }
            }
            // Anything whose embedding failed while indexing is retried here rather than waiting for the night.
            _ = try? await indexer.embedPending()
        }
        return total
    }

    // MARK: The nightly cycle

    /// Read what is new -> update the knowledge base -> index -> prepare suggestions. Each stage
    /// is independent: a failure in one is reported and does not stop the ones after it. Cancelling
    /// the surrounding task stops at the next item; everything already read stays read, and the next
    /// run carries on from there.
    public func runCycle(
        skipVault: Bool = false, skipProactive: Bool = false, maxItemsPerSource: Int? = nil,
        shouldSkipVault: @escaping @Sendable () -> Bool = { false }, progress: (@Sendable (CycleProgress) -> Void)? = nil
    ) async -> CycleReport {
        let started = Date()
        var report = CycleReport()
        let tracker = ProgressTracker(sink: progress)
        @Sendable func emit(_ stage: CycleProgress.Stage, _ message: String) { tracker.update { $0.stage = stage; $0.message = message } }

        let connectors = self.connectors()
        if connectors.isEmpty { report.warnings.append("No sources are configured. Choose what to read in Settings, or run: offload sources add-folder <path>") }
        if !triageModel.capabilities.isLocal {
            report.warnings.append("triage is using a hosted model (\(triageModel.name)): the text of every item read is sent to that provider.")
        }

        emit(.reading, "Reading your sources")
        do {
            let pipeline = IngestPipeline(store: store, triager: Triager(model: triageModel), indexer: indexer)
            report.ingest = try await ingestGate.withLock {
                try await pipeline.run(connectors: connectors, maxItemsPerSource: maxItemsPerSource) { p in
                    tracker.update { state in
                        switch p.lastVerdict {
                        case .survivor: state.kept += 1
                        case .sensitive: state.sensitive += 1
                        case .junk, .failed: state.skipped += 1
                        }
                        state.stage = .reading; state.source = SourceNames.friendly(p.bucket)
                        state.done = p.done; state.total = p.total; state.currentTitle = p.lastTitle
                        state.message = "Reading \(state.source ?? "")"
                    }
                }
            }
            for (bucket, error) in report.ingest.sourceErrors { report.warnings.append("\(SourceNames.friendly(bucket)): \(error)") }
            if let w = try? WritingStyle.createIfNeeded(workspace: workspace, store: store) { report.writingStyleCreated = w }
        } catch { report.warnings.append("reading failed: \(error)") }

        if Task.isCancelled { return finish(&report, started: started, cancelled: true) }
        tracker.update { $0.source = nil; $0.currentTitle = nil; $0.done = 0; $0.total = 0 }
        emit(.embedding, "Indexing")
        do { report.vectorsStored = try await indexer.embedPending() } catch { report.warnings.append("indexing failed: \(error)") }

        if !skipVault, !Task.isCancelled {
            emit(.knowledge, "Updating your knowledge base")
            if knowledgeModel.name == AppleOnDeviceModel().name {
                report.warnings.append("the knowledge base is being written by the built-in on-device model, which misfiles and duplicates when merging many items. Search still finds your raw files, but for good notes choose a stronger model in Settings.")
            }
            do {
                let builder = VaultBuilder(store: store, model: knowledgeModel, embedder: embedder, workspace: workspace)
                report.vault = try await builder.update(shouldSkip: shouldSkipVault, progress: { message in emit(.knowledge, message) })
                if let why = report.vault.abortedReason { report.warnings.append("knowledge base not updated: \(why)") }
                if report.vault.failedBatches > 0 { report.warnings.append("\(report.vault.failedBatches) knowledge batch(es) failed; they will be retried") }
            } catch is CancellationError { return finish(&report, started: started, cancelled: true)
            } catch { report.warnings.append("knowledge update failed: \(error)") }
        }

        if !skipProactive, !Task.isCancelled {
            emit(.suggestions, "Preparing suggestions")
            do {
                report.cards = try await ProactivePlanner(store: store, memory: memory, model: assistantModel).run().count
            } catch is CancellationError { return finish(&report, started: started, cancelled: true)
            } catch { report.warnings.append("suggestions failed: \(error)") }
        }
        return finish(&report, started: started, cancelled: Task.isCancelled)
    }

    private func finish(_ report: inout CycleReport, started: Date, cancelled: Bool) -> CycleReport {
        report.cancelled = cancelled
        report.seconds = Date().timeIntervalSince(started)
        let i = report.ingest
        history.append(CycleRecord(
            id: UUID().uuidString, date: started, seconds: report.seconds, kept: i.survivors, skipped: i.junk, sensitive: i.sensitive, failed: i.failed,
            notesCreated: report.vault.created, notesChanged: report.vault.changed, suggestions: report.cards, warnings: report.warnings, cancelled: cancelled))
        return report
    }
}
