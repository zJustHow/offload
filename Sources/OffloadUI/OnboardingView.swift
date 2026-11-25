import SwiftUI

/// The first-run guide: seven short screens, each with one job.
public struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var fixedPhase: Double?

    public init(model: OnboardingModel, fixedPhase: Double? = nil) { self.model = model; self.fixedPhase = fixedPhase }

    public static let size = CGSize(width: 780, height: 690)

    public var body: some View {
        ZStack {
            IntelligenceBackground(phase: fixedPhase)
            VStack(spacing: 0) {
                header
                content
                    .id(model.step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: model.goingForward ? 36 : -36)),
                        removal: .opacity.combined(with: .offset(x: model.goingForward ? -36 : 36))))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 44).padding(.vertical, 26)
        }
        .animation(intelligentAnimation(IntelligenceStyle.expressive, reduceMotion: reduceMotion), value: model.step)
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            StepDots(count: OnboardingModel.Step.allCases.count, current: model.step.rawValue)
            Spacer()
            if model.step != .done { Button("Skip setup") { model.skipAll() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
        }
        .frame(height: 24)
    }

    private var footer: some View {
        HStack {
            Button("Back") { model.back() }.buttonStyle(QuietButtonStyle()).opacity(model.canGoBack ? 1 : 0).disabled(!model.canGoBack)
            Spacer()
            if model.step == .done {
                Button("Browse my knowledge") { model.onFinish?(true) }.buttonStyle(QuietButtonStyle())
            }
            Button(model.primaryTitle) { model.step == .done ? model.onFinish?(false) : model.performPrimary() }
                .buttonStyle(PrimaryButtonStyle()).disabled(!model.primaryEnabled)
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 40)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeScreen(fixedPhase: fixedPhase)
        case .sources: SourcesScreen(model: model)
        case .permissions: PermissionsScreen(model: model)
        case .models: ModelsScreen(model: model)
        case .privacy: PrivacyScreen(model: model)
        case .analyze: AnalyzeScreen(model: model, fixedPhase: fixedPhase)
        case .done: DoneScreen(model: model)
        }
    }
}

// MARK: - Screens

private struct ScreenTitle: View {
    var title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GradientText(title, size: 30)
            Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
    }
}

