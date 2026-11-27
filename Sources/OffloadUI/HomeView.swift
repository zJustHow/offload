import SwiftUI

public struct HomeSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var itemCount: Int
    public var status: HealthStatus
    public var detail: String
    public init(id: String, title: String, symbol: String, itemCount: Int, status: HealthStatus, detail: String) {
        self.id = id; self.title = title; self.symbol = symbol; self.itemCount = itemCount; self.status = status; self.detail = detail
    }
}

public struct HomeAttention: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var actionTitle: String?
    public var url: URL?
    public init(id: String, title: String, detail: String, actionTitle: String? = nil, url: URL? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.actionTitle = actionTitle; self.url = url
    }
}

public struct HomeActivity: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    public var text: String
    public var isWarning: Bool
    public init(id: String, date: Date, text: String, isWarning: Bool = false) { self.id = id; self.date = date; self.text = text; self.isWarning = isWarning }
}

/// Everything the dashboard shows. The app computes it; the view only draws it.
public struct HomeData: Equatable, Sendable {
    public var itemsRead = 0
    public var notes = 0
    public var suggestions = 0
    public var sources: [HomeSource] = []
    public var attention: [HomeAttention] = []
    public var activity: [HomeActivity] = []
    public var lastRun: Date?
    public var analysis = AnalysisState()
    public init() {}
}

@MainActor
public final class HomeModel: ObservableObject {
    @Published public var data = HomeData()
    public var onAnalyze: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onOpenKnowledge: (() -> Void)?
    public var onOpenSuggestions: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenAssistant: (() -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    public var onShowGuide: (() -> Void)?
    public init() {}
}

public enum HomeText {
    public static func greeting(at date: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Still up?"
        }
    }

    /// "just now", "5 minutes ago", "yesterday"…
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return "just now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

public struct HomeView: View {
    @ObservedObject var model: HomeModel
    var now: Date
    var fixedPhase: Double?
    public static let size = CGSize(width: 960, height: 700)
    private static let sidebarWidth: CGFloat = 244

    public init(model: HomeModel, now: Date = Date(), fixedPhase: Double? = nil) { self.model = model; self.now = now; self.fixedPhase = fixedPhase }

    public var body: some View {
        let d = model.data
        HStack(spacing: 0) {
            sidebar(d)
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    topBar(d)
                    AdaptiveScroll {
                        VStack(spacing: 22) {
                            greeting(d)
                            composer
                            hint
                            HStack(spacing: 12) {
                                tile(d.itemsRead.formatted(), "items read", action: nil)
                                tile(d.notes.formatted(), "notes in your knowledge base", action: model.onOpenKnowledge)
                                tile(d.suggestions.formatted(), d.suggestions == 1 ? "suggestion ready" : "suggestions ready", action: model.onOpenSuggestions)
                            }
                            if d.analysis.phase == .running { runningPanel(d.analysis) }
                            if !d.attention.isEmpty { VStack(alignment: .leading, spacing: 8) { sectionTitle("Needs attention"); attention(d) } }
                            VStack(alignment: .leading, spacing: 8) { sectionTitle("Recent activity"); activity(d) }
                        }
                        .frame(maxWidth: 640).padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 8)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark)
    }

    // MARK: sidebar (the list on the left, as in ChatGPT: a "new" button, places to go, then what it knows)

    private func sidebar(_ d: HomeData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppMark(size: 26)
                Text("Offload").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 14)
            SidebarRow(symbol: "square.and.pencil", title: "Ask or give a task") { model.onOpenAssistant?() }
            SidebarRow(symbol: "books.vertical", title: "Knowledge") { model.onOpenKnowledge?() }
            SidebarRow(symbol: "sparkles", title: "Suggestions", trailing: d.suggestions > 0 ? "\(d.suggestions)" : nil) { model.onOpenSuggestions?() }
            Text("Sources").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 4)
            if d.sources.isEmpty {
                Text("No sources yet.").font(.system(size: 13)).foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(d.sources) { s in
                SidebarRow(symbol: s.symbol, title: s.title, trailing: "\(s.itemCount)", status: s.status == .ok ? nil : s.status, help: s.detail, action: nil)
            }
            Spacer(minLength: 0)
            SidebarRow(symbol: "gearshape", title: "Settings") { model.onOpenSettings?() }
            SidebarRow(symbol: "questionmark.circle", title: "Welcome guide") { model.onShowGuide?() }
        }
        .padding(.horizontal, 10).padding(.bottom, 12).padding(.top, 38)   // clears the window's traffic lights
        .frame(width: Self.sidebarWidth).frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    // MARK: main column

