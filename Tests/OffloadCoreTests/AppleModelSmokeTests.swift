import XCTest
@testable import OffloadCore

/// Runs the real triage prompt against the system's on-device model. Skipped where it is unavailable.
final class AppleModelSmokeTests: XCTestCase {
    func testTriageWithRealOnDeviceModel() async throws {
        try XCTSkipUnless(AppleOnDeviceModel.availability.available, "Apple on-device model unavailable: \(AppleOnDeviceModel.availability.reason)")
        let triager = Triager(model: AppleOnDeviceModel())
        let cases: [(String, TriageInput, Verdict)] = [
            ("EN lease note", TriageInput(kind: .file, trust: .authored, title: "lease", location: "/notes/lease.md", date: Date(),
                text: "Signed the lease for the Mission Street apartment with landlord Mr. Alvarez. Rent is $3,400 a month, security deposit equals two months of rent. Lease runs twelve months from June 1."), .survivor),
            ("ZH lease note", TriageInput(kind: .file, trust: .authored, title: "租房", location: "/notes/租房.md", date: Date(),
                text: "昨天在上海和王先生签了租房合同,押金两个月房租,每月租金五千元,租期一年,从七月一号开始。房子在浦东新区世纪大道附近。"), .survivor),
            ("promo mail", TriageInput(kind: .mail, trust: .correspondence, title: "FLASH SALE 50% OFF", location: "mail", date: Date(),
                text: "From: deals@shop.example\nSubject: FLASH SALE 50% OFF\n\nHuge savings this weekend only! Click here to shop now. Unsubscribe at any time."), .junk),
            ("booking mail", TriageInput(kind: .mail, trust: .correspondence, title: "Your flight is confirmed", location: "mail", date: Date(),
                text: "From: noreply@united.example\nSubject: Your flight is confirmed\n\nUA 837 San Francisco to Shanghai departs March 3 at 11:40. Confirmation code K7P2QX. Seat 24A."), .survivor),
            ("medical", TriageInput(kind: .file, trust: .saved, title: "labs", location: "/docs/labs.pdf", date: Date(),
                text: "Patient: lab results. HIV test positive. Diagnosis: type 2 diabetes. Prescribed metformin 500mg. Psychiatric evaluation notes attached. Confidential medical record."), .sensitive),
            ("group chat small talk", TriageInput(kind: .chat, trust: .correspondence, title: "Friends", location: "chat", date: Date(),
                text: "Alex: lol did you see the game\nSam: yeah insane\nMe: haha\nAlex: gg\nSam: 😂", conversation: ConversationInfo(name: "Friends", isGroup: true)), .junk),
        ]
        var correct = 0
        print("\n===== ON-DEVICE TRIAGE SMOKE =====")
        for (label, input, expected) in cases {
            let start = Date()
            let out = await triager.triage(input)
            let ok = out.verdict == expected
            if ok { correct += 1 }
            print(String(format: "%@ %-22@ expected=%@ got=%@ reason=%@ (%.1fs)", ok ? "✓" : "✗", label as NSString, expected.rawValue as NSString, out.verdict.rawValue as NSString, out.reason.rawValue as NSString, Date().timeIntervalSince(start)))
            if out.verdict == .survivor { print("    title: \(out.title)\n    summary: \(out.summary)") }
            if let d = out.detail { print("    detail: \(d)") }
        }
        print("correct \(correct)/\(cases.count)\n=====")
        // Not asserting accuracy (a 3B model is not deterministic), but it must at least produce parseable answers.
        XCTAssertGreaterThanOrEqual(correct, cases.count / 2)
    }
}

/// Builds a small knowledge base with the real on-device model from realistic summaries.
final class AppleVaultSmokeTests: XCTestCase {
    func testBuildVaultWithRealOnDeviceModel() async throws {
        try XCTSkipUnless(AppleOnDeviceModel.availability.available, "Apple on-device model unavailable")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-apple-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try T.store()
        let items: [(String, String, Trust, String)] = [
            ("lease", "Mission Street lease", .authored, "The user signed a twelve-month lease for an apartment on Mission Street with landlord Mr. Alvarez. Rent is $3,400 per month and the security deposit equals two months of rent. The lease starts June 1."),
            ("acme", "Acme Series A", .authored, "The user is the founder of Acme and is raising a Series A. Orion Capital sent a term sheet for eight million dollars at a thirty-two million dollar pre-money valuation. Legal is reviewing the liquidation preference clause."),
            ("sync", "Weekly sync with Priya", .authored, "The user has a weekly sync with Priya every Tuesday at 10am about the data pipeline migration for Acme. Action items go into the shared tracker."),
            ("japan", "Japan trip", .authored, "The user plans a trip to Japan in April: three nights in Kyoto at a ryokan and two nights in Osaka. Shinkansen seats should be reserved a month ahead."),
            ("zh-school", "孩子的学校", .correspondence, "The user's child Xiaoming transfers to Tsinghua Primary School in the third grade next term. Arrival is at 7:40 and pickup at 4:30."),
            ("article", "Article about venture valuations", .saved, "A saved article about venture capital valuation bubbles and exit cycles; it argues fundraising will be more cautious this year."),
        ]
        for (id, title, trust, summary) in items {
            try store.commitItem(ItemRecord(id: id, bucket: "b", kind: .file, uri: "/\(id)", title: title, itemDate: Date(), fingerprint: id, summary: summary, verdict: .survivor, trust: trust), chunkTexts: [summary])
        }
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        let builder = VaultBuilder(store: store, model: AppleOnDeviceModel(), embedder: AppleContextualEmbedder(), workspace: ws)
        let start = Date()
        let report = try await builder.update(progress: { print("  [progress] \($0)") })
        print("\n===== ON-DEVICE VAULT BUILD (\(String(format: "%.0f", Date().timeIntervalSince(start)))s) =====")
        print("considered=\(report.considered) merged=\(report.merged) batches=\(report.batches) failedBatches=\(report.failedBatches) created=\(report.created) rejected=\(report.rejected) portrait=\(report.portraitUpdated) aborted=\(report.abortedReason ?? "-")")
        let notes = try ws.readAll()
        for path in notes.keys.sorted() {
            print("\n--- \(path) ---\n\(notes[path]!.prefix(700))")
        }
        print("\nunmerged left: \(try store.unmergedSurvivors().count)\n=====")
        XCTAssertGreaterThan(report.batches, 0)
    }
}
