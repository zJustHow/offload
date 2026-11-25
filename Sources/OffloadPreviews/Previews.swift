import AppKit
import OffloadUI
import SwiftUI

/// The app icon: a deep-night squircle holding a softly glowing orb with a sparkle, drawn on the
/// macOS icon grid (artwork inset to ~80% of the canvas, as the system expects).
struct AppIconArt: View {
    var side: CGFloat
    var body: some View {
        let art = side * 0.8, corner = art * 0.2237
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1A2250), Color(hex: 0x2B1B52), Color(hex: 0x0B0F24)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: art, height: art)
                .shadow(color: .black.opacity(0.35), radius: side * 0.02, y: side * 0.012)
            ZStack {   // everything luminous stays inside the silhouette, so the edge is crisp at every size
                IntelligenceGlow(shape: RoundedRectangle(cornerRadius: corner, style: .continuous), phase: 2.6, intensity: 0.8, lineWidth: max(1, art * 0.016))
                IntelligenceOrb(size: art * 0.54, phase: 2.6)
                Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(.white.opacity(0.95))
                    .frame(width: art * 0.22, height: art * 0.22).shadow(color: .white.opacity(0.6), radius: art * 0.03)
            }
            .frame(width: art, height: art)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .frame(width: side, height: side)
        .environment(\.stillMotion, true)
    }
}

