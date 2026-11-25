import AppKit
import EventKit
import Foundation
import OffloadCore
import OffloadUI
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable { case general, sources, models, privacy, schedule, advanced }

/// The app's one shared state: configuration, the runtime built from it, the cycle that reads your
/// data, and the windows. Everything is on the main actor; long work runs in tasks that report back.
@MainActor
final class AppModel: ObservableObject {
    let paths = AppPaths()
    @Published private(set) var runtime: Runtime?
    @Published private(set) var startupError: String?
    @Published private(set) var config = OffloadConfig()
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var cards: [Card] = []
    @Published private(set) var cycleRunning = false
    @Published var settingsTab: SettingsTab = .general
    @Published var doubleTapEnabled = UserDefaults.standard.bool(forKey: "doubleTapEnabled") {
        didSet { UserDefaults.standard.set(doubleTapEnabled, forKey: "doubleTapEnabled"); updateDoubleTap() }
    }

    let notch = NotchModel()
    let home = HomeModel()
    let windows = WindowManager()
    var onboarding: OnboardingModel?
    var ollamaModels: [String] = []
    private(set) lazy var knowledge = KnowledgeModel(app: self)

    var analysis = AnalysisState()
    private var cycleTask: Task<Void, Never>?
    private var runtimeIsStale = false
    private let editing = AtomicFlag()
    private let doubleTap = DoubleTapMonitor()
    private lazy var notchController = NotchWindowController(model: notch)
    private let edgeGlow = ScreenEdgeGlowController()
    private var assistantTask: Task<Void, Never>?
    private var hotkeyMonitors: [Any] = []
    var permissionTask: Task<Void, Never>?

    init() {
        AppLog.shared.configure(directory: paths.logs)
        AppLog.shared.info("Offload launched")
        reload()
        // Windows are NOT created here. This initializer runs while SwiftUI is computing the App's
        // state, and building an NSHostingView inside that update re-enters SwiftUI and aborts the
        // process. Setting up on the next run-loop turn is safely outside it.
        DispatchQueue.main.async { [weak self] in self?.finishSetup() }
    }

    private func finishSetup() {
        notchController.install()
        notchController.onNotchClick = { [weak self] in self?.notch.present() }
        notch.onSubmit = { [weak self] text, mode in self?.runAssistant(text, mode: mode) }
        notch.onStop = { [weak self] in self?.assistantTask?.cancel() }
        windows.onClose = { [weak self] id in self?.windowClosed(id) }
        wireHome()
        installHotkey()
        updateDoubleTap()
        #if DEBUG
        debugHooks()
        #endif
        if !config.onboardingCompleted { showOnboarding() }
    }

    // MARK: Configuration and runtime

    func reload() {
        do {
            let cfg = try paths.loadConfig()
            config = cfg
            runtime = try Runtime(paths: paths, config: cfg)
            startupError = nil
            refreshCounts()
        } catch { startupError = "\(error)"; AppLog.shared.error("could not start: \(error)") }
    }

    /// Changes the configuration, saves it, and rebuilds what depends on it (after a running cycle
    /// finishes, never underneath it).
    func update(_ change: (inout OffloadConfig) -> Void) {
        var new = config
        change(&new)
        guard new != config else { return }
        config = new
        do { try paths.save(new) } catch { startupError = "Couldn't save your settings: \(error.localizedDescription)" }
        if cycleRunning { runtimeIsStale = true } else { rebuildRuntime() }
    }

    private func rebuildRuntime() {
        runtimeIsStale = false
        do { runtime = try Runtime(paths: paths, config: config); startupError = nil } catch { startupError = "\(error)" }
        refreshCounts()
    }

    func refreshCounts() {
        guard let rt = runtime else { return }
        counts = (try? rt.store.counts()) ?? [:]
        cards = (try? rt.store.cards()) ?? []
    }

    // MARK: The cycle (reading, indexing, writing notes)

    func startCycle() {
        guard let rt = runtime, !cycleRunning else { return }
        cycleRunning = true
        var a = AnalysisState(); a.phase = .running; a.stage = "Starting"
        publish(a)
        let flag = editing
        cycleTask = Task { [weak self] in
            let report = await rt.runCycle(shouldSkipVault: { flag.value }, progress: { p in Task { @MainActor in self?.apply(p) } })
            await MainActor.run { self?.finishCycle(report) }
        }
    }

    func stopCycle() { cycleTask?.cancel() }