private struct WelcomeScreen: View {
    var fixedPhase: Double?
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 4)
            ZStack {
                AnimatedGlow(shape: Circle(), intensity: 0.9, lineWidth: 2).frame(width: 118, height: 118).opacity(0.85)
                IntelligenceOrb(size: 96, phase: fixedPhase)
            }.frame(height: 130)
            VStack(spacing: 10) {
                GradientText("Hello, I'm Offload.", size: 38)
                Text("I read the things you already keep on this Mac, turn them into notes you can read, and help with whatever you ask. Let's set me up.")
                    .font(.system(size: 15)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            VStack(spacing: 10) {
                feature("lock.shield", "Learns on this Mac", "Your files, notes, mail and calendar are read locally.")
                feature("doc.text", "Notes you own", "Everything becomes plain Markdown that you can open, edit and keep.")
                feature("sparkles", "Ask, or hand it off", "Click the notch to ask a question or give me a task.")
            }
            .padding(14).glassCard(cornerRadius: 16).frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            SymbolBadge(symbol, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
    }
}

private struct SourcesScreen: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(title: "What should I read?", subtitle: "Pick where I should learn from. You can change this at any time in Settings.")
            AdaptiveScroll {
                VStack(spacing: 8) { ForEach(model.sources) { row($0) } }.padding(.vertical, 2)
            }
            if model.chosenSources.isEmpty {
                Text("Choose at least one to continue.").font(.system(size: 12)).foregroundStyle(Theme.warn).padding(.top, 8)
            }
        }
    }

    private func buttonTitle(_ s: SourceOption) -> String {
        switch s.style {
        case .folders: return s.isOn ? "Add more…" : "Choose…"
        case .chats: return s.isOn ? "Change…" : "Choose chats…"
        default: return s.actionTitle ?? "Set up…"
        }
    }

    private func row(_ s: SourceOption) -> some View {
        HStack(spacing: 14) {
            SymbolBadge(s.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(s.subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let d = s.detail { Text(d).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.good) }
                    if s.needsFullDiskAccess { Label("Needs Full Disk Access", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                }
            }
            Spacer(minLength: 8)
            switch s.style {
            case .toggle:
                PillSwitch(isOn: Binding(get: { s.isOn }, set: { model.toggle(s.id, $0) }), label: s.title)
            case .folders, .chats, .action:
                Button(buttonTitle(s)) { model.onConfigureSource?(s.id) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(12).glassCard(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(s.isOn ? Color(hex: 0xBC82F3).opacity(0.6) : .clear, lineWidth: 1.2))
        .accessibilityElement(children: .contain)
    }
}

private struct PermissionsScreen: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(title: "A few permissions", subtitle: model.missingRequired.isEmpty
                ? "Everything your sources need is already allowed. The rest are optional."
                : "macOS keeps your data behind permissions. Allow what your sources need; this page updates by itself when you come back.")
            AdaptiveScroll {
                VStack(alignment: .leading, spacing: 8) {
                    let needed = model.permissions.filter(\.required), optional = model.permissions.filter { !$0.required }
                    if !needed.isEmpty { section("Needed for the sources you chose"); ForEach(needed) { row($0) } }
                    if !optional.isEmpty { section("For the assistant (optional)").padding(.top, needed.isEmpty ? 0 : 8); ForEach(optional) { row($0) } }
                }
            }
        }
    }

    private func section(_ t: String) -> some View { Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.leading, 4) }

    private func row(_ p: PermissionRow) -> some View {
        HStack(spacing: 14) {
            SymbolBadge(p.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(p.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if p.status == .ok { StatusDot(.ok) }
            else if let url = p.settingsURL {
                Button("Open Settings") { model.onRequestPermission?(p.id); model.onOpenSettings?(url) }.buttonStyle(QuietButtonStyle())
            } else { Button("Allow") { model.onRequestPermission?(p.id) }.buttonStyle(QuietButtonStyle()) }
        }
        .padding(12).glassCard(cornerRadius: 14)
    }
}

private struct ModelsScreen: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(title: "How should I think?", subtitle: "Reading each of your items always happens with the model built into your Mac. Choose what writes your notes and answers your questions.")
            AdaptiveScroll { VStack(spacing: 8) { ForEach(model.models) { row($0) } } }
        }
    }

    private func row(_ m: ModelOption) -> some View {
        let selected = model.selectedModel == m.id
        return Button { model.select(model: m.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 18)).foregroundStyle(selected ? Color(hex: 0xBC82F3) : Theme.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(m.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        if let b = m.badge { Text(b).font(.system(size: 10, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.gradient)).foregroundStyle(.black.opacity(0.8)) }
                    }
                    Text(m.subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(m.statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(m.readiness == .ready ? Theme.good : m.readiness == .needsSetup ? Theme.warn : Color(hex: 0xFF6778))
                }
                Spacer()
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard(cornerRadius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Color(hex: 0xBC82F3).opacity(0.7) : .clear, lineWidth: 1.4))
            .opacity(m.readiness == .unavailable ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct PrivacyScreen: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(title: "Your data, your call", subtitle: "Here is exactly what happens with what I read.")
            VStack(spacing: 10) {
                point("internaldrive", "Stays on this Mac", "Your notes, the search index and your settings live in folders on this Mac. Nothing is uploaded unless you choose a cloud model.")
                point("eye.slash", "Sensitive things are dropped", "Medical, financial and other very private items are skipped, and card or ID numbers are removed before anything is stored.")
                point("cloud", "If you picked a cloud model", "It can read your notes and excerpts from your original files and messages (card and ID numbers already removed), and those excerpts are sent to the provider when they are used.")
            }
            Spacer(minLength: 0)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            SymbolBadge(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12).glassCard(cornerRadius: 14)
    }
}

private struct AnalyzeScreen: View {
    @ObservedObject var model: OnboardingModel
    var fixedPhase: Double?
    var body: some View {
        let a = model.analysis
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            switch a.phase {
            case .idle:
                IntelligenceOrb(size: 72, phase: fixedPhase)
                VStack(spacing: 8) {
                    GradientText("Ready to read", size: 30)
                    Text("I'll go through \(model.chosenSources.count == 1 ? "your chosen source" : "\(model.chosenSources.count) sources"), one item at a time, on this Mac. The first pass can take a while; you can keep using your Mac.")
                        .font(.system(size: 15)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                }
                HStack { ForEach(model.chosenSources.prefix(5)) { s in Label(s.title, systemImage: s.symbol).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(.white.opacity(0.1))).foregroundStyle(.white.opacity(0.85)) } }
            case .running:
                IntelligenceOrb(size: 64, phase: fixedPhase)
                VStack(spacing: 6) {
                    ShimmerText(a.source.map { "Reading \($0)" } ?? a.stage, font: .system(size: 20, weight: .semibold), phase: fixedPhase)
                    if a.total > 0 { Text("\(a.done) of \(a.total)").font(.system(size: 13)).foregroundStyle(Theme.secondary).contentTransition(.numericText()) }
                    if let t = a.currentTitle { Text(t).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1).frame(maxWidth: 420) }
                }
                GradientProgress(a.fraction).frame(maxWidth: 440)
                counters(a)
                HStack(spacing: 12) {
                    Button("Stop") { model.onStopAnalysis?() }.buttonStyle(QuietButtonStyle())
                }
                Text("You don't have to wait here. I'll carry on in the background.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            case .finished, .stopped:
                Image(systemName: a.phase == .finished ? "checkmark.circle.fill" : "pause.circle.fill").font(.system(size: 52)).foregroundStyle(a.phase == .finished ? Theme.good : Theme.warn)
                VStack(spacing: 6) {
                    GradientText(a.phase == .finished ? "All read" : "Paused", size: 30)
                    Text(a.phase == .finished ? "I read \(a.kept) items and wrote \(a.notes) notes." : "I read \(a.kept) items so far. I'll pick up where I left off next time.")
                        .font(.system(size: 15)).foregroundStyle(Theme.secondary)
                }
                counters(a)
                ForEach(a.warnings.prefix(2), id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warn).frame(maxWidth: 480, alignment: .leading) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func counters(_ a: AnalysisState) -> some View {
        HStack(spacing: 10) { StatTile("\(a.kept)", "kept"); StatTile("\(a.skipped)", "skipped"); StatTile("\(a.sensitive)", "kept private") }.frame(maxWidth: 440)
    }
}

private struct DoneScreen: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            IntelligenceOrb(size: 64)
            GradientText("You're all set.", size: 36)
            Text("Here is how to reach me.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
            VStack(spacing: 10) {
                tip("rectangle.topthird.inset.filled", "Click the notch", "or press ⌘⇧Space. Ask a question, or give me a task to do.")
                tip("text.bubble", "Double-tap the right ⌘ key", "to draft a reply to the message on your screen.")
                tip("books.vertical", "Open Knowledge", "to read, search and edit your notes, or see how they connect.")
                tip("sparkles", "The ✦ in your menu bar", "has everything else: analyze now, suggestions, settings.")
            }
            .padding(14).glassCard(cornerRadius: 16).frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            SymbolBadge(symbol, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
    }
}
