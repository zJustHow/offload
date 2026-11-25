import AppKit
import OffloadCore
import OffloadUI
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            SourcesTab(model: model).tabItem { Label("Sources", systemImage: "tray.full") }.tag(SettingsTab.sources)
            ModelsTab(model: model).tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsTab.models)
            PrivacyTab(model: model).tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
            ScheduleTab(model: model).tabItem { Label("Nightly", systemImage: "moon.stars") }.tag(SettingsTab.schedule)
            AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
        }
        .frame(width: 660, height: 560)
        .onAppear { NSApp.setActivationPolicy(.regular) }
    }
}

/// A binding into the configuration that saves on every change.
@MainActor
private func config<T>(_ model: AppModel, _ keyPath: WritableKeyPath<OffloadConfig, T>) -> Binding<T> {
    Binding(get: { model.config[keyPath: keyPath] }, set: { v in model.update { $0[keyPath: keyPath] = v } })
}

private func note(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("Open Offload when I log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Draft replies with a double-tap of the right ⌘ key", isOn: $model.doubleTapEnabled)
                note("Reads the message on your screen and pastes an unsent draft in your voice. Needs Screen Recording and Accessibility.")
            }
            Section("Ask from anywhere") {
                LabeledContent("Open the assistant") { Text("Click the notch, or press ⌘⇧Space").foregroundStyle(.secondary) }
                Button("Open the welcome guide again") { model.showOnboarding(restart: true) }
            }
            Section("About") {
                LabeledContent("Version") { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build") }
                LabeledContent("Your data") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.support]) }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Sources

private struct SourcesTab: View {
    @ObservedObject var model: AppModel
    @State private var googleClientID = ""
    @State private var googleSecret = ""
    @State private var googleStatus = "Checking…"
    @State private var googleBusy = false

    var body: some View {
        Form {
            Section("Folders") {
                ForEach(model.config.folders, id: \.self) { f in
                    HStack { Image(systemName: "folder").foregroundStyle(.secondary); Text(f).lineLimit(1).truncationMode(.middle); Spacer(); Button("Remove") { model.update { $0.folders.removeAll { $0 == f } } }.buttonStyle(.link) }
                }
                Button("Add folder…") { model.pickFolders {} }
            }
            Section("On this Mac") {
                Toggle("Apple Notes", isOn: config(model, \.appleNotesEnabled))
                Toggle("Apple Mail", isOn: config(model, \.mailEnabled))
                Toggle("Apple Calendar", isOn: config(model, \.calendarEnabled))
                HStack {
                    Text("Messages and WhatsApp")
                    Spacer()
                    Text("\(model.config.imessageChats.count + model.config.whatsappChats.count) chats").foregroundStyle(.secondary)
                    Button("Choose chats…") { model.showChatPicker() }
                }
                HStack {
                    Text("SiYuan"); Spacer()
                    Text(model.config.siyuanPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? "off").foregroundStyle(.secondary)
                    Button("Choose…") { model.pickSiYuan {} }
                    if model.config.siyuanPath != nil { Button("Off") { model.update { $0.siyuanPath = nil } } }
                }
                note("Notes, Mail and Messages need Full Disk Access. Only the chats you tick are ever read.")
            }
            Section("Google (Gmail and Calendar)") {
                Text(googleStatus).font(.callout)
                TextField("OAuth client ID", text: $googleClientID)
                SecureField("OAuth client secret", text: $googleSecret)
                HStack {
                    Button(googleBusy ? "Waiting for the browser…" : "Sign in with Google") { signIn() }.disabled(googleBusy || googleClientID.isEmpty || googleSecret.isEmpty)
                    Button("Sign out") { signOut() }
                }
                Toggle("Read Gmail", isOn: config(model, \.gmailEnabled))
                Toggle("Read Google Calendar", isOn: config(model, \.googleCalendarEnabled))
                note("Google needs an OAuth client of your own: in Google Cloud Console create a project, enable the Gmail and Calendar APIs, and create a client of type “Desktop app”. Access is read-only, and the token stays in your Keychain.")
            }
        }
        .formStyle(.grouped)
        .task { await refreshGoogle() }
    }

    private func refreshGoogle() async {
        if let c = await GoogleAuth().credentials() {
            googleStatus = "Signed in. Gmail: \(c.scopes.contains(GoogleAuth.gmailScope) ? "allowed" : "not allowed"), Calendar: \(c.scopes.contains(GoogleAuth.calendarScope) ? "allowed" : "not allowed")."
        } else { googleStatus = "Not signed in." }
    }

