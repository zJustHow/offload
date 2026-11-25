import AppKit
import SwiftUI
import XCTest
@testable import OffloadUI

final class NotchGeometryTests: XCTestCase {
    func testRealMacBookProNotchNumbers() {
        // Measured on this Mac: 1512x982 screen, menu-bar areas 663.5 wide on each side, 32 pt tall.
        let g = NotchGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        XCTAssertTrue(g.hasHardwareNotch)
        XCTAssertEqual(g.width, 185, accuracy: 0.01)
        XCTAssertEqual(g.height, 32)
        XCTAssertEqual(g.rect.midX, 756, accuracy: 0.01, "centered on the screen")
        XCTAssertEqual(g.rect.maxY, 982, "flush with the top edge")
        XCTAssertTrue(g.contains(CGPoint(x: 756, y: 975)))
        XCTAssertTrue(g.contains(CGPoint(x: 756 + 92 + 4, y: 975)), "a few points of forgiveness at the sides")
        XCTAssertFalse(g.contains(CGPoint(x: 756, y: 900)))
        XCTAssertFalse(g.contains(CGPoint(x: 300, y: 975)))
    }

    func testMacsWithoutANotchGetACenteredPill() {
        let g = NotchGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0, topLeft: nil, topRight: nil)
        XCTAssertFalse(g.hasHardwareNotch)
        XCTAssertEqual(g.rect.midX, 960)
        XCTAssertEqual(g.rect.maxY, 1080)
        XCTAssertGreaterThan(g.width, 100)
    }

    func testLayoutNeverShrinksBelowTheNotchAndAnswersGrowThenCap() {
        let notch = CGSize(width: 185, height: 32)
        for phase in [NotchModel.Phase.hidden, .compact, .input, .thinking, .working, .confirm, .answer, .error] {
            let s = NotchLayout.size(phase: phase, notch: notch, steps: 3, answerLength: 200)
            XCTAssertGreaterThanOrEqual(s.width, notch.width, "\(phase)")
            XCTAssertGreaterThanOrEqual(s.height, notch.height, "\(phase)")
            XCTAssertLessThanOrEqual(s.width, NotchView.canvas.width - 60, "\(phase): leave room for the glow")
            XCTAssertLessThanOrEqual(s.height, NotchView.canvas.height - 60, "\(phase)")
        }
        let short = NotchLayout.size(phase: .answer, notch: notch, answerLength: 40).height
        let long = NotchLayout.size(phase: .answer, notch: notch, answerLength: 600).height
        let huge = NotchLayout.size(phase: .answer, notch: notch, answerLength: 60_000).height
        XCTAssertLessThan(short, long)
        XCTAssertEqual(huge, 32 + 380, "capped; longer answers scroll")
        XCTAssertGreaterThan(NotchLayout.size(phase: .working, notch: notch, steps: 4).height, NotchLayout.size(phase: .working, notch: notch, steps: 1).height)
        XCTAssertEqual(NotchLayout.size(phase: .working, notch: notch, steps: 99).height, NotchLayout.size(phase: .working, notch: notch, steps: 4).height)
        XCTAssertGreaterThan(NotchLayout.radii(phase: .input).bottom, NotchLayout.radii(phase: .compact).bottom, "tight when tucked in, generous when open")
    }
}

