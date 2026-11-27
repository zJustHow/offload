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
        for phase in [NotchModel.Phase.hidden, .compact, .input, .thinking, .working, .confirm, .question, .answer, .error] {
            let s = NotchLayout.size(phase: phase, notch: notch, steps: 3, answerLength: 200, checklist: 9, planLines: 20, options: 9)
            XCTAssertGreaterThanOrEqual(s.width, notch.width, "\(phase)")
            XCTAssertGreaterThanOrEqual(s.height, notch.height, "\(phase)")
            XCTAssertLessThanOrEqual(s.width, NotchView.canvas.width - 60, "\(phase): leave room around the surface")
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

final class GlassFadeTests: XCTestCase {
    func testOnlyALongAnswerFadesToGlass() {
        XCTAssertFalse(NotchLayout.fadesToGlass(phase: .answer, answerLength: NotchLayout.longAnswer), "at the limit it still fits as a plain card")
        XCTAssertTrue(NotchLayout.fadesToGlass(phase: .answer, answerLength: NotchLayout.longAnswer + 1))
        for phase in [NotchModel.Phase.hidden, .compact, .input, .thinking, .working, .confirm, .question, .error] {
            XCTAssertFalse(NotchLayout.fadesToGlass(phase: phase, answerLength: 60_000), "\(phase) keeps the plain black surface")
        }
    }

    private func opacities(_ stops: [Gradient.Stop]) -> [CGFloat] {
        stops.map { s in NSColor(s.color).usingColorSpace(.sRGB)?.alphaComponent ?? -1 }
    }

    func testNoFadeIsAPlainBlackCard() {
        XCTAssertTrue(opacities(GlassFade.surfaceStops(fade: 0)).allSatisfy { abs($0 - 1) < 0.001 }, "fade 0 must be fully opaque everywhere")
    }

    func testFullFadeStaysSolidThenEasesDownToANonZeroFloor() {
        let stops = GlassFade.surfaceStops(fade: 1), a = opacities(stops)
        XCTAssertEqual(a.first ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(a[1], 1, accuracy: 0.001, "solid until the fade starts")
        XCTAssertEqual(a.last ?? 0, CGFloat(GlassFade.floorOpacity), accuracy: 0.005, "never fully clear: the footer must stay readable")
        XCTAssertGreaterThan(a.last ?? 0, 0)
        for (x, y) in zip(a, a.dropFirst()) { XCTAssertGreaterThanOrEqual(x + 0.001, y, "opacity only ever decreases toward the bottom") }
        let locations = stops.map(\.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertEqual(locations.last ?? 0, 1, accuracy: 0.001)
    }

    func testStopLocationsDoNotDependOnFadeSoItInterpolatesCleanly() {
        XCTAssertEqual(GlassFade.surfaceStops(fade: 0).map(\.location), GlassFade.surfaceStops(fade: 1).map(\.location))
        XCTAssertEqual(GlassFade.surfaceStops(fade: 0.5).count, GlassFade.surfaceStops(fade: 1).count)
    }

    func testOutOfRangeFadeIsClamped() {
        XCTAssertEqual(opacities(GlassFade.surfaceStops(fade: 7)), opacities(GlassFade.surfaceStops(fade: 1)))
        XCTAssertEqual(opacities(GlassFade.surfaceStops(fade: -3)), opacities(GlassFade.surfaceStops(fade: 0)))
    }

    func testTextFadesToNothingAtTheBottom() {
        let a = opacities(GlassFade.textStops())
        XCTAssertEqual(a.first ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(a.last ?? 1, 0, accuracy: 0.001)
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
        m.finish(answer: "March 3", sources: ["Flight.md"])
        XCTAssertEqual(m.phase, .answer)
        XCTAssertEqual(m.answer, "March 3")
        XCTAssertEqual(m.sources, ["Flight.md"])
        m.dismiss()
        XCTAssertEqual(m.phase, .hidden)
        XCTAssertEqual(m.answer, "")
    }

    func testReplyModeNeedsNoInstructionAndOffersTheDraftForReview() {
        let m = NotchModel()
        var submitted: [(String, NotchModel.Mode)] = []
        var actions: [(NotchModel.DraftAction, String)] = []
        m.onSubmit = { submitted.append(($0, $1)) }
        m.onDraftAction = { actions.append(($0, $1)) }

        // Ask still ignores an empty field; Reply does not, because "reply to this" is a whole request.
        m.present(mode: .ask); m.submit()
        XCTAssertEqual(m.phase, .input)
        XCTAssertTrue(submitted.isEmpty)
        m.mode = .reply   // what the mode buttons do; `present` is ignored while the field is already open
        m.submit()
        XCTAssertEqual(m.phase, .thinking)
        XCTAssertEqual(m.status, "Drafting reply…")
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted[0].0, "")
        XCTAssertEqual(submitted[0].1, .reply)

        m.finishDraft("Friday at 3pm works.", sources: ["Calendar.md"])
        XCTAssertEqual(m.phase, .answer)
        XCTAssertTrue(m.isDraft)
        XCTAssertEqual(m.answer, "Friday at 3pm works.")
        XCTAssertTrue(actions.isEmpty, "nothing leaves the notch until the user chooses")

        m.copyDraft()
        XCTAssertTrue(m.copied)
        XCTAssertEqual(m.phase, .answer, "copying keeps the draft up, so it can still be inserted")
        XCTAssertEqual(actions.map(\.1), ["Friday at 3pm works."])

        m.insertDraft()
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[1].0, .insert)
        XCTAssertEqual(actions[1].1, "Friday at 3pm works.")
        XCTAssertEqual(m.phase, .hidden, "the surface closes so the field underneath gets the keyboard back")
        XCTAssertFalse(m.isDraft)
        XCTAssertFalse(m.copied)
    }

    func testLongSourceNamesAreCutInTheMiddleSoTheButtonsKeepTheirRoom() {
        XCTAssertEqual(NotchView.shortName("Home/Apartment.md"), "Apartment.md")
        let long = NotchView.shortName("Lease from Mr. Alvarez about the security deposit")
        XCTAssertEqual(long.count, 20)
        XCTAssertTrue(long.hasPrefix("Lease from") && long.hasSuffix("deposit") && long.contains("…"), long)
        XCTAssertEqual(NotchView.shortName("exactly-twenty-chars"), "exactly-twenty-chars")
    }

    func testOnlyADraftCanBeCopiedOrInserted() {
        let m = NotchModel()
        var actions = 0
        m.onDraftAction = { _, _ in actions += 1 }
        m.present(); m.input = "x"; m.submit()
        m.finish(answer: "March 3")
        XCTAssertFalse(m.isDraft)
        m.copyDraft(); m.insertDraft()
        XCTAssertEqual(actions, 0, "an answer is not a draft")
        XCTAssertEqual(m.phase, .answer)

        // A draft followed by an ordinary answer must not keep offering Insert.
        m.finishDraft("hello")
        XCTAssertTrue(m.isDraft)
        m.finish(answer: "later answer")
        XCTAssertFalse(m.isDraft)
        // And reopening the notch clears the draft.
        m.finishDraft("hello again")
        m.present()
        XCTAssertFalse(m.isDraft)
        XCTAssertEqual(m.answer, "")
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

    // MARK: Checklist, plans, questions

    func testTheChecklistShowsWhileWorkingGrowsTheSurfaceAndClearsWithTheTask() {
        let m = NotchModel()
        m.setChecklist([.init("a", .active)])
        XCTAssertTrue(m.checklist.isEmpty, "nothing to show before a task is running")
        m.present(mode: .act); m.input = "x"; m.submit()
        m.setChecklist([.init("Find the lease", .done), .init("Write the reply", .active), .init("Show the draft", .pending)])
        XCTAssertEqual(m.phase, .working, "a checklist is progress: it takes the surface out of 'thinking'")
        XCTAssertEqual(m.checklist.map(\.state), [.done, .active, .pending])
        let notch = CGSize(width: 185, height: 32)
        XCTAssertGreaterThan(NotchLayout.size(phase: .working, notch: notch, steps: 1, checklist: 3).height, NotchLayout.size(phase: .working, notch: notch, steps: 1).height)
        XCTAssertEqual(NotchLayout.size(phase: .working, notch: notch, steps: 1, checklist: 40).height, NotchLayout.size(phase: .working, notch: notch, steps: 1, checklist: NotchModel.maxChecklistRows).height, "capped")

        m.finish(answer: "done")
        XCTAssertTrue(m.checklist.isEmpty, "the answer replaces it")
        m.present(mode: .act); m.input = "y"; m.submit()
        XCTAssertTrue(m.checklist.isEmpty, "a new task starts with a clean list")
    }

    func testALongChecklistShowsAWindowAroundTheStepInProgress() {
        let m = NotchModel(); m.present(mode: .act); m.input = "x"; m.submit()
        var items = (0..<10).map { NotchModel.ChecklistItem("step \($0)", $0 < 6 ? .done : .pending) }
        items[6].state = .active
        m.setChecklist(items)
        XCTAssertEqual(m.visibleChecklist.count, NotchModel.maxChecklistRows)
        XCTAssertTrue(m.visibleChecklist.contains { $0.state == .active }, "the step in progress is always visible")
        XCTAssertEqual(m.visibleChecklist.first?.text, "step 5", "one finished step of context before it")
        m.setChecklist(Array(items.prefix(3)))
        XCTAssertEqual(m.visibleChecklist.count, 3)
        m.setChecklist(items.map { var i = $0; i.state = .done; return i })
        XCTAssertEqual(m.visibleChecklist.last?.text, "step 9", "when everything is done, the end of the list")
    }

    func testPlansAndApprovalsOfEveryKindResolveAndDismissalIsNeverAYes() async {
        let m = NotchModel()
        m.present(mode: .act); m.input = "x"; m.submit(); m.addStep("planning")
        let plan = Task { await m.requestApproval(.init(kind: .plan, detail: "Plan: 1. Open Mail 2. Find the thread")) }
        await Task.yield()
        XCTAssertEqual(m.phase, .confirm)
        XCTAssertEqual(m.approval?.kind, .plan)
        let notch = CGSize(width: 185, height: 32)
        XCTAssertEqual(NotchModel.planLines(from: m.approval!.detail).count, 2)
        XCTAssertGreaterThan(NotchLayout.size(phase: .confirm, notch: notch, planLines: 6).height, NotchLayout.size(phase: .confirm, notch: notch, planLines: 2).height, "a longer plan gets a taller surface")
        m.resolveConfirmation(true)
        let go = await plan.value
        XCTAssertTrue(go)
        XCTAssertNil(m.approval)
        XCTAssertEqual(m.phase, .working)

        let external = Task { await m.requestApproval(.init(kind: .needsApproval, detail: "mcp__tasks__add(title=x)", reason: "comes from an external server")) }
        await Task.yield()
        XCTAssertEqual(m.approval?.reason, "comes from an external server")
        XCTAssertEqual(m.confirmation, "mcp__tasks__add(title=x)", "the old property still carries the text")
        m.dismiss()
        let r = await external.value
        XCTAssertFalse(r)
        XCTAssertNil(m.approval)

        m.present(mode: .act); m.input = "x"; m.submit()
        let legacy = Task { await m.requestConfirmation("press Send") }
        await Task.yield()
        XCTAssertEqual(m.approval?.kind, .irreversible, "the original question is the irreversible kind")
        m.resolveConfirmation(false)
        let no = await legacy.value
        XCTAssertFalse(no)
    }

    func testPlanTextBecomesSeparateLines() {
        XCTAssertEqual(NotchModel.planLines(from: "Plan: 1. Open Mail 2. Find the thread 3. Write a reply"), ["1. Open Mail", "2. Find the thread", "3. Write a reply"])
        XCTAssertEqual(NotchModel.planLines(from: "1) Look\n2) Act\n\n3) Check"), ["1) Look", "2) Act", "3) Check"])
        XCTAssertEqual(NotchModel.planLines(from: "Just do the thing"), ["Just do the thing"])
        XCTAssertEqual(NotchModel.planLines(from: "Version 2.5 of the file costs $3. 4 items"), ["Version 2.5 of the file costs $3. 4 items"], "numbers in a sentence are not step markers")
        let long = (1...12).map { "\($0). step" }.joined(separator: "\n")
        let capped = NotchModel.planLines(from: long)
        XCTAssertEqual(capped.count, NotchModel.maxPlanLines)
        XCTAssertEqual(capped.last, "… and 5 more steps")
    }

    func testQuestionsCanBeAnsweredByButtonByTextOrSkippedAndNeverHangWhenDismissed() async {
        let m = NotchModel()
        m.present(mode: .act); m.input = "x"; m.submit(); m.addStep("working")

        let picked = Task { await m.requestAnswer(question: "Which address?", options: ["work", "home", "", "both", "extra", "more"]) }
        await Task.yield()
        XCTAssertEqual(m.phase, .question)
        XCTAssertEqual(m.question, "Which address?")
        XCTAssertEqual(m.options, ["work", "home", "both", "extra"], "blank options are dropped and the list is capped")
        m.answerQuestion("home")
        let a1 = await picked.value
        XCTAssertEqual(a1, "home")
        XCTAssertEqual(m.phase, .working)
        XCTAssertTrue(m.options.isEmpty && m.question.isEmpty)

        let typed = Task { await m.requestAnswer(question: "What time?") }
        await Task.yield()
        m.answerQuestion()
        XCTAssertEqual(m.phase, .question, "an empty answer is not an answer")
        m.answerInput = "  Friday 3pm  "
        m.answerQuestion()
        let a2 = await typed.value
        XCTAssertEqual(a2, "Friday 3pm")
        XCTAssertEqual(m.answerInput, "")

        let skipped = Task { await m.requestAnswer(question: "Anything else?") }
        await Task.yield()
        m.skipQuestion()
        let a3 = await skipped.value
        XCTAssertNil(a3)

        let dismissed = Task { await m.requestAnswer(question: "Still there?") }
        await Task.yield()
        m.dismiss()
        let a4 = await dismissed.value
        XCTAssertNil(a4, "closing the notch answers nothing, and the assistant is not left waiting")

        m.present(mode: .act); m.input = "x"; m.submit()
        let first = Task { await m.requestAnswer(question: "one") }
        await Task.yield()
        let second = Task { await m.requestAnswer(question: "two") }
        await Task.yield()
        let firstResult = await first.value
        XCTAssertNil(firstResult, "a newer question supersedes the older one")
        XCTAssertEqual(m.question, "two")
        m.fail("model gone")
        let secondResult = await second.value
        XCTAssertNil(secondResult)
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
        m.showBackground(status: "ignored while an error is showing")
        XCTAssertEqual(m.phase, .error)
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

/// Renders the real view and looks at the pixels: the notch must stay black, white and gray only.
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

    /// Brightest saturated pixel in a horizontal band (color on the black backdrop shows up here).
    func colorfulness(_ img: NSBitmapImageRep, y: Int, xRange: ClosedRange<Int>) -> CGFloat {
        colorfulness(img, rows: [y], xRange: xRange, step: 1)
    }

    /// The same over several rows, sampling every `step`-th column.
    func colorfulness<Rows: Sequence>(_ img: NSBitmapImageRep, rows: Rows, xRange: ClosedRange<Int>, step: Int) -> CGFloat where Rows.Element == Int {
        var best: CGFloat = 0
        for y in rows {
            for x in stride(from: xRange.lowerBound, through: xRange.upperBound, by: step) {
                guard let c = img.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let mx = max(c.redComponent, c.greenComponent, c.blueComponent), mn = min(c.redComponent, c.greenComponent, c.blueComponent)
                best = max(best, (mx - mn) * mx)
            }
        }
        return best
    }

    /// Every state, drawn for real: nothing on screen may carry a hue. The notch is black, white and
    /// gray only (no colored glow around the edge, no accent colors on buttons or icons).
    func testEveryStateIsBlackWhiteAndGrayOnly() throws {
        let w = Int(NotchView.canvas.width), h = Int(NotchView.canvas.height)
        func model(_ setup: (NotchModel) -> Void) -> NotchModel { let m = NotchModel(); setup(m); return m }
        let states: [(String, NotchModel)] = [
            ("compact", model { $0.showBackground(status: "Drafting reply…") }),
            ("input", model { $0.present() }),
            ("thinking", model { $0.present(); $0.input = "q"; $0.submit() }),
            ("working", model { $0.present(mode: .act); $0.input = "x"; $0.submit(); $0.addStep("Opening Mail")
                $0.setChecklist([.init("Find the lease", .done), .init("Write the reply", .active), .init("Show the draft", .pending)]) }),
            ("answer", model { $0.present(); $0.input = "q"; $0.submit(); $0.finish(answer: "March 3", sources: ["Flight.md"]) }),
            ("long answer", model { $0.present(); $0.input = "q"; $0.submit(); $0.finish(answer: String(repeating: "word ", count: 200), sources: ["Flight.md"]) }),
            ("draft", model { $0.present(mode: .reply); $0.input = "x"; $0.submit(); $0.finishDraft("Friday works.", sources: ["Lease.md"]) }),
            ("error", model { $0.present(); $0.input = "q"; $0.submit(); $0.fail("Usage limit reached") }),
        ]
        for (name, m) in states {
            let img = try XCTUnwrap(render(m), name)
            // A coarse grid is enough: a colored glow or button covers hundreds of pixels.
            let worst = colorfulness(img, rows: stride(from: 0, to: h, by: 3), xRange: 0...(w - 1), step: 3)
            XCTAssertLessThan(worst, 0.02, "\(name): no colored pixels anywhere")
        }
    }

    func testTheThinkingDotBreathesWithinAGentleRange() {
        var lo = 1.0, hi = 0.0
        for t in stride(from: 0.0, to: 20.0, by: 0.05) { let b = ThinkingDot.breath(t); lo = min(lo, b); hi = max(hi, b) }
        XCTAssertGreaterThanOrEqual(lo, 0); XCTAssertLessThanOrEqual(hi, 1)
        XCTAssertLessThan(lo, 0.05, "it really goes down"); XCTAssertGreaterThan(hi, 0.95, "…and up, so the pulse is visible")
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

    func testNewSurfacesDrawContentInsideTheCanvas() throws {
        // Each new state renders, with real text drawn on the black surface (not an empty or clipped box).
        func lightPixels(_ img: NSBitmapImageRep, rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Int {
            var n = 0
            for y in rows { for x in columns {
                guard let c = img.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.6 && c.greenComponent > 0.6 && c.blueComponent > 0.6 { n += 1 }
            } }
            return n
        }
        let centre = 140...520
        let list = NotchModel(); list.present(mode: .act); list.input = "x"; list.submit(); list.addStep("Opening Mail")
        list.setChecklist([.init("Find the lease", .done), .init("Write the reply", .active), .init("Show the draft", .pending)])
        let plan = NotchModel(); plan.present(mode: .act); plan.input = "x"; plan.submit()
        Task { @MainActor in _ = await plan.requestApproval(.init(kind: .plan, detail: "1. Open Mail 2. Reply")) }
        let ask = NotchModel(); ask.present(mode: .act); ask.input = "x"; ask.submit()
        Task { @MainActor in _ = await ask.requestAnswer(question: "Which address?", options: ["work", "home"]) }
        for (name, model, phase) in [("checklist", list, NotchModel.Phase.working), ("plan", plan, .confirm), ("question", ask, .question)] {
            let img = try XCTUnwrap(render(model), name)
            XCTAssertEqual(img.pixelsWide, Int(NotchView.canvas.width), name)
            let surface = NotchLayout.size(phase: phase, notch: geo.rect.size, steps: 1, checklist: 3, planLines: name == "plan" ? 2 : 0, options: name == "question" ? 2 : 0)
            XCTAssertLessThanOrEqual(surface.height + 40, NotchView.canvas.height, name)
            let text = lightPixels(img, rows: Int(geo.height) + 10...Int(surface.height) - 10, columns: centre)
            XCTAssertGreaterThan(text, 40, "\(name): text is drawn inside its surface")
        }
    }
}
