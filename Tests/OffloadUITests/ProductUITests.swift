import AppKit
import SwiftUI
import XCTest
@testable import OffloadUI

@MainActor
final class OnboardingModelTests: XCTestCase {
    func make(_ step: OnboardingModel.Step = .welcome) -> OnboardingModel {
        let m = OnboardingModel(startAt: step)
        m.sources = [SourceOption(id: "folders", title: "Folders", subtitle: "", symbol: "folder", style: .folders), SourceOption(id: "notes", title: "Notes", subtitle: "", symbol: "note.text")]
        return m
    }

    func testWalksTheWholeGuideForwardAndBack() {
        let m = make()
        var visited: [OnboardingModel.Step] = []
        m.onStepChanged = { visited.append($0) }
        m.toggle("notes", true)
        for _ in 0..<5 { m.performPrimary() }          // welcome -> sources -> permissions -> models -> privacy -> analyze
        XCTAssertEqual(m.step, .analyze)
        XCTAssertEqual(visited, [.sources, .permissions, .models, .privacy, .analyze])
        m.back()
        XCTAssertEqual(m.step, .privacy)
        XCTAssertFalse(m.goingForward, "the screens slide the other way when going back")
        m.performPrimary()
        XCTAssertTrue(m.goingForward)
        XCTAssertFalse(make(.welcome).canGoBack)
        XCTAssertFalse(make(.done).canGoBack)
    }

    func testYouCannotLeaveTheSourcesStepWithNothingChosen() {
        let m = make(.sources)
        XCTAssertFalse(m.primaryEnabled)
        m.performPrimary()
        XCTAssertEqual(m.step, .sources, "nothing chosen: stay")
        var toggled: [(String, Bool)] = []
        m.onToggleSource = { toggled.append(($0, $1)) }
        m.toggle("notes", true)
        XCTAssertTrue(m.primaryEnabled)
        XCTAssertEqual(toggled.count, 1)
        XCTAssertEqual(m.chosenSources.map(\.id), ["notes"])
        m.toggle("notes", false)
        XCTAssertFalse(m.primaryEnabled)
        m.toggle("does-not-exist", true)   // unknown ids are ignored, not crashes
        XCTAssertEqual(toggled.count, 2)
    }

    func testPermissionsStepWarnsButNeverBlocks() {
        let m = make(.permissions)
        m.permissions = [PermissionRow(id: "fda", title: "FDA", detail: "", status: .needsAction, symbol: "x", required: true),
                         PermissionRow(id: "screen", title: "Screen", detail: "", status: .optional, symbol: "x", required: false)]
        XCTAssertEqual(m.missingRequired.map(\.id), ["fda"], "optional permissions never count as missing")
        XCTAssertEqual(m.primaryTitle, "Continue anyway")
        XCTAssertTrue(m.primaryEnabled)
        m.permissions[0].status = .ok
        XCTAssertEqual(m.primaryTitle, "Continue")
        m.performPrimary()
        XCTAssertEqual(m.step, .models)
    }

    func testModelChoiceIgnoresUnavailableOptions() {
        let m = make(.models)
        m.models = [ModelOption(id: "builtin", title: "", subtitle: "", readiness: .ready, statusText: ""), ModelOption(id: "gone", title: "", subtitle: "", readiness: .unavailable, statusText: "")]
        var chosen: [String] = []
        m.onSelectModel = { chosen.append($0) }
        m.select(model: "gone"); m.select(model: "nope"); m.select(model: "builtin")
        XCTAssertEqual(chosen, ["builtin"])
        XCTAssertEqual(m.selectedModel, "builtin")
    }

    func testTheAnalysisStepAdaptsToWhatIsHappening() {
        let m = make(.analyze)
        var started = 0, stopped = 0, finished: [Bool] = []
        m.onStartAnalysis = { started += 1 }; m.onStopAnalysis = { stopped += 1 }; m.onFinish = { finished.append($0) }
        XCTAssertEqual(m.primaryTitle, "Start reading")
        m.performPrimary()
        XCTAssertEqual(started, 1)
        XCTAssertEqual(m.step, .analyze, "starting does not advance")
        m.analysis.phase = .running
        XCTAssertEqual(m.primaryTitle, "Keep going in the background")
        XCTAssertFalse(m.canGoBack, "no walking away mid-run by accident")
        m.performPrimary()
        XCTAssertEqual(m.step, .done, "the user may leave it running")
        XCTAssertEqual(started, 1, "…and it was not started twice")
        let done = make(.done)
        done.onFinish = { finished.append($0) }
        XCTAssertEqual(done.primaryTitle, "Open Offload")
        done.performPrimary()
        done.skipAll()
        XCTAssertEqual(finished, [true, false])
        XCTAssertEqual(OnboardingModel.Step.allCases.count, 7)
        XCTAssertEqual(make(.welcome).progress, 0); XCTAssertEqual(make(.done).progress, 1)
    }