    private func signIn() {
        googleBusy = true
        Task {
            defer { googleBusy = false }
            do {
                try await GoogleAuth().signIn(clientID: googleClientID, clientSecret: googleSecret, scopes: [GoogleAuth.gmailScope, GoogleAuth.calendarScope], openURL: { NSWorkspace.shared.open($0) })
                model.update { $0.gmailEnabled = true; $0.googleCalendarEnabled = true }
                googleSecret = ""
            } catch { googleStatus = "\(error)"; return }
            await refreshGoogle()
        }
    }

    private func signOut() {
        Task {
            await GoogleAuth().signOut()
            model.update { $0.gmailEnabled = false; $0.googleCalendarEnabled = false }
            await refreshGoogle()
        }
    }
}

// MARK: Models

private struct ModelsTab: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                ModelPicker(title: "Writes your notes (use a strong model)", profile: config(model, \.knowledge))
                ModelPicker(title: "Answers, drafts and acts", profile: config(model, \.assistant))
                ModelPicker(title: "Reads every item (keep this local)", profile: config(model, \.triage))
                if model.config.knowledge.provider == .apple {
                    Label("The built-in model is weak at merging many items into notes. A stronger model makes noticeably better notes.", systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                }
                if model.config.triage.provider != .apple {
                    Label("Reading covers every item, so a hosted model here receives the text of all your files, mail and messages.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                ForEach(model.runtime?.fallbackNotes ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
            }
            Section("API key") {
                SecureField("Key for an API model (saved in your Keychain)", text: $apiKey)
                Button("Save key for the API models above") { saveKey() }.disabled(apiKey.isEmpty)
                note("Only needed for “Anthropic API key” and “OpenAI-compatible” models. Subscriptions use the tool's own login.")
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        for role in ["triage", "knowledge", "assistant"] {
            let kp: WritableKeyPath<OffloadConfig, ModelProfile> = role == "triage" ? \.triage : role == "knowledge" ? \.knowledge : \.assistant
            guard model.config[keyPath: kp].provider == .anthropic || model.config[keyPath: kp].provider == .openaiCompatible else { continue }
            let account = "\(role)-app"
            try? Keychain.set(apiKey, account: account)
            model.update { $0[keyPath: kp].keyAccount = account }
        }
        apiKey = ""
    }
}

private struct ModelPicker: View {
    let title: String
    @Binding var profile: ModelProfile
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Picker("", selection: Binding(get: { profile.provider }, set: { p in
                    profile.provider = p
                    if p == .openaiCompatible, profile.baseURL == nil { profile.baseURL = "http://localhost:11434/v1" }
                })) {
                    Text("Built in (on this Mac)").tag(ModelProfile.Provider.apple)
                    Text("Claude subscription").tag(ModelProfile.Provider.claudeCLI)
                    Text("ChatGPT subscription").tag(ModelProfile.Provider.codexCLI)
                    Text("OpenAI-compatible / Ollama").tag(ModelProfile.Provider.openaiCompatible)
                    Text("Anthropic API key").tag(ModelProfile.Provider.anthropic)
                }.labelsHidden().frame(width: 230)
            }
            switch profile.provider {
            case .claudeCLI, .codexCLI:
                Text(status.isEmpty ? "Checking…" : status).font(.caption).foregroundStyle(status.hasPrefix("Logged in") ? Color.green : Color.orange)
                TextField("Model (optional, e.g. sonnet)", text: Binding(get: { profile.model ?? "" }, set: { profile.model = $0.isEmpty ? nil : $0 }))
            case .openaiCompatible:
                TextField("Model name", text: Binding(get: { profile.model ?? "" }, set: { profile.model = $0 }))
                TextField("Base URL", text: Binding(get: { profile.baseURL ?? "" }, set: { profile.baseURL = $0 }))
            case .anthropic:
                TextField("Model name", text: Binding(get: { profile.model ?? "" }, set: { profile.model = $0 }))
            case .apple: EmptyView()
            }
        }
        .padding(.vertical, 2)
        .task(id: profile.provider) {
            switch profile.provider {
            case .claudeCLI: let s = await ClaudeCLIModel.authStatus(); status = s.loggedIn ? "Logged in via \(s.method ?? "claude")" : s.detail
            case .codexCLI: let s = await CodexCLIModel.loginStatus(); status = s.loggedIn ? "Logged in" : s.detail
            default: status = ""
            }
        }
    }
}

// MARK: Privacy

private struct PrivacyTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Cloud models") {
                note("A cloud model (a subscription or an API) can read your notes and excerpts from your files and messages, with card numbers, ID numbers, passports and passwords already removed. Those excerpts are sent to the provider when they are used to answer, draft or act. Models on this Mac send nothing anywhere.")
            }
            Section("Where your data lives") {
                row("Search index and settings", model.paths.support)
                row("Knowledge base (plain Markdown)", model.runtime?.workspace.root)
                note("The index is excluded from Time Machine and Spotlight. API keys and the Google sign-in are in your Keychain.")
            }
            Section("What is never kept") {
                note("Medical, financial and other very private items are skipped entirely. Card numbers, ID numbers, passports and passwords are removed from text before it is stored.")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ url: URL?) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url?.path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .trailing)
                if let url { Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link) }
            }
        }
    }
}

