import Foundation
import SwiftUI

/// The notch assistant's state machine. It knows nothing about models or agents: the app wires its
/// callbacks, and reports progress by calling the methods below. Everything is on the main actor
/// so SwiftUI can observe it directly.
@MainActor
public final class NotchModel: ObservableObject {
    public enum Phase: Equatable, Sendable { case hidden, compact, input, thinking, working, confirm, question, answer, error }
    /// `reply` drafts an answer to the message on screen; its text is an optional instruction.
    public enum Mode: String, CaseIterable, Sendable { case ask = "Ask", act = "Do", reply = "Reply" }
    public enum DraftAction: Sendable { case copy, insert }

    /// What the user is being asked to approve. `irreversible` is the original "this cannot be undone"
    /// question; `needsApproval` is a tool that asks every time (a connected app, the web, a note edit);
    /// `plan` is the assistant's plan, shown as a list, to be approved once before it acts.
    public struct Approval: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case irreversible, needsApproval, plan }
        public var kind: Kind
        public var title: String
        public var detail: String
        /// Why it is being asked, in words (empty for the original irreversible question).
        public var reason: String
        public init(kind: Kind, title: String = "Needs your OK", detail: String, reason: String = "") {
            self.kind = kind; self.title = title; self.detail = detail; self.reason = reason
        }
    }

    /// One line of the assistant's own checklist for a task with several steps.
    public struct ChecklistItem: Equatable, Sendable {
        public enum State: Equatable, Sendable { case pending, active, done }
        public var text: String
        public var state: State
        public init(_ text: String, _ state: State) { self.text = text; self.state = state }
    }

    @Published public private(set) var phase: Phase = .hidden
    @Published public var mode: Mode = .ask
    @Published public var input = ""
    @Published public private(set) var status = ""
    @Published public private(set) var steps: [String] = []
    @Published public private(set) var answer = ""
    /// True when `answer` is a drafted reply (offered with Copy and Insert) rather than an answer.
    @Published public private(set) var isDraft = false
    /// True after the draft was copied, so the button can say so.
    @Published public private(set) var copied = false
    @Published public private(set) var sources: [String] = []
    @Published public private(set) var confirmation: String?
    @Published public private(set) var approval: Approval?
    @Published public private(set) var checklist: [ChecklistItem] = []
    @Published public private(set) var question = ""
    @Published public private(set) var options: [String] = []
    /// The text the user is typing as an answer to `question`.
    @Published public var answerInput = ""
    @Published public private(set) var errorText = ""
    /// Where the interactive part of the surface is, in the panel's coordinates; everything else
    /// lets clicks fall through to the windows underneath.
    @Published public var interactiveRect: CGRect = .zero

    public var onSubmit: ((String, Mode) -> Void)?
    /// Called with the draft's text when the user copies it or asks for it to be inserted.
    public var onDraftAction: ((DraftAction, String) -> Void)?
    public var onStop: (() -> Void)?
    public var onDismiss: (() -> Void)?

    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var answerContinuation: CheckedContinuation<String?, Never>?
    public static let maxSteps = 6
    public nonisolated static let maxOptions = 4
    public nonisolated static let maxChecklistRows = 5
    public nonisolated static let maxPlanLines = 8

    public init() {}

    // MARK: Lifecycle

    /// Opens the input field.
    public func present(mode: Mode? = nil) {
        guard phase == .hidden || phase == .compact || phase == .answer || phase == .error else { return }
        resetOutput()
        if let mode { self.mode = mode }
        set(.input)
    }

    /// Sends the current text. Ignored when a task is already running, and when the text is empty,
    /// except in Reply mode, where no instruction means "just reply to what is on screen".
    public func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .input, !text.isEmpty || mode == .reply else { return }
        input = ""
        switch mode {
        case .ask: status = "Thinking…"
        case .act: status = "Working on it…"
        case .reply: status = "Drafting reply…"
        }
        steps = []; checklist = []
        set(.thinking)
        onSubmit?(text, mode)
    }

    /// Shows a background activity without taking over (for example drafting a reply).
    public func showBackground(status: String) {
        guard phase == .hidden || phase == .compact else { return }
        self.status = status
        set(.compact)
    }

    public func addStep(_ text: String) {
        guard phase == .thinking || phase == .working else { return }
        steps.append(text)
        if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
        status = text
        set(.working)
    }

    /// Asks the user to approve something irreversible. Resolves when they choose, or `false` if the
    /// surface is dismissed first — a dismissed question is never an approval.
    public func requestConfirmation(_ description: String) async -> Bool {
        await requestApproval(Approval(kind: .irreversible, detail: description))
    }

    /// The same question, in any of its kinds. A newer question replaces an unanswered one (as a "no").
    public func requestApproval(_ request: Approval) async -> Bool {
        if let pending = confirmContinuation { confirmContinuation = nil; pending.resume(returning: false) }
        return await withCheckedContinuation { cont in
            approval = request
            confirmation = request.detail
            confirmContinuation = cont
            set(.confirm)
        }
    }

    public func resolveConfirmation(_ allow: Bool) {
        guard let cont = confirmContinuation else { return }
        confirmContinuation = nil
        confirmation = nil
        approval = nil
        set(.working)
        cont.resume(returning: allow)
    }

    /// Asks the user a question while a task runs: with `options`, as buttons (and they may still type
    /// their own answer); without, as a text field. Resolves with the answer, or nil if they skip it or the
    /// surface is dismissed first.
    public func requestAnswer(question text: String, options choices: [String] = []) async -> String? {
        if let pending = answerContinuation { answerContinuation = nil; pending.resume(returning: nil) }
        return await withCheckedContinuation { cont in
            question = text
            options = Array(choices.filter { !$0.isEmpty }.prefix(Self.maxOptions))
            answerInput = ""
            answerContinuation = cont
            set(.question)
        }
    }

    /// Answers the open question with the typed text, or with a chosen option.
    public func answerQuestion(_ text: String? = nil) {
        let answer = (text ?? answerInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cont = answerContinuation, !answer.isEmpty else { return }
        finishQuestion(cont, with: answer)
    }

    public func skipQuestion() {
        guard let cont = answerContinuation else { return }
        finishQuestion(cont, with: nil)
    }

    private func finishQuestion(_ cont: CheckedContinuation<String?, Never>, with answer: String?) {
        answerContinuation = nil
        question = ""; options = []; answerInput = ""
        set(.working)
        cont.resume(returning: answer)
    }

    /// Replaces the assistant's checklist (it sends the whole list each time). Shown while it works.
    public func setChecklist(_ items: [ChecklistItem]) {
        guard phase == .thinking || phase == .working || phase == .confirm || phase == .question else { return }
        checklist = items
        if phase == .thinking { set(.working) }
    }

    /// The rows to draw: all of them when there are few, otherwise a window around the step in progress.
    public var visibleChecklist: [ChecklistItem] {
        let all = checklist
        guard all.count > Self.maxChecklistRows else { return all }
        let current = all.firstIndex { $0.state != .done } ?? all.count - 1
        let start = min(max(0, current - 1), all.count - Self.maxChecklistRows)
        return Array(all[start..<(start + Self.maxChecklistRows)])
    }

    /// A plan as separate lines: it may arrive as "1. A 2. B" on one line or as one step per line.
    public nonisolated static func planLines(from text: String) -> [String] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("plan:") { body = String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count == 1, let re = try? NSRegularExpression(pattern: #"\s+(?=\d{1,2}[.)]\s)"#) {
            let line = lines[0], range = NSRange(line.startIndex..., in: line)
            let split = re.stringByReplacingMatches(in: line, range: range, withTemplate: "\n")
            lines = split.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard lines.count > maxPlanLines else { return lines }
        return Array(lines.prefix(maxPlanLines - 1)) + ["… and \(lines.count - maxPlanLines + 1) more steps"]
    }

    public func finish(answer: String, sources: [String] = []) {
        show(answer, sources: sources, isDraft: false)
    }

    /// Shows a drafted reply for the user to look over, with Copy and Insert beside it. Nothing
    /// reaches a text field until the user chooses Insert.
    public func finishDraft(_ text: String, sources: [String] = []) {
        show(text, sources: sources, isDraft: true)
    }

    public func copyDraft() {
        guard phase == .answer, isDraft else { return }
        copied = true
        onDraftAction?(.copy, answer)
    }

    /// Hands the draft to the app and closes the surface, so the field underneath gets the keyboard back.
    public func insertDraft() {
        guard phase == .answer, isDraft else { return }
        let text = answer
        onDraftAction?(.insert, text)
        dismiss()
    }

    private func show(_ text: String, sources: [String], isDraft: Bool) {
        answer = text
        self.sources = sources
        self.isDraft = isDraft
        copied = false
        confirmation = nil; approval = nil; checklist = []
        if let cont = answerContinuation { answerContinuation = nil; cont.resume(returning: nil) }
        set(.answer)
    }

    public func fail(_ message: String) {
        errorText = message
        confirmation = nil; approval = nil
        if let cont = confirmContinuation { confirmContinuation = nil; cont.resume(returning: false) }
        if let cont = answerContinuation { answerContinuation = nil; cont.resume(returning: nil) }
        set(.error)
    }

    public func stop() {
        onStop?()
        dismiss()
    }

    public func dismiss() {
        if let cont = confirmContinuation { confirmContinuation = nil; cont.resume(returning: false) }
        if let cont = answerContinuation { answerContinuation = nil; cont.resume(returning: nil) }
        resetOutput()
        input = ""
        phase = .hidden
        onDismiss?()
    }

    // MARK: internals

    private func set(_ new: Phase) { phase = new }

    private func resetOutput() {
        status = ""; steps = []; answer = ""; sources = []; confirmation = nil; approval = nil; errorText = ""; isDraft = false; copied = false
        checklist = []; question = ""; options = []; answerInput = ""
    }
}