    func testAnalysisStateFraction() {
        var a = AnalysisState()
        XCTAssertEqual(a.fraction, 0)
        a.total = 120; a.done = 30
        XCTAssertEqual(a.fraction, 0.25, accuracy: 1e-9)
        a.done = 500
        XCTAssertEqual(a.fraction, 1, "never beyond 100%")
    }
}

final class GraphTests: XCTestCase {
    let notes: [(path: String, title: String, body: String)] = [
        ("README.md", "About", "[[Apartment]] [[Acme]] [[Ghost]]"),
        ("Home/Apartment.md", "Apartment", "See [[Acme|the company]] and [[apartment]] (itself) and [[Taxes#2026]]."),
        ("Home/Taxes.md", "Taxes", "No links."),
        ("Work/Acme.md", "Acme", "[[Apartment]] again, and [[Taxes]]."),
        ("Work/Priya.md", "Priya", "Isolated."),
    ]

    func testEdgesResolveTitlesAliasesAndHeadingsAndDropGhostsAndSelfLinks() {
        let g = KnowledgeGraph.build(notes: notes)
        XCTAssertEqual(g.nodes.map(\.id), ["Home/Apartment.md", "Home/Taxes.md", "README.md", "Work/Acme.md", "Work/Priya.md"], "stable order")
        func name(_ i: Int) -> String { g.nodes[i].title }
        let pairs = Set(g.edges.map { Set([name($0.0), name($0.1)]) })
        XCTAssertEqual(pairs, [["About", "Apartment"], ["About", "Acme"], ["Apartment", "Acme"], ["Apartment", "Taxes"], ["Acme", "Taxes"]])
        XCTAssertEqual(g.edges.count, 5, "duplicates and Apartment->Acme / Acme->Apartment collapse; self-link and [[Ghost]] vanish")
        XCTAssertEqual(g.nodes.first { $0.title == "Priya" }?.degree, 0)
        XCTAssertEqual(g.nodes.first { $0.title == "Apartment" }?.degree, 3)
        XCTAssertEqual(g.domains, ["Home", "Work"])
        XCTAssertEqual(g.nodes.first { $0.id == "README.md" }?.domainIndex, -1, "the overview belongs to no folder")
    }

    func testLayoutIsDeterministicFiniteBoundedAndGroupsFolders() {
        var many: [(path: String, title: String, body: String)] = [("README.md", "About", "")]
        for d in 0..<3 { for i in 0..<10 { many.append(("D\(d)/N\(i).md", "D\(d) N\(i)", i == 0 ? "" : "[[D\(d) N0]] [[D\(d) N\((i % 9) + 1)]]")) } }
        let g = KnowledgeGraph.build(notes: many)
        let a = GraphLayout.positions(for: g), b = GraphLayout.positions(for: g)
        XCTAssertEqual(a, b, "same input, same picture")
        XCTAssertEqual(a.count, g.nodes.count)
        XCTAssertTrue(a.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1.0001 && abs($0.y) <= 1.0001 })
        func dist(_ i: Int, _ j: Int) -> Double { Double(hypot(a[i].x - a[j].x, a[i].y - a[j].y)) }
        var intra = [Double](), inter = [Double]()
        for i in g.nodes.indices { for j in (i + 1)..<g.nodes.count where g.nodes[i].domainIndex >= 0 && g.nodes[j].domainIndex >= 0 {
            if g.nodes[i].domainIndex == g.nodes[j].domainIndex { intra.append(dist(i, j)) } else { inter.append(dist(i, j)) } } }
        XCTAssertLessThan(intra.reduce(0, +) / Double(intra.count), inter.reduce(0, +) / Double(inter.count), "notes of one folder sit together")
        let points = Set(a.map { "\(Int($0.x * 1000)),\(Int($0.y * 1000))" })
        XCTAssertEqual(points.count, a.count, "no two stars on top of each other")
    }

    func testDegenerateGraphs() {
        XCTAssertTrue(GraphLayout.positions(for: KnowledgeGraph.build(notes: [])).isEmpty)
        XCTAssertEqual(GraphLayout.positions(for: KnowledgeGraph.build(notes: [("A/x.md", "x", "")])), [.zero])
        let two = GraphLayout.positions(for: KnowledgeGraph.build(notes: [("A/x.md", "x", "[[y]]"), ("A/y.md", "y", "")]))
        XCTAssertEqual(two.count, 2); XCTAssertTrue(two.allSatisfy { $0.x.isFinite })
    }
}