    private func apply(_ p: CycleProgress) {
        guard cycleRunning else { return }   // a late update must not undo "finished"
        var a = analysis
        a.phase = .running; a.stage = p.message; a.source = p.source; a.done = p.done; a.total = p.total
        a.currentTitle = p.currentTitle; a.kept = p.kept; a.skipped = p.skipped; a.sensitive = p.sensitive
        publish(a)
    }

    private func finishCycle(_ report: CycleReport) {
        cycleRunning = false
        AppLog.shared.info("cycle \(report.cancelled ? "stopped" : "finished") in \(Int(report.seconds))s: \(report.ingest.survivors) kept, \(report.ingest.junk) skipped, \(report.ingest.sensitive) sensitive, \(report.vault.notesInVault) notes")
        for w in report.warnings { AppLog.shared.warning(w) }
        var a = analysis
        a.phase = report.cancelled ? .stopped : .finished
        a.kept = report.ingest.survivors; a.skipped = report.ingest.junk; a.sensitive = report.ingest.sensitive
        a.notes = report.vault.notesInVault; a.warnings = report.warnings
        publish(a)
        if runtimeIsStale { rebuildRuntime() } else { refreshCounts() }
        knowledge.reload()
        refreshHome()
    }

    private func publish(_ a: AnalysisState) {
        analysis = a
        home.data.analysis = a
        onboarding?.analysis = a
    }

    func setEditing(_ value: Bool) { editing.value = value }

    func setCard(_ card: Card, status: String) {
        try? runtime?.store.setCardStatus(id: card.id, status: status)
        refreshCounts()
        refreshHome()
    }

    // MARK: Windows

    func showHome() {
        refreshHome()
        windows.show("home", title: "Offload", size: HomeView.size, immersive: true, resizable: false) { HomeView(model: home) }
    }

    func showKnowledge(select path: String? = nil) {
        knowledge.reload()
        if let path { knowledge.select(path) }
        windows.show("knowledge", title: "Knowledge", size: CGSize(width: 980, height: 660), minSize: CGSize(width: 760, height: 480)) { KnowledgeView(model: knowledge) }
    }

    func showSuggestions() {
        refreshCounts()
        windows.show("suggestions", title: "Suggestions", size: CGSize(width: 640, height: 560), minSize: CGSize(width: 520, height: 400)) { SuggestionsView(model: self) }
    }

    func showChatPicker() {
        windows.show("chats", title: "Choose chats", size: CGSize(width: 520, height: 560), minSize: CGSize(width: 420, height: 380)) { ChatPickerView(model: self) }
    }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func openAssistant() { notch.present() }

    func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

    private func windowClosed(_ id: String) {
        if id == "onboarding" { permissionTask?.cancel(); onboarding = nil }
        if id == "knowledge" { knowledge.windowClosed() }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { startupError = "Couldn't change the login item: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }

    // MARK: Assistant (notch)

    private func installHotkey() {
        // ⌘⇧Space: a combination that types no character, because a global monitor can observe a key
        // press but cannot swallow it.
        let match: (NSEvent) -> Bool = { $0.keyCode == 49 && $0.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in if match(e) { Task { @MainActor in self?.notch.present() } } }) { hotkeyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if match(e) { Task { @MainActor in self?.notch.present() }; return nil }
            return e
        }) { hotkeyMonitors.append(l) }
    }

    private func runAssistant(_ text: String, mode: NotchModel.Mode) {
        guard let rt = runtime else { notch.fail("Not ready: \(startupError ?? "no configuration")"); return }
        assistantTask?.cancel()
        assistantTask = Task { @MainActor in
            switch mode {
            case .ask:
                do {
                    let answer = try await MemoryQA(memory: rt.memory, model: rt.assistantModel).ask(text)
                    if !Task.isCancelled { notch.finish(answer: answer.text, sources: answer.sources) }
                } catch { AppLog.shared.error("question failed: \(error)"); if !Task.isCancelled { notch.fail(ErrorText.friendly(error)) } }
            case .act:
                guard ComputerPermissions.screenRecording, ComputerPermissions.accessibility else {
                    ComputerPermissions.requestScreenRecording(); ComputerPermissions.requestAccessibility()
                    notch.fail("To operate your Mac I need Screen Recording and Accessibility permission. Allow them in System Settings, then try again.")
                    return
                }
                edgeGlow.show()                       // the whole display glows while the assistant has the mouse
                defer { edgeGlow.hide() }
                let agent = Agent(
                    model: rt.assistantModel, memory: rt.memory, computer: MacComputerController(),
                    confirm: { [notch] description in await notch.requestConfirmation(description) })
                let result = await agent.run(task: text) { [notch] event in
                    if case .action(let a) = event { Task { @MainActor in notch.addStep(Dashboard.stepDescription(a)) } }
                }
                if Task.isCancelled { return }
                switch result.status {
                case .done: notch.finish(answer: result.summary.isEmpty ? "Done." : result.summary)
                case .couldNot, .maxSteps: notch.finish(answer: "I couldn't finish this. " + result.summary)
                case .cancelled: break
                case .failed(let why): notch.fail(why)
                }
            }
        }
    }

