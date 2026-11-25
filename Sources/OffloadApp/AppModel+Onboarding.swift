import AppKit
import EventKit
import Foundation
import OffloadCore
import OffloadUI

extension AppModel {
    func showOnboarding(restart: Bool = false) {
        if let existing = onboarding, windows.isOpen("onboarding") {
            windows.show("onboarding", title: "Welcome to Offload", size: OnboardingView.size, immersive: true, resizable: false) { OnboardingView(model: existing) }
            return
        }
        if restart { update { $0.onboardingStep = 0; $0.onboardingCompleted = false } }
        let start = OnboardingModel.Step(rawValue: config.onboardingStep) ?? .welcome
        let m = makeOnboarding(startAt: start == .done ? .welcome : start)
        onboarding = m
        windows.show("onboarding", title: "Welcome to Offload", size: OnboardingView.size, immersive: true, resizable: false) { OnboardingView(model: m) }
        permissionTask?.cancel()
        permissionTask = Task { @MainActor [weak self] in
            await self?.refreshModels(m)
            // The permission pages follow what the user does in System Settings, live.
            while !Task.isCancelled, self?.onboarding === m {
                await self?.refreshPermissions(m)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func makeOnboarding(startAt: OnboardingModel.Step) -> OnboardingModel {
        let m = OnboardingModel(startAt: startAt)
        m.analysis = analysis
        m.allowCloudExcerpts = config.egress.rawSnippetsToHostedModels
        m.sources = sourceOptions()

        m.onToggleSource = { [weak self, weak m] id, on in
            guard let self, let m else { return }
            self.update { c in
                switch id {
                case "notes": c.appleNotesEnabled = on
                case "mail": c.mailEnabled = on
                case "calendar": c.calendarEnabled = on
                default: break
                }
            }
            m.sources = self.sourceOptions()
            Task { await self.refreshPermissions(m) }
        }
        m.onConfigureSource = { [weak self, weak m] id in
            guard let self, let m else { return }
            switch id {
            case "folders": self.pickFolders { m.sources = self.sourceOptions() }
            case "siyuan": self.pickSiYuan { m.sources = self.sourceOptions() }
            case "messages": self.showChatPicker()
            case "google": self.openSettings(tab: .sources)
            default: break
            }
        }
        m.onOpenSettings = { [weak self] url in self?.openURL(url) }
        m.onRequestPermission = { id in
            switch id {
            case "calendar": Task { _ = try? await EKEventStore().requestFullAccessToEvents() }
            case "screen": ComputerPermissions.requestScreenRecording()
            case "accessibility": ComputerPermissions.requestAccessibility()
            default: break
            }
        }
        m.onSelectModel = { [weak self] id in self?.applyModelChoice(id) }
        m.onAllowExcerpts = { [weak self] on in self?.update { $0.egress.rawSnippetsToHostedModels = on } }
        m.onStartAnalysis = { [weak self] in self?.startCycle() }
        m.onStopAnalysis = { [weak self] in self?.stopCycle() }
        m.onStepChanged = { [weak self] step in self?.update { $0.onboardingStep = step.rawValue } }
        m.onFinish = { [weak self] openKnowledge in self?.finishOnboarding(openKnowledge: openKnowledge) }
        return m
    }

    private func finishOnboarding(openKnowledge: Bool) {
        update { $0.onboardingCompleted = true; $0.onboardingStep = OnboardingModel.Step.done.rawValue }
        windows.close("onboarding")
        if openKnowledge { showKnowledge() } else { showHome() }
    }

    // MARK: Data for the screens

    func sourceOptions() -> [SourceOption] {
        let c = config
        let chats = c.imessageChats.count + c.whatsappChats.count
        return [
            SourceOption(id: "folders", title: "Folders", subtitle: "Documents, notes, PDFs and screenshots you keep in folders.", symbol: "folder", style: .folders, isOn: !c.folders.isEmpty,
                         detail: c.folders.isEmpty ? nil : "\(c.folders.count) folder\(c.folders.count == 1 ? "" : "s") chosen"),
            SourceOption(id: "notes", title: "Apple Notes", subtitle: "Your notes in the Notes app.", symbol: "note.text", isOn: c.appleNotesEnabled, needsFullDiskAccess: true),
            SourceOption(id: "mail", title: "Apple Mail", subtitle: "Messages in your mailboxes. They're read on this Mac and never sent anywhere.", symbol: "envelope", isOn: c.mailEnabled, needsFullDiskAccess: true),
            SourceOption(id: "calendar", title: "Calendar", subtitle: "Upcoming events and recent ones.", symbol: "calendar", isOn: c.calendarEnabled),
            SourceOption(id: "messages", title: "Messages and WhatsApp", subtitle: "Only the conversations you pick, one by one.", symbol: "message", style: .chats, isOn: chats > 0,
                         detail: chats > 0 ? "\(chats) chat\(chats == 1 ? "" : "s") chosen" : nil, needsFullDiskAccess: true),
            SourceOption(id: "siyuan", title: "SiYuan", subtitle: "A SiYuan workspace on this Mac.", symbol: "books.vertical", style: .action, isOn: c.siyuanPath != nil,
                         detail: c.siyuanPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }, actionTitle: c.siyuanPath == nil ? "Choose…" : "Change…"),
            SourceOption(id: "google", title: "Gmail and Google Calendar", subtitle: "Needs your own Google sign-in; set it up in Settings.", symbol: "tray", style: .action,
                         isOn: c.gmailEnabled || c.googleCalendarEnabled, detail: (c.gmailEnabled || c.googleCalendarEnabled) ? "Signed in" : nil, actionTitle: "Set up…"),
        ]
    }

    func refreshPermissions(_ m: OnboardingModel) async {
        let cfg = config
        let health = await SystemHealth.check(config: cfg)
        func item(_ id: String) -> HealthItem? { health.first { $0.id == id } }
        let needsFDA = cfg.appleNotesEnabled || cfg.mailEnabled || !cfg.imessageChats.isEmpty || !cfg.whatsappChats.isEmpty || m.chosenSources.contains { $0.id == "messages" }
        var rows: [PermissionRow] = []
        func status(_ s: HealthItem.Status) -> HealthStatus { HealthStatus(rawValue: s.rawValue) ?? .optional }
        if needsFDA, let f = item("fda") {
            rows.append(PermissionRow(id: "fda", title: "Full Disk Access", detail: "Lets me read Apple Notes, Mail and Messages. In System Settings, open Privacy & Security → Full Disk Access and turn on Offload.", status: status(f.status), symbol: "internaldrive", required: true, settingsURL: f.settingsURL))
        }
        if cfg.calendarEnabled || m.chosenSources.contains(where: { $0.id == "calendar" }), let c = item("calendar") {
            rows.append(PermissionRow(id: "calendar", title: "Calendar", detail: "Lets me read your events.", status: status(c.status), symbol: "calendar", required: true, settingsURL: c.status == .ok ? nil : nil))
        }
        if let s = item("screen") { rows.append(PermissionRow(id: "screen", title: "Screen Recording", detail: "So I can see the screen when you ask me to do something, or to draft a reply.", status: status(s.status), symbol: "rectangle.dashed.badge.record", required: false, settingsURL: s.settingsURL)) }
        if let a = item("accessibility") { rows.append(PermissionRow(id: "accessibility", title: "Accessibility", detail: "So I can click and type for you, and for the double-⌘ shortcut.", status: status(a.status), symbol: "accessibility", required: false, settingsURL: a.settingsURL)) }
        if m.permissions != rows { m.permissions = rows }
    }

    func refreshModels(_ m: OnboardingModel) async {
        async let claude = ClaudeCLIModel.authStatus()
        async let codex = CodexCLIModel.loginStatus()
        async let ollama = Self.detectOllama()
        let (cl, cx, ol) = await (claude, codex, ollama)
        let builtin = AppleOnDeviceModel.availability
        let current = currentModelChoice()
        var options = [
            ModelOption(id: "builtin", title: "Built in", subtitle: "Runs on this Mac and works offline. Good for reading and searching; the notes it writes are less polished.",
                        readiness: builtin.available ? .ready : .unavailable, statusText: builtin.available ? "Ready" : "Unavailable: \(builtin.reason). Turn on Apple Intelligence in System Settings."),
            ModelOption(id: "claude", title: "My Claude subscription", subtitle: "Writes much better notes. A short summary of each item (not the original files) is sent to Anthropic.",
                        badge: cl.loggedIn ? "Recommended" : nil, readiness: cl.loggedIn ? .ready : .needsSetup,
                        statusText: cl.loggedIn ? "Logged in via \(cl.method ?? "claude")" : cl.detail),
            ModelOption(id: "chatgpt", title: "My ChatGPT subscription", subtitle: "Uses the Codex command-line tool. A short summary of each item is sent to OpenAI.",
                        badge: (!cl.loggedIn && cx.loggedIn) ? "Recommended" : nil, readiness: cx.loggedIn ? .ready : .needsSetup,
                        statusText: cx.loggedIn ? "Logged in" : cx.detail),
            ModelOption(id: "local", title: "A model on this Mac (Ollama)", subtitle: "Private and strong, if you already run a large local model.",
                        readiness: ol.isEmpty ? .needsSetup : .ready, statusText: ol.isEmpty ? "Not detected at localhost:11434" : "Found \(ol.count) model\(ol.count == 1 ? "" : "s"): \(ol.prefix(2).joined(separator: ", "))"),
        ]
        if !(options.first { $0.id == current }.map { $0.readiness != .unavailable } ?? false) { options[0].badge = nil }
        m.models = options
        m.selectedModel = current
        ollamaModels = ol
    }

    /// Which option the saved configuration corresponds to.
    func currentModelChoice() -> String {
        switch config.knowledge.provider {
        case .claudeCLI: return "claude"
        case .codexCLI: return "chatgpt"
        case .openaiCompatible: return "local"
        default: return "builtin"
        }
    }

    func applyModelChoice(_ id: String) {
        let profile: ModelProfile
        switch id {
        case "claude": profile = ModelProfile(provider: .claudeCLI)
        case "chatgpt": profile = ModelProfile(provider: .codexCLI)
        case "local": profile = ModelProfile(provider: .openaiCompatible, baseURL: "http://localhost:11434/v1", model: ollamaModels.first ?? "")
        default: profile = .apple
        }
        // Reading every item always stays on the built-in model; only writing notes and answering move.
        update { $0.knowledge = profile; $0.assistant = profile }
    }

    static func detectOllama() async -> [String] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        req.timeoutInterval = 0.8
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let models = obj["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: Pickers

    func pickFolders(then done: @escaping () -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folders I should read"; p.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        update { c in for u in p.urls where !c.folders.contains(u.path) { c.folders.append(u.path) } }
        done()
    }

    func pickSiYuan(then done: @escaping () -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose the `data` folder inside your SiYuan workspace"; p.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        update { $0.siyuanPath = url.path }
        done()
    }
}