final class HomeTextTests: XCTestCase {
    func testGreetingFollowsTheClock() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: h))! }
        XCTAssertEqual(HomeText.greeting(at: at(8), calendar: cal), "Good morning")
        XCTAssertEqual(HomeText.greeting(at: at(13), calendar: cal), "Good afternoon")
        XCTAssertEqual(HomeText.greeting(at: at(20), calendar: cal), "Good evening")
        XCTAssertEqual(HomeText.greeting(at: at(2), calendar: cal), "Still up?")
    }

    func testRelativeTimes() {
        let now = Date()
        XCTAssertEqual(HomeText.relative(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertTrue(HomeText.relative(now.addingTimeInterval(-3 * 3600), now: now).contains("3 hours"))
        XCTAssertTrue(HomeText.relative(now.addingTimeInterval(-26 * 3600), now: now).contains("1 day") || HomeText.relative(now.addingTimeInterval(-26 * 3600), now: now).contains("yesterday"))
    }
}

/// Every screen must render something real (not an empty frame) and, when motion is off, identically twice.
@MainActor
final class ScreenRenderTests: XCTestCase {
    func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        let r = ImageRenderer(content: view.environment(\.stillMotion, true)); r.scale = 1
        return r.cgImage.map { NSBitmapImageRep(cgImage: $0) }
    }
    /// Standard deviation of brightness over a sample: a blank or single-color image scores ~0.
    func variety(_ img: NSBitmapImageRep) -> Double {
        var vals = [Double]()
        for y in stride(from: 0, to: img.pixelsHigh, by: 9) { for x in stride(from: 0, to: img.pixelsWide, by: 9) {
            if let c = img.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { vals.append(Double(c.redComponent + c.greenComponent + c.blueComponent) / 3) } } }
        let mean = vals.reduce(0, +) / Double(max(1, vals.count))
        return (vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, vals.count))).squareRoot()
    }
    func fixture(_ step: OnboardingModel.Step) -> OnboardingModel {
        let m = OnboardingModel(startAt: step)
        m.sources = [SourceOption(id: "a", title: "Apple Notes", subtitle: "Your notes", symbol: "note.text", isOn: true)]
        m.permissions = [PermissionRow(id: "fda", title: "Full Disk Access", detail: "d", status: .needsAction, symbol: "internaldrive", required: true)]
        m.models = [ModelOption(id: "builtin", title: "Built in", subtitle: "s", readiness: .ready, statusText: "Ready")]
        return m
    }

    func testEveryOnboardingScreenRendersContent() throws {
        for step in OnboardingModel.Step.allCases {
            let img = try XCTUnwrap(render(OnboardingView(model: fixture(step), fixedPhase: 2.6)), "\(step)")
            XCTAssertEqual(img.pixelsWide, Int(OnboardingView.size.width))
            XCTAssertGreaterThan(variety(img), 0.03, "\(step) looks blank")
        }
    }

    /// Largest per-channel difference (0...255) between two same-sized renders.
    func maxDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 255 }
        var worst = 0.0
        for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
            guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 255 }
            worst = max(worst, abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent), abs(p.blueComponent - q.blueComponent), abs(p.alphaComponent - q.alphaComponent))
        } }
        return worst * 255
    }

    func testStillsAreDeterministicAndHomeRenders() throws {
        let a = try XCTUnwrap(render(OnboardingView(model: fixture(.welcome), fixedPhase: 2.6)))
        let b = try XCTUnwrap(render(OnboardingView(model: fixture(.welcome), fixedPhase: 2.6)))
        // Not bit-for-bit: the renderer's GPU blur differs by up to ~2/255 between its first renders and later ones
        // (measured; stable after warm-up). A moving animation would differ by far more.
        XCTAssertLessThan(maxDifference(a, b), 4, "with motion off the picture does not change")
        let other = try XCTUnwrap(render(OnboardingView(model: fixture(.welcome), fixedPhase: 4.1)))
        XCTAssertGreaterThan(maxDifference(a, other), 12, "…while a different phase does visibly change it, so the check above can fail")
        let home = HomeModel()
        home.data.itemsRead = 1284; home.data.notes = 47
        home.data.sources = [HomeSource(id: "a", title: "Apple Notes", symbol: "note.text", itemCount: 3, status: .ok, detail: "Up to date")]
        XCTAssertGreaterThan(variety(try XCTUnwrap(render(HomeView(model: home, fixedPhase: 2.6)))), 0.03)
    }
}
