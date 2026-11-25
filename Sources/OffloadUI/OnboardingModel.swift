import Foundation
import SwiftUI

public enum HealthStatus: String, Sendable { case ok, needsAction, optional, unavailable }

public struct SourceOption: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case toggle, folders, chats, action }
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var style: Style = .toggle
    public var isOn: Bool = false
    /// A short status under the title, e.g. "2 folders chosen".
    public var detail: String?
    public var needsFullDiskAccess = false
    /// Label of the button for `.action` rows.
    public var actionTitle: String?
    public init(id: String, title: String, subtitle: String, symbol: String, style: Style = .toggle, isOn: Bool = false, detail: String? = nil, needsFullDiskAccess: Bool = false, actionTitle: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.style = style; self.isOn = isOn; self.detail = detail; self.needsFullDiskAccess = needsFullDiskAccess; self.actionTitle = actionTitle
    }
}

public struct PermissionRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: HealthStatus
    public var symbol: String
    /// Whether the sources chosen earlier need it.
    public var required: Bool
    public var settingsURL: URL?
    public init(id: String, title: String, detail: String, status: HealthStatus, symbol: String, required: Bool, settingsURL: URL? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.status = status; self.symbol = symbol; self.required = required; self.settingsURL = settingsURL
    }
}

public struct ModelOption: Identifiable, Equatable, Sendable {
    public enum Readiness: Sendable { case ready, needsSetup, unavailable }
    public var id: String
    public var title: String
    public var subtitle: String
    public var badge: String?
    public var readiness: Readiness
    public var statusText: String
    public init(id: String, title: String, subtitle: String, badge: String? = nil, readiness: Readiness, statusText: String) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.badge = badge; self.readiness = readiness; self.statusText = statusText
    }
}

public struct AnalysisState: Equatable, Sendable {
    public enum Phase: Sendable { case idle, running, stopped, finished }
    public var phase: Phase = .idle
    public var stage = ""
    public var source: String?
    public var done = 0
    public var total = 0
    public var currentTitle: String?
    public var kept = 0
    public var skipped = 0
    public var sensitive = 0
    public var notes = 0
    public var warnings: [String] = []
    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    public init() {}
}

/// The first-run guide. It owns *where the user is* and *what they may do next*; the app fills in
/// the facts (which permissions are granted, what a model's status is, how far the analysis is) and
/// carries out the actions through the callbacks.
@MainActor
public final class OnboardingModel: ObservableObject {
    public enum Step: Int, CaseIterable, Sendable { case welcome, sources, permissions, models, privacy, analyze, done }

    @Published public private(set) var step: Step
    @Published public var sources: [SourceOption] = []
    @Published public var permissions: [PermissionRow] = []
    @Published public var models: [ModelOption] = []
    @Published public var selectedModel = "builtin"
    @Published public var analysis = AnalysisState()
    @Published public private(set) var goingForward = true

    public var onToggleSource: ((String, Bool) -> Void)?
    public var onConfigureSource: ((String) -> Void)?
    public var onOpenSettings: ((URL) -> Void)?
    public var onRequestPermission: ((String) -> Void)?
    public var onSelectModel: ((String) -> Void)?
    public var onStartAnalysis: (() -> Void)?
    public var onStopAnalysis: (() -> Void)?
    public var onStepChanged: ((Step) -> Void)?
    public var onFinish: ((Bool) -> Void)?   // true = open the knowledge base

    public init(startAt step: Step = .welcome) { self.step = step }

    // MARK: Navigation

    public var progress: Double { Double(step.rawValue) / Double(Step.allCases.count - 1) }
    public var chosenSources: [SourceOption] { sources.filter(\.isOn) }
    /// Permissions the chosen sources need and the Mac has not granted.
    public var missingRequired: [PermissionRow] { permissions.filter { $0.required && $0.status != .ok } }

    public var canGoBack: Bool {
        switch step {
        case .welcome, .done: return false
        case .analyze: return analysis.phase != .running
        default: return true
        }
    }

    public var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .sources, .models, .privacy: return "Continue"
        case .permissions: return missingRequired.isEmpty ? "Continue" : "Continue anyway"
        case .analyze:
            switch analysis.phase {
            case .idle: return "Start reading"
            case .running: return "Keep going in the background"
            case .stopped, .finished: return "Continue"
            }
        case .done: return "Open Offload"
        }
    }

    public var primaryEnabled: Bool { step == .sources ? !chosenSources.isEmpty : true }

    /// What the big button does at this step.
    public func performPrimary() {
        guard primaryEnabled else { return }
        switch step {
        case .analyze where analysis.phase == .idle: onStartAnalysis?()
        case .done: onFinish?(true)
        default: go(to: Step(rawValue: step.rawValue + 1))
        }
    }

    public func back() {
        guard canGoBack else { return }
        go(to: Step(rawValue: step.rawValue - 1), forward: false)
    }

    /// Leaves the guide from any step (the work done so far is kept).
    public func skipAll() { onFinish?(false) }

    public func jump(to step: Step) { go(to: step, forward: step.rawValue >= self.step.rawValue) }

    private func go(to next: Step?, forward: Bool = true) {
        guard let next else { return }
        goingForward = forward
        step = next
        onStepChanged?(next)
    }

    // MARK: Choices

    public func toggle(_ id: String, _ on: Bool) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].isOn = on
        onToggleSource?(id, on)
    }

    public func select(model id: String) {
        guard let option = models.first(where: { $0.id == id }), option.readiness != .unavailable else { return }
        selectedModel = id
        onSelectModel?(id)
    }
}