/// Renders the UI components to PNG files so their look can be checked without running the app:
/// `offload-previews <output-directory>`; `offload-previews --icon <name.iconset>` writes the app icon.
@main
struct Previews {
    @MainActor static func main() async {
        if CommandLine.arguments.dropFirst().first == "--icon" {
            let out = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon.iconset", isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
                let px = base * scale
                let r = ImageRenderer(content: AppIconArt(side: CGFloat(px))); r.scale = 1
                guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { print("FAILED \(px)"); exit(1) }
                try? png.write(to: out.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
            }
            print("wrote \(out.path)"); return
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The real notch of a 14-inch MacBook Pro: 185 x 32 pt on a 1512-pt-wide screen.
        let geo = NotchGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        let phase = 2.6

        func scene(_ model: NotchModel, glowPhase: Double = phase) -> some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x1B2A55), Color(hex: 0x3A1F5E), Color(hex: 0x0E1220)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.black.opacity(0.28)).frame(height: geo.height).frame(maxHeight: .infinity, alignment: .top)
                NotchShape(topRadius: 6, bottomRadius: 12).fill(.black).frame(width: geo.width, height: geo.height)   // the hardware notch
                NotchView(model: model, geometry: geo, fixedPhase: glowPhase)
            }
            .frame(width: 760, height: NotchView.canvas.height, alignment: .top)
            .frame(width: 760, height: 330, alignment: .top)   // anchor to the top edge, as the real panel is
            .clipped()
        }

        func save<V: View>(_ view: V, _ name: String, size: CGSize? = nil) {
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let size { r.proposedSize = ProposedViewSize(size) }
            guard let cg = r.cgImage else { print("FAILED to render \(name)"); return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            print("wrote \(name).png \(cg.width)x\(cg.height)")
        }

        let input = NotchModel(); input.present()
        save(scene(input), "notch-input")

        let thinking = NotchModel(); thinking.present(); thinking.input = "when is my flight"; thinking.submit()
        save(scene(thinking), "notch-thinking")
        save(scene(thinking, glowPhase: 5.1), "notch-thinking-b")

        let working = NotchModel(); working.present(mode: .act); working.input = "reply"; working.submit()
        for s in ["Searching your notes for the landlord", "Opening Mail", "Clicking the reply field", "Typing the draft"] { working.addStep(s) }
        save(scene(working), "notch-working")

        let confirm = NotchModel(); confirm.present(mode: .act); confirm.input = "x"; confirm.submit(); confirm.addStep("Sending")
        Task { @MainActor in _ = await confirm.requestConfirmation("click(x=812, y=640): press Send to email the lease question to Mr. Alvarez") }
        await Task.yield()
        save(scene(confirm), "notch-confirm")

        let answer = NotchModel(); answer.present(); answer.input = "x"; answer.submit()
        answer.finish(answer: "Your flight is UA 837 from San Francisco to Shanghai Pudong on March 3 at 11:40, seat 24A. The confirmation code is K7P2QX. The return leg is on March 21 with a layover in Tokyo.", sources: ["Flight Booking", "Home/Travel.md"])
        save(scene(answer), "notch-answer")

        let err = NotchModel(); err.present(); err.input = "x"; err.submit(); err.fail("Claude usage limit reached. Try again later.")
        save(scene(err), "notch-error")

        let compact = NotchModel(); compact.showBackground(status: "Drafting reply…")
        save(scene(compact), "notch-compact")

        // Glow ring at four moments, to check the colors loop seamlessly and drift.
        let ring = HStack(spacing: 28) {
            ForEach([0.0, 1.3, 2.6, 3.9], id: \.self) { t in
                IntelligenceGlow(shape: RoundedRectangle(cornerRadius: 26, style: .continuous), phase: t, intensity: 1, lineWidth: 2.5).frame(width: 150, height: 110)
            }
        }.padding(40).background(Color.black)
        save(ring, "glow-frames")

        let kit = ZStack {
            IntelligenceBackground(phase: 3, dark: true)
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    IntelligenceOrb(size: 34, phase: 1.5)
                    ShimmerText("Thinking about your question…", font: .system(size: 18, weight: .medium), phase: 0.9)
                }
                Text("Where did I put the landlord's number?").foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 12).frame(width: 380, alignment: .leading)
                    .glassCard().intelligenceGlowBorder(active: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggestion").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text("Confirm the term sheet with Orion by Friday").foregroundStyle(.white).font(.headline)
                }.padding(16).frame(width: 380, alignment: .leading).glassCard()
            }
        }.frame(width: 520, height: 330)
        save(kit, "ui-kit")

        // First-run guide, every step.
        for (name, step, analysis) in [("welcome", OnboardingModel.Step.welcome, AnalysisState()), ("sources", .sources, AnalysisState()), ("permissions", .permissions, AnalysisState()),
                                       ("models", .models, AnalysisState()), ("privacy", .privacy, AnalysisState()), ("analyze-idle", .analyze, AnalysisState()),
                                       ("analyze-running", .analyze, Fixtures.running), ("analyze-done", .analyze, Fixtures.finished), ("done", .done, AnalysisState())] {
            let m = Fixtures.onboarding(step, analysis: analysis)
            save(OnboardingView(model: m, fixedPhase: 2.6).environment(\.stillMotion, true), "onboarding-\(name)")
        }

        save(HomeView(model: Fixtures.home(), fixedPhase: 2.6).environment(\.stillMotion, true), "home")
        save(HomeView(model: Fixtures.home(running: true), fixedPhase: 2.6).environment(\.stillMotion, true), "home-running")

        // The knowledge constellation, from a small invented vault.
        var vault: [(path: String, title: String, body: String)] = [("README.md", "Overview", "[[Apartment]] [[Acme Corp]] [[Japan trip]] [[Health]]")]
        let folders: [(String, [String])] = [
            ("Home", ["Apartment", "Lease", "Taxes", "Utilities", "Insurance", "Landlord"]),
            ("Work", ["Acme Corp", "Q3 roadmap", "Priya", "Term sheet", "Hiring", "Board deck", "Orion"]),
            ("Travel", ["Japan trip", "Flights", "Hotels", "Visa", "Packing"]),
            ("Health", ["Health", "Dentist", "Prescriptions", "Gym"]),
            ("People", ["Mr. Alvarez", "Sam", "Mom", "Priya"]),
        ]
        for (folder, titles) in folders {
            for (i, t) in titles.enumerated() {
                let next = titles[(i + 1) % titles.count], hub = titles[0]
                vault.append(("\(folder)/\(t).md", t, i == 0 ? titles.dropFirst().map { "[[\($0)]]" }.joined(separator: " ") : "Part of [[\(hub)]]; see also [[\(next)]]."))
            }
        }
        vault.append(("Work/Cross.md", "Cross", "[[Apartment]] [[Japan trip]] [[Acme Corp]] [[Mr. Alvarez]]"))
        let graph = KnowledgeGraph.build(notes: vault)
        save(ZStack { Color(hex: 0x0E1220); GraphView(graph: graph, points: GraphLayout.positions(for: graph), selection: "Home/Lease.md", onSelect: { _ in }) }.frame(width: 760, height: 520), "knowledge-graph")

        let edge = ZStack { Color(hex: 0x10131F); ScreenEdgeGlowView(visible: true, phase: 2.0).padding(2) }.frame(width: 640, height: 400)
        save(edge, "edge-glow")
    }
}