// MARK: Nightly

private struct ScheduleTab: View {
    @ObservedObject var model: AppModel
    @State private var message = ""
    @State private var installed = LaunchAgent.isInstalled

    var body: some View {
        Form {
            Section {
                Stepper("Run every night at \(String(format: "%02d:00", model.config.scheduleHour))", value: config(model, \.scheduleHour), in: 0...23)
                HStack {
                    Button(installed ? "Update schedule" : "Turn on nightly run") { install() }
                    if installed { Button("Turn off") { remove() } }
                }
                Text(message.isEmpty ? (installed ? "Scheduled." : "Not scheduled.") : message).font(.callout).foregroundStyle(.secondary)
            }
            Section("While the app is open") {
                Toggle("Keep search up to date as files change", isOn: config(model, \.liveSync))
                note("New, edited, moved and deleted files are reflected in search within seconds, and changes made while the app was closed are caught up when it starts. Only folders you have already read in full are followed; a read you stopped halfway is not resumed on its own. Files are read and summarized with your triage model as they change, so a hosted triage model receives them as they change rather than once a night. Your notes are still updated by the nightly run.")
            }
            Section("Good to know") {
                note("It reads what's new, updates your notes and prepares suggestions, while your Mac is awake and plugged in. A sleeping Mac is not woken: to also wake it each night, run this once in Terminal (it asks for your password):")
                Text(LaunchAgent.wakeCommand(hour: model.config.scheduleHour)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        do {
            let exe = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath + "/Contents/MacOS/offload" : CommandLine.arguments[0]
            try LaunchAgent.install(executable: exe, hour: model.config.scheduleHour, logDir: model.paths.logs.path)
            installed = true; message = "Scheduled for \(String(format: "%02d:00", model.config.scheduleHour)) every night."
        } catch { message = "Couldn't schedule it: \(error)" }
    }

    private func remove() {
        do { try LaunchAgent.uninstall(); installed = false; message = "Turned off." } catch { message = "Couldn't turn it off: \(error)" }
    }
}

// MARK: Advanced

private struct AdvancedTab: View {
    @ObservedObject var model: AppModel
    @State private var health: [HealthItem] = []
    @State private var confirming: Reset.Options?
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Health") {
                if health.isEmpty { ProgressView().controlSize(.small) }
                ForEach(health) { h in
                    HStack(alignment: .top, spacing: 10) {
                        StatusDot(HealthStatus(rawValue: h.status.rawValue) ?? .optional)
                        VStack(alignment: .leading, spacing: 1) { Text(h.title); Text(h.detail).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if h.status == .needsAction || (h.status == .optional && h.settingsURL != nil), let url = h.settingsURL { Button("Open Settings") { model.openURL(url) }.buttonStyle(.link) }
                    }
                }
                Button("Check again") { Task { await load() } }
            }
            Section("Reset") {
                Button("Rebuild the search index…") { confirming = [.index] }
                note("Deletes what was read and indexed; the next run reads everything again. Your notes and original files are untouched.")
                Button("Remove all Offload data…", role: .destructive) { confirming = .everything }
                note("Removes the index, settings, keys and the nightly schedule, and moves the knowledge base to the Trash. Your original files are never touched.")
            }
            Section("Troubleshooting") {
                Button("Show log files") {
                    try? FileManager.default.createDirectory(at: model.paths.logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.paths.logs)
                }
                note("Logs hold events and error messages, never the contents of your notes or messages.")
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .alert("That didn't work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .confirmationDialog(confirming == .everything ? "Remove all Offload data?" : "Rebuild the search index?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirming == .everything ? "Remove everything" : "Rebuild", role: .destructive) { perform() }
        } message: {
            Text(confirming == .everything ? "Your knowledge base goes to the Trash. This can't be undone from inside Offload." : "The next run will read everything again.")
        }
    }

    private func load() async { health = await SystemHealth.check(config: model.config) }

    private func perform() {
        guard let options = confirming, let rt = model.runtime else { return }
        confirming = nil
        do {
            try Reset.perform(options, paths: model.paths, vault: rt.workspace.root)
            model.reload()
            if options == .everything { model.showOnboarding(restart: true) }
            model.refreshHome()
        } catch {
            AppLog.shared.error("reset failed: \(error)")
            failure = ErrorText.friendly(error)
        }
    }
}