    private func topBar(_ d: HomeData) -> some View {
        HStack {
            Spacer()
            if d.analysis.phase == .running {
                Button("Stop") { model.onStop?() }.buttonStyle(QuietButtonStyle())
            } else {
                Button("Analyze now") { model.onAnalyze?() }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private func greeting(_ d: HomeData) -> some View {
        VStack(spacing: 6) {
            Heading(HomeText.greeting(at: now), size: 30)
            Text(d.lastRun.map { "Last read \(HomeText.relative($0, now: now))." } ?? "I haven't read anything yet.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 14)
    }

    /// ChatGPT's composer, as a button: a round field with the send arrow at its end. It opens the assistant.
    private var composer: some View {
        Button { model.onOpenAssistant?() } label: {
            HStack(spacing: 12) {
                Text("Ask or give a task").font(.system(size: 16)).foregroundStyle(Theme.tertiary)
                Spacer()
                SendGlyph(enabled: true, size: 34)
            }
            .padding(.leading, 22).padding(.trailing, 11).frame(height: 58)
            .background(Theme.surface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask or give a task")
        .accessibilityHint("Opens the assistant in the notch")
    }

    private var hint: some View {
        Text("Click the notch or press ⌘⇧Space to ask  ·  Double-tap right ⌘ to draft a reply")
            .font(.system(size: 12)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
            .padding(.bottom, 4)
    }

    @ViewBuilder private func tile(_ value: String, _ label: String, action: (() -> Void)?) -> some View {
        if let action { Button(action: action) { StatTile(value, label) }.buttonStyle(.plain).accessibilityHint("Opens it") }
        else { StatTile(value, label) }   // information only: not a (dimmed) button
    }

    private func runningPanel(_ a: AnalysisState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ThinkingDot(size: 10, phase: fixedPhase)
                ShimmerText(a.source.map { "Reading \($0)" } ?? a.stage, font: .system(size: 14, weight: .medium), phase: fixedPhase)
                Spacer()
                if a.total > 0 { Text("\(a.done) of \(a.total)").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            ProgressBar(a.fraction)
            if let t = a.currentTitle { Text(t).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
    }

    private func sectionTitle(_ t: String) -> some View { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.leading, 4) }

    private func attention(_ d: HomeData) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(d.attention.enumerated()), id: \.element.id) { i, a in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn).font(.system(size: 15)).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        Text(a.detail).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    if let t = a.actionTitle, let url = a.url { Button(t) { model.onOpenURL?(url) }.buttonStyle(QuietButtonStyle()) }
                    else if let t = a.actionTitle { Button(t) { model.onOpenSettings?() }.buttonStyle(QuietButtonStyle()) }
                }
                .padding(14)
                if i < d.attention.count - 1 { Divider().overlay(Theme.border) }
            }
        }
        .surfaceCard()
    }

    private func activity(_ d: HomeData) -> some View {
        VStack(spacing: 0) {
            if d.activity.isEmpty { Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(Array(d.activity.prefix(5).enumerated()), id: \.element.id) { i, a in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: a.isWarning ? "exclamationmark.triangle" : "checkmark.circle").font(.system(size: 13)).foregroundStyle(a.isWarning ? Theme.warn : Theme.tertiary).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.text).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        Text(HomeText.relative(a.date, now: now)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                if i < min(5, d.activity.count) - 1 { Divider().overlay(Theme.border) }
            }
        }
        .surfaceCard()
    }
}