    // MARK: Double tap (reply drafting)

    private func updateDoubleTap() {
        if doubleTapEnabled {
            doubleTap.start { [weak self] in Task { @MainActor in await self?.draftFromScreen() } }
        } else { doubleTap.stop() }
    }

    func draftFromScreen() async {
        guard let rt = runtime, !cycleRunning else { return }
        guard ComputerPermissions.screenRecording, ComputerPermissions.accessibility else {
            ComputerPermissions.requestScreenRecording(); ComputerPermissions.requestAccessibility()
            notch.present(); notch.fail("To draft a reply I need Screen Recording and Accessibility permission. Allow them in System Settings, then try again.")
            return
        }
        notch.showBackground(status: "Drafting reply…")
        defer { if notch.phase == .compact { notch.dismiss() } }
        do {
            let shot = try await MacComputerController().screenshot()
            let visible = try OCR.recognize(imageData: shot)
            let ws = rt.workspace
            let drafter = ReplyDrafter(memory: rt.memory, model: rt.assistantModel, writingStyle: { WritingStyle.read(in: ws) })
            let draft = try await drafter.draft(visibleText: visible, screenshot: shot)
            Paster.paste(draft.text)   // an unsent draft in the focused field; the user reviews and sends
        } catch {
            if notch.phase == .compact { notch.dismiss() }
            notch.present(); notch.fail("Couldn't draft a reply: \(ErrorText.friendly(error))")
        }
    }

    #if DEBUG
    /// Debug builds only: `OFFLOAD_DEBUG_NOTCH=input|thinking|answer` shows the notch a moment after
    /// launch (without calling any model), and `OFFLOAD_DEBUG_WINDOW=home|onboarding|knowledge`
    /// opens a window, so the real windows can be inspected.
    private func debugHooks() {
        let env = ProcessInfo.processInfo.environment
        if let state = env["OFFLOAD_DEBUG_NOTCH"] {
            notch.onSubmit = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let notch = self?.notch else { return }
                notch.present()
                if state != "input" { notch.input = "when is my flight"; notch.submit() }
                if state == "answer" { notch.finish(answer: "Your flight is UA 837 on March 3 at 11:40, seat 24A. The confirmation code is K7P2QX.", sources: ["Flight Booking"]) }
            }
        }
        if env["OFFLOAD_DEBUG_DUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                for w in NSApp.windows where w.isVisible || w.title != "" {
                    FileHandle.standardError.write(Data("WINDOW title=\"\(w.title)\" visible=\(w.isVisible) frame=\(w.frame) level=\(w.level.rawValue) key=\(w.isKeyWindow)\n".utf8))
                }
                FileHandle.standardError.write(Data("POLICY \(NSApp.activationPolicy().rawValue)\n".utf8))
            }
        }
        if let window = env["OFFLOAD_DEBUG_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                switch window {
                case "home": self?.showHome()
                case "onboarding": self?.showOnboarding()
                case "knowledge": self?.showKnowledge()
                case "suggestions": self?.showSuggestions()
                default: break
                }
            }
        }
    }
    #endif
}

// MARK: - Helpers

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

/// Puts text in the focused field via the pasteboard (and restores the previous clipboard).
enum Paster {
    @MainActor static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents(); pb.setString(text, forType: .string)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
    }
}

/// Detects two quick presses of the right Command key (and nothing else in between).
final class DoubleTapMonitor {
    private var monitor: Any?
    private var lastRelease: TimeInterval = 0
    private var rightCommandDown = false
    private var otherKeyPressed = false
    private let window: TimeInterval = 0.35

    func start(_ onTrigger: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown { self.otherKeyPressed = true; self.lastRelease = 0; return }
            guard event.keyCode == 54 else { return }   // right Command
            if event.modifierFlags.contains(.command) {
                self.rightCommandDown = true; self.otherKeyPressed = false
            } else if self.rightCommandDown {
                self.rightCommandDown = false
                let now = ProcessInfo.processInfo.systemUptime
                if !self.otherKeyPressed, now - self.lastRelease < self.window { self.lastRelease = 0; onTrigger() } else { self.lastRelease = now }
            }
        }
    }

    func stop() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
}