@MainActor
final class NotchModelTests: XCTestCase {
    func testHappyPathAskFlow() {
        let m = NotchModel()
        var submitted: [(String, NotchModel.Mode)] = []
        m.onSubmit = { submitted.append(($0, $1)) }
        XCTAssertEqual(m.phase, .hidden)
        m.present()
        XCTAssertEqual(m.phase, .input)
        m.submit()
        XCTAssertEqual(m.phase, .input, "empty input is ignored")
        m.input = "  when is my flight  "
        m.submit()
        XCTAssertEqual(m.phase, .thinking)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted[0].0, "when is my flight", "trimmed")
        XCTAssertEqual(m.input, "", "the field clears once sent")
        XCTAssertEqual(m.glow, 1, "full glow while thinking")
        m.finish(answer: "March 3", sources: ["Flight.md"])
        XCTAssertEqual(m.phase, .answer)
        XCTAssertEqual(m.answer, "March 3")
        XCTAssertEqual(m.sources, ["Flight.md"])
        m.dismiss()
        XCTAssertEqual(m.phase, .hidden)
        XCTAssertEqual(m.answer, "")
        XCTAssertEqual(m.glow, 0)
    }

    func testSecondSubmitWhileBusyIsIgnoredAndStepsAreCapped() {
        let m = NotchModel()
        var count = 0
        m.onSubmit = { _, _ in count += 1 }
        m.present(mode: .act)
        XCTAssertEqual(m.mode, .act)
        m.input = "do it"; m.submit()
        m.input = "again"; m.submit()
        XCTAssertEqual(count, 1)
        for i in 0..<20 { m.addStep("step \(i)") }
        XCTAssertEqual(m.phase, .working)
        XCTAssertEqual(m.steps.count, NotchModel.maxSteps)
        XCTAssertEqual(m.steps.last, "step 19")
        XCTAssertEqual(m.status, "step 19")
        let idle = NotchModel()
        idle.addStep("ignored")
        XCTAssertTrue(idle.steps.isEmpty, "steps only count during a task")
    }

    func testConfirmationResolvesAndADismissedQuestionIsNeverAnApproval() async {
        let m = NotchModel()
        m.present(); m.input = "x"; m.submit(); m.addStep("sending")
        let allow = Task { await m.requestConfirmation("press Send") }
        await Task.yield()
        XCTAssertEqual(m.phase, .confirm)
        XCTAssertEqual(m.confirmation, "press Send")
        m.resolveConfirmation(true)
        let r1 = await allow.value
        XCTAssertTrue(r1)
        XCTAssertEqual(m.phase, .working)
        XCTAssertNil(m.confirmation)

        let deny = Task { await m.requestConfirmation("delete it") }
        await Task.yield()
        m.resolveConfirmation(false)
        let r2 = await deny.value
        XCTAssertFalse(r2)

        let dismissed = Task { await m.requestConfirmation("buy it") }
        await Task.yield()
        m.dismiss()
        let r3 = await dismissed.value
        XCTAssertFalse(r3, "closing the notch while a question is open must answer NO")

        m.present(); m.input = "x"; m.submit()
        let first = Task { await m.requestConfirmation("one") }
        await Task.yield()
        let second = Task { await m.requestConfirmation("two") }
        await Task.yield()
        let firstResult = await first.value
        XCTAssertFalse(firstResult, "a newer question supersedes (and denies) the older one")
        XCTAssertEqual(m.confirmation, "two")
        m.resolveConfirmation(true)
        let secondResult = await second.value
        XCTAssertTrue(secondResult)
    }

    func testStopFailAndBackgroundBehaviour() async {
        let m = NotchModel()
        var stopped = 0, dismissed = 0
        m.onStop = { stopped += 1 }; m.onDismiss = { dismissed += 1 }
        m.showBackground(status: "Drafting…")
        XCTAssertEqual(m.phase, .compact)
        m.present()
        XCTAssertEqual(m.phase, .input, "the user can open the assistant over a background activity")
        m.input = "x"; m.submit()
        m.stop()
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(m.phase, .hidden)
        XCTAssertEqual(dismissed, 1)

        m.present(); m.input = "x"; m.submit()
        let pending = Task { await m.requestConfirmation("q") }
        await Task.yield()
        m.fail("Claude usage limit reached")
        let pendingResult = await pending.value
        XCTAssertFalse(pendingResult)
        XCTAssertEqual(m.phase, .error)
        XCTAssertEqual(m.errorText, "Claude usage limit reached")
        XCTAssertEqual(m.glow, 0)
        m.showBackground(status: "ignored while an error is showing")
        XCTAssertEqual(m.phase, .error)
    }

    func testAnswerGlowSettlesAfterAMoment() async throws {
        let m = NotchModel()
        m.present(); m.input = "x"; m.submit()
        m.finish(answer: "ok")
        XCTAssertGreaterThan(m.glow, 0)
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertEqual(m.glow, 0, "the glow flares while thinking and settles once there is something to read")
        XCTAssertEqual(m.phase, .answer)
    }
}

final class StyleTests: XCTestCase {
    func testGradientStopsFormAClosedMonotoneRingAtEveryMoment() {
        for layer in 0..<4 {
            for t in stride(from: 0.0, to: 60.0, by: 0.37) {
                let stops = IntelligenceStyle.gradientStops(phase: t, layer: layer)
                XCTAssertEqual(stops.count, IntelligenceStyle.hexes.count + 1)
                XCTAssertEqual(stops.first?.location, 0)
                XCTAssertEqual(stops.last?.location, 1)
                XCTAssertEqual(stops.first?.color, stops.last?.color, "first and last share a color: the sweep closes seamlessly")
                for (a, b) in zip(stops, stops.dropFirst()) { XCTAssertLessThan(a.location, b.location, "stops never cross (crossing would make colors jump)") }
                XCTAssertTrue(stops.allSatisfy { (0...1).contains($0.location) })
            }
        }
        // It really moves.
        XCTAssertNotEqual(IntelligenceStyle.gradientStops(phase: 0, layer: 0).map(\.location), IntelligenceStyle.gradientStops(phase: 2, layer: 0).map(\.location))
        XCTAssertNotEqual(IntelligenceStyle.gradientStops(phase: 1, layer: 0).map(\.location), IntelligenceStyle.gradientStops(phase: 1, layer: 2).map(\.location), "layers are out of step")
    }

