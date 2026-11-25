import XCTest
@testable import OffloadCore

final class RuntimeTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("offload-home-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testLaunchAgentPlistIsValidAndSchedulesTheCycle() throws {
        let data = try LaunchAgent.plist(executable: "/usr/local/bin/offload", hour: 3, minute: 15, logDir: "/tmp/logs", environment: ["OFFLOAD_HOME": "/tmp/x"])
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "dev.offload.cycle")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/local/bin/offload", "cycle", "--quiet", "--require-ac"])
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], ["Hour": 3, "Minute": 15])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["OFFLOAD_HOME"], "/tmp/x")
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertEqual(LaunchAgent.wakeCommand(hour: 3), "sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00")
        XCTAssertEqual(LaunchAgent.wakeCommand(hour: 0, minute: 2), "sudo pmset repeat wakeorpoweron MTWRFSU 23:57:00", "wraps past midnight")
        _ = Power.isOnACPower()
    }

    func testConfigRoundTripsWithRestrictedPermissionsAndNoSecrets() throws {
        let paths = AppPaths(support: home)
        var cfg = OffloadConfig()
        cfg.folders = ["~/Notes"]
        cfg.knowledge = ModelProfile(provider: .anthropic, model: "claude-sonnet-5-5", keyAccount: "anthropic-main")
        try paths.save(cfg)
        XCTAssertEqual(try paths.loadConfig(), cfg)
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.config.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        let text = try String(contentsOf: paths.config, encoding: .utf8)
        XCTAssertTrue(text.contains("anthropic-main"), "only the Keychain account name is stored")
        XCTAssertEqual(try AppPaths(support: home.appendingPathComponent("nothing")).loadConfig(), OffloadConfig(), "missing config means defaults")
    }

    func testDefaultLocationIsOwnDirectoryAndARelocatedHomeIsNeverEscaped() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = home.appendingPathComponent("Library/Application Support/Offload").path
        let standard = AppPaths()
        if ProcessInfo.processInfo.environment["OFFLOAD_HOME"] == nil {
            XCTAssertEqual(standard.support.path, expected, "the default data directory is Offload's own")
            XCTAssertTrue(standard.database.path.hasPrefix(expected))
        }
        // An explicitly relocated installation keeps its vault inside itself: tests and dev runs
        // must never write into the real home directory.
        let relocated = AppPaths(support: self.home)
        XCTAssertTrue(relocated.defaultVault.path.hasPrefix(self.home.path))
        XCTAssertTrue(relocated.database.path.hasPrefix(self.home.path))
        XCTAssertEqual(LaunchAgent.label, "dev.offload.cycle")
    }

    func testConfigFromAnOlderVersionStillLoads() throws {
        // Written before notes/SiYuan/Gmail existed: the newer keys are simply absent. The retired
        // "egress" key is still present in such files and must be ignored, not rejected.
        let old = ##"{"folders":["/Users/x/Notes"],"mailEnabled":true,"triage":{"provider":"apple"},"egress":{"rawSnippetsToHostedModels":true},"scheduleHour":4}"##
        let cfg = try JSONDecoder().decode(OffloadConfig.self, from: Data(old.utf8))
        XCTAssertEqual(cfg.folders, ["/Users/x/Notes"])
        XCTAssertTrue(cfg.mailEnabled)
        XCTAssertEqual(cfg.scheduleHour, 4)
        XCTAssertFalse(cfg.appleNotesEnabled); XCTAssertFalse(cfg.gmailEnabled); XCTAssertNil(cfg.siyuanPath)
        XCTAssertEqual(try JSONDecoder().decode(OffloadConfig.self, from: Data("{}".utf8)), OffloadConfig())
    }

    func testEverySourceGetsItsOwnBucketSoSourcesCannotDeleteEachOther() throws {
        var cfg = OffloadConfig()
        cfg.folders = ["/tmp/a", "/tmp/b"]; cfg.imessageChats = ["x"]; cfg.whatsappChats = ["y"]
        cfg.mailEnabled = true; cfg.calendarEnabled = true; cfg.appleNotesEnabled = true
        cfg.siyuanPath = "/tmp/siyuan/data"; cfg.gmailEnabled = true; cfg.googleCalendarEnabled = true
        cfg.embedding = EmbeddingProfile(kind: .hashing)
        let rt = try Runtime(paths: AppPaths(support: home), config: cfg)
        let buckets = rt.connectors().map(\.bucket)
        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(Set(buckets).count, buckets.count, "duplicate bucket names: \(buckets)")
        XCTAssertTrue(buckets.contains("calendar:apple") && buckets.contains("calendar:google") && buckets.contains("gmail") && buckets.contains("applenotes"))
    }

    func testSubscriptionProfilesBuildHostedModels() throws {
        if Subprocess.locate("claude") != nil {
            let m = try Runtime.makeModel(ModelProfile(provider: .claudeCLI, model: "sonnet"))
            XCTAssertFalse(m.capabilities.isLocal)
            XCTAssertEqual(m.name, "claude-cli:sonnet")
        } else { XCTAssertThrowsError(try Runtime.makeModel(ModelProfile(provider: .claudeCLI))) }
        if Subprocess.locate("codex") == nil { XCTAssertThrowsError(try Runtime.makeModel(ModelProfile(provider: .codexCLI))) }
    }

    func testAnUnusableConfiguredModelFallsBackInsteadOfBreakingEverything() throws {
        var cfg = OffloadConfig()
        cfg.knowledge = ModelProfile(provider: .openaiCompatible)      // no URL or model: cannot be built
        cfg.assistant = ModelProfile(provider: .anthropic, model: "m", keyAccount: "no-such-\(UUID().uuidString)")
        cfg.embedding = EmbeddingProfile(kind: .openaiCompatible)
        let rt = try Runtime(paths: AppPaths(support: home), config: cfg)
        XCTAssertEqual(rt.knowledgeModel.name, "apple.on-device")
        XCTAssertEqual(rt.assistantModel.name, "apple.on-device")
        XCTAssertEqual(rt.fallbackNotes.count, 3, "\(rt.fallbackNotes)")
        XCTAssertTrue(rt.fallbackNotes[0].hasPrefix("Knowledge model unavailable"))
        XCTAssertEqual(try Runtime(paths: AppPaths(support: home), config: OffloadConfig()).fallbackNotes, [])
    }

    func testHostedProfilesFailClearlyWithoutKeys() {
        XCTAssertThrowsError(try Runtime.makeModel(ModelProfile(provider: .anthropic, model: "m", keyAccount: "no-such-account-\(UUID().uuidString)")))
        XCTAssertThrowsError(try Runtime.makeModel(ModelProfile(provider: .openaiCompatible)))
        XCTAssertNoThrow(try Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "http://localhost:11434/v1", model: "qwen")))
        let local = try? Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "http://localhost:11434/v1", model: "qwen"))
        XCTAssertEqual(local?.capabilities.isLocal, true, "localhost servers count as local")
        let remote = try? Runtime.makeModel(ModelProfile(provider: .openaiCompatible, baseURL: "https://api.openai.com/v1", model: "gpt"))
        XCTAssertEqual(remote?.capabilities.isLocal, false)
    }

    /// The whole system, offline: a folder of notes goes in, a searchable knowledge base comes out.
    func testFullCycleWithScriptedModels() async throws {
        let docs = home.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "# Lease\nSigned the Mission Street lease with Mr. Alvarez. Deposit reference LD-55821. Rent is $3,400.".write(to: docs.appendingPathComponent("lease.md"), atomically: true, encoding: .utf8)
        try "# Acme\nOrion Capital sent the Series A term sheet; legal reviews the liquidation preference.".write(to: docs.appendingPathComponent("acme.md"), atomically: true, encoding: .utf8)
        try "BUY NOW limited offer JUNKME on everything in the shop this weekend only".write(to: docs.appendingPathComponent("promo.txt"), atomically: true, encoding: .utf8)

        var cfg = OffloadConfig()
        cfg.folders = [docs.path]
        cfg.embedding = EmbeddingProfile(kind: .hashing)
        let paths = AppPaths(support: home)
        let rt = try Runtime(paths: paths, config: cfg)
        XCTAssertEqual(rt.workspace.root.path, paths.defaultVault.path)

        // Replace the models with scripted ones; everything else is the real pipeline.
        let triage = MockModel { req in
            let t = req.messages.last!.text
            if t.contains("JUNKME") { return ##"{"summary":"","title":"x","junk":true,"sensitive":false}"## }
            if t.contains("Mission Street") { return ##"{"summary":"The user leases an apartment on Mission Street from Mr. Alvarez at $3,400 a month.","title":"Lease","junk":false,"sensitive":false}"## }
            return ##"{"summary":"The user is raising a Series A; Orion Capital sent a term sheet.","title":"Acme Series A","junk":false,"sensitive":false}"##
        }
        let knowledge = MockModel(contextChars: 60_000) { req in
            if req.messages[0].text.contains("opening portrait") { return "A founder who rents an apartment in San Francisco and is raising a Series A." }
            let user = req.messages.last!.text
            func n(_ title: String) -> Int { user.components(separatedBy: "\n").compactMap { l -> Int? in l.hasPrefix("#") && l.contains("· \(title)") ? Int(l.dropFirst().prefix { $0.isNumber }) : nil }.first ?? 1 }
            return ##"{"operations":[{"op":"create","path":"Home/Apartment.md","content":"# Apartment\nLeases on Mission Street from Mr. Alvarez, $3,400 a month.","evidence":[\##(n("Lease"))]},{"op":"create","path":"Work/Acme.md","content":"# Acme\nRaising a Series A; Orion Capital sent a term sheet.","evidence":[\##(n("Acme Series A"))]}],"skipped":[]}"##
        }
        let assistant = MockModel { _ in ##"{"candidates":[]}"## }
        let live = try RuntimeTestHarness.rewire(rt, triage: triage, knowledge: knowledge, assistant: assistant)

        let report = await live.runCycle()
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(report.ingest.survivors, 2)
        XCTAssertEqual(report.ingest.junk, 1)
        XCTAssertEqual(report.vault.created, 2)
        XCTAssertGreaterThan(try live.store.counts()["vectors"] ?? 0, 0)
        XCTAssertEqual(try live.store.notesNeedingVectors().count, 0, "notes are embedded too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.workspace.root.appendingPathComponent("README.md").path))

        // The point of the whole design: summaries for the big picture, raw text for the specifics.
        var opts = SearchOptions(); opts.limit = 5
        let hits = try await live.memory.search("LD-55821", options: opts)
        let raw = try XCTUnwrap(hits.first { $0.kind == .chunk })
        XCTAssertTrue(raw.text.contains("LD-55821"), "the exact reference lives only in the raw index; the note does not have it")
        XCTAssertEqual(raw.citedByNotes, ["Home/Apartment.md"], "…and the raw hit points back to the note that summarizes it")
        let noteHits = try await live.memory.search("Mr. Alvarez Mission Street rent", options: opts)
        XCTAssertEqual(noteHits.first { $0.kind == .note }?.notePath, "Home/Apartment.md")

        // A second cycle is a no-op: nothing new to read, nothing pending to merge.
        let before = triage.requests.count
        let again = await live.runCycle()
        XCTAssertEqual(again.ingest.survivors + again.ingest.junk, 0)
        XCTAssertEqual(triage.requests.count, before)
        XCTAssertEqual(again.vault.considered, 0)
    }
}

/// Builds a `Runtime`-like object with replacement models (the real `Runtime` constructs its
/// models from configuration, which tests must not depend on).
enum RuntimeTestHarness {
    static func rewire(_ rt: Runtime, triage: LanguageModel, knowledge: LanguageModel, assistant: LanguageModel) throws -> Runtime {
        try Runtime(paths: rt.paths, config: rt.config, models: (triage, knowledge, assistant))
    }
}
