import Foundation
import SwiftUI

/// The notch assistant's state machine. It knows nothing about models or agents: the app wires its
/// callbacks, and reports progress by calling the methods below. Everything is on the main actor
/// so SwiftUI can observe it directly.
@MainActor
public final class NotchModel: ObservableObject {
    public enum Phase: Equatable, Sendable { case hidden, compact, input, thinking, working, confirm, answer, error }
    public enum Mode: String, CaseIterable, Sendable { case ask = "Ask", act = "Do" }

    @Published public private(set) var phase: Phase = .hidden
    @Published public var mode: Mode = .ask
    @Published public var input = ""
    @Published public private(set) var status = ""
    @Published public private(set) var steps: [String] = []
    @Published public private(set) var answer = ""
    @Published public private(set) var sources: [String] = []
    @Published public private(set) var confirmation: String?
    @Published public private(set) var errorText = ""
    /// 0...1: how strongly the glow should burn right now (the view animates toward it).
    @Published public private(set) var glow: Double = 0
    /// Where the interactive part of the surface is, in the panel's coordinates; everything else
    /// lets clicks fall through to the windows underneath.
    @Published public var interactiveRect: CGRect = .zero

    public var onSubmit: ((String, Mode) -> Void)?
    public var onStop: (() -> Void)?
    public var onDismiss: (() -> Void)?

    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var fadeTask: Task<Void, Never>?
    public static let maxSteps = 6

    public init() {}

    // MARK: Lifecycle

    /// Opens the input field.
    public func present(mode: Mode? = nil) {
        guard phase == .hidden || phase == .compact || phase == .answer || phase == .error else { return }
        resetOutput()
        if let mode { self.mode = mode }
        set(.input)
    }

    /// Sends the current text. Ignored when empty or when a task is already running.
    public func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .input, !text.isEmpty else { return }
        input = ""
        status = mode == .act ? "Working on it…" : "Thinking…"
        steps = []
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
        if let pending = confirmContinuation { confirmContinuation = nil; pending.resume(returning: false) }
        return await withCheckedContinuation { cont in
            confirmation = description
            confirmContinuation = cont
            set(.confirm)
        }
    }

    public func resolveConfirmation(_ allow: Bool) {
        guard let cont = confirmContinuation else { return }
        confirmContinuation = nil
        confirmation = nil
        set(.working)
        cont.resume(returning: allow)
    }

    public func finish(answer: String, sources: [String] = []) {
        self.answer = answer
        self.sources = sources
        confirmation = nil
        set(.answer)
        // The glow flares while thinking and settles once there is something to read.
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.glow = 0
        }
    }

    public func fail(_ message: String) {
        errorText = message
        confirmation = nil
        if let cont = confirmContinuation { confirmContinuation = nil; cont.resume(returning: false) }
        set(.error)
    }

    public func stop() {
        onStop?()
        dismiss()
    }

    public func dismiss() {
        fadeTask?.cancel()
        if let cont = confirmContinuation { confirmContinuation = nil; cont.resume(returning: false) }
        resetOutput()
        input = ""
        glow = 0
        phase = .hidden
        onDismiss?()
    }

    // MARK: internals

    private func set(_ new: Phase) {
        phase = new
        switch new {
        case .hidden, .error: glow = 0
        case .compact: glow = 0.85
        case .input: glow = 0.4
        case .thinking: glow = 1
        case .working: glow = 0.85
        case .confirm: glow = 0.65
        case .answer: glow = 0.45
        }
    }

    private func resetOutput() {
        status = ""; steps = []; answer = ""; sources = []; confirmation = nil; errorText = ""
    }
}