    func testNotchShapeStaysInsideItsRectAndMorphs() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        for (t, b) in [(6.0, 12.0), (10, 28), (0, 0), (400, 400)] {
            let p = NotchShape(topRadius: t, bottomRadius: b).path(in: rect)
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(p.boundingRect), "radii \(t)/\(b)")
            XCTAssertFalse(p.isEmpty)
            XCTAssertTrue(p.contains(CGPoint(x: 150, y: 60)))
            if t > 0 { XCTAssertFalse(p.contains(CGPoint(x: 1, y: 100)), "the shoulders pull the sides in from the corners") }
        }
        var s = NotchShape(topRadius: 6, bottomRadius: 12)
        s.animatableData = AnimatablePair(10, 28)
        XCTAssertEqual(s.topRadius, 10); XCTAssertEqual(s.bottomRadius, 28)
        XCTAssertGreaterThan(NotchShape(topRadius: 6, bottomRadius: 12).inset(by: 2).path(in: rect).boundingRect.minX, 0)
    }

    func testColorHex() {
        let c = NSColor(Color(hex: 0xBC82F3)).usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 0xBC / 255.0, accuracy: 0.003)
        XCTAssertEqual(c.blueComponent, 0xF3 / 255.0, accuracy: 0.003)
    }
}

/// Renders the real view and looks at the pixels: the glow must exist while thinking and be gone
/// when the model says there is none (otherwise a regression could silently draw nothing).
@MainActor
final class NotchRenderTests: XCTestCase {
    let geo = NotchGeometry.compute(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))

    func render(_ model: NotchModel, phase: Double = 2.6) -> NSBitmapImageRep? {
        let view = ZStack(alignment: .top) { Color.black; NotchView(model: model, geometry: geo, fixedPhase: phase) }
            .frame(width: NotchView.canvas.width, height: NotchView.canvas.height, alignment: .top)
        let r = ImageRenderer(content: view); r.scale = 1
        return r.cgImage.map { NSBitmapImageRep(cgImage: $0) }
    }

    /// Brightest saturated pixel in a horizontal band (a glow shows up as color on a black backdrop).
    func colorfulness(_ img: NSBitmapImageRep, y: Int, xRange: ClosedRange<Int>) -> CGFloat {
        var best: CGFloat = 0
        for x in xRange {
            guard let c = img.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let mx = max(c.redComponent, c.greenComponent, c.blueComponent), mn = min(c.redComponent, c.greenComponent, c.blueComponent)
            best = max(best, (mx - mn) * mx)
        }
        return best
    }

    func testThinkingGlowIsDrawnJustBelowTheSurfaceAndAbsentWhenIdle() throws {
        let thinking = NotchModel(); thinking.present(); thinking.input = "q"; thinking.submit()
        let img = try XCTUnwrap(render(thinking))
        let surface = NotchLayout.size(phase: .thinking, notch: geo.rect.size)
        // The halo spills a few points below the surface's bottom edge.
        let below = Int(surface.height) + 3
        let w = Int(NotchView.canvas.width)
        let lit = colorfulness(img, y: below, xRange: (w / 2 - 150)...(w / 2 + 150))
        XCTAssertGreaterThan(lit, 0.04, "a visible, colorful glow under the surface while thinking")

        let off = NotchModel(); off.present(); off.input = "q"; off.submit(); off.fail("x")   // error => glow 0
        let img2 = try XCTUnwrap(render(off))
        let errSurface = NotchLayout.size(phase: .error, notch: geo.rect.size)
        let dark = colorfulness(img2, y: Int(errSurface.height) + 3, xRange: (w / 2 - 150)...(w / 2 + 150))
        XCTAssertLessThan(dark, 0.03, "no glow when the model says glow = 0")
        XCTAssertGreaterThan(lit, dark * 3)
    }

    /// Regression: a mask offset once erased the glow of every surface shorter than ~100 pt.
    func testCompactAndThinkingSurfacesBothGlow() throws {
        let w = Int(NotchView.canvas.width)
        let compact = NotchModel(); compact.showBackground(status: "Drafting reply…")
        let c = try XCTUnwrap(render(compact))
        let cs = NotchLayout.size(phase: .compact, notch: geo.rect.size)
        XCTAssertGreaterThan(colorfulness(c, y: Int(cs.height) + 2, xRange: (w / 2 - 100)...(w / 2 + 100)), 0.05, "compact: glow under the notch band")
        let thinking = NotchModel(); thinking.present(); thinking.input = "q"; thinking.submit()
        let t = try XCTUnwrap(render(thinking))
        let ts = NotchLayout.size(phase: .thinking, notch: geo.rect.size)
        XCTAssertGreaterThan(colorfulness(t, y: Int(ts.height) + 2, xRange: (w / 2 - 100)...(w / 2 + 100)), 0.08, "thinking: 84 pt tall, below the old mask's cutoff")
    }

    func testHiddenRendersNothingAndSurfacesStayWithinTheCanvas() throws {
        let hidden = try XCTUnwrap(render(NotchModel()))
        XCTAssertLessThan(colorfulness(hidden, y: 20, xRange: 0...Int(NotchView.canvas.width) - 1), 0.001)
        let answer = NotchModel(); answer.present(); answer.input = "q"; answer.submit(); answer.finish(answer: String(repeating: "word ", count: 400))
        let img = try XCTUnwrap(render(answer))
        XCTAssertEqual(img.pixelsWide, Int(NotchView.canvas.width))
        let s = NotchLayout.size(phase: .answer, notch: geo.rect.size, answerLength: 2_000)
        XCTAssertLessThanOrEqual(s.height + 40, NotchView.canvas.height)
    }
}
