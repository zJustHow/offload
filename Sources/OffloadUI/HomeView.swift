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
    public static let size = CGSize(width: 860, height: 660)

    public init(model: HomeModel, now: Date = Date(), fixedPhase: Double? = nil) { self.model = model; self.now = now; self.fixedPhase = fixedPhase }

    public var body: some View {
        let d = model.data
        ZStack {
            IntelligenceBackground(phase: fixedPhase)
            AdaptiveScroll {
                VStack(alignment: .leading, spacing: 20) {
                    header(d)
                    HStack(spacing: 12) {
                        tile(d.itemsRead.formatted(), "items read", action: nil)
                        tile(d.notes.formatted(), "notes in your knowledge base", action: model.onOpenKnowledge)
                        tile(d.suggestions.formatted(), d.suggestions == 1 ? "suggestion ready" : "suggestions ready", action: model.onOpenSuggestions)
                    }
                    if d.analysis.phase == .running { runningPanel(d.analysis) }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) { sectionTitle("Sources"); sources(d) }.frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 14) {
                            if !d.attention.isEmpty { VStack(alignment: .leading, spacing: 10) { sectionTitle("Needs attention"); attention(d) } }
                            VStack(alignment: .leading, spacing: 10) { sectionTitle("Recent activity"); activity(d) }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    tips
                }
                .padding(28)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: pieces

    private func header(_ d: HomeData) -> some View {
        HStack(spacing: 16) {
            IntelligenceOrb(size: 46, phase: fixedPhase)
            VStack(alignment: .leading, spacing: 3) {
                GradientText(HomeText.greeting(at: now), size: 28)
                Text(d.lastRun.map { "Last read \(HomeText.relative($0, now: now))." } ?? "I haven't read anything yet.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Ask or give a task") { model.onOpenAssistant?() }.buttonStyle(QuietButtonStyle())
            if d.analysis.phase == .running {
                Button("Stop") { model.onStop?() }.buttonStyle(QuietButtonStyle())
            } else {
                Button("Analyze now") { model.onAnalyze?() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private func tile(_ value: String, _ label: String, action: (() -> Void)?) -> some View {
        if let action { Button(action: action) { StatTile(value, label) }.buttonStyle(.plain).accessibilityHint("Opens it") }
        else { StatTile(value, label) }   // information only: not a (dimmed) button
    }

    private func runningPanel(_ a: AnalysisState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IntelligenceOrb(size: 18, phase: fixedPhase)
                ShimmerText(a.source.map { "Reading \($0)" } ?? a.stage, font: .system(size: 14, weight: .semibold), phase: fixedPhase)
                Spacer()
                if a.total > 0 { Text("\(a.done) of \(a.total)").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            GradientProgress(a.fraction)
            if let t = a.currentTitle { Text(t).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
        .padding(14).glassCard(cornerRadius: 14)
    }

    private func sectionTitle(_ t: String) -> some View { Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.leading, 2) }

    private func sources(_ d: HomeData) -> some View {
        VStack(spacing: 0) {
            if d.sources.isEmpty {
                Text("No sources yet. Add one in Settings.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(d.sources.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 12) {
                    SymbolBadge(s.symbol, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        Text(s.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(s.itemCount)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).monospacedDigit()
                    StatusDot(s.status)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                if i < d.sources.count - 1 { Divider().overlay(.white.opacity(0.08)).padding(.leading, 54) }
            }
        }
        .glassCard(cornerRadius: 14)
    }

    private func attention(_ d: HomeData) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(d.attention.enumerated()), id: \.element.id) { i, a in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn).font(.system(size: 14)).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        Text(a.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    if let t = a.actionTitle, let url = a.url { Button(t) { model.onOpenURL?(url) }.buttonStyle(QuietButtonStyle()) }
                    else if let t = a.actionTitle { Button(t) { model.onOpenSettings?() }.buttonStyle(QuietButtonStyle()) }
                }
                .padding(12)
                if i < d.attention.count - 1 { Divider().overlay(.white.opacity(0.08)) }
            }
        }
        .glassCard(cornerRadius: 14)
    }

    private func activity(_ d: HomeData) -> some View {
        VStack(spacing: 0) {
            if d.activity.isEmpty { Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(Array(d.activity.prefix(5).enumerated()), id: \.element.id) { i, a in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: a.isWarning ? "exclamationmark.triangle" : "checkmark.circle").font(.system(size: 12)).foregroundStyle(a.isWarning ? Theme.warn : Theme.good).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                        Text(HomeText.relative(a.date, now: now)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                if i < min(5, d.activity.count) - 1 { Divider().overlay(.white.opacity(0.08)) }
            }
        }
        .glassCard(cornerRadius: 14)
    }

    private var tips: some View {
        HStack(spacing: 18) {
            Label("Click the notch or press ⌘⇧Space to ask", systemImage: "sparkles")
            Label("Double-tap right ⌘ to draft a reply", systemImage: "text.bubble")
            Spacer()
            Button("Welcome guide") { model.onShowGuide?() }.buttonStyle(.plain).foregroundStyle(Theme.tertiary)
            Button("Settings") { model.onOpenSettings?() }.buttonStyle(.plain).foregroundStyle(Theme.tertiary)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
    }
}
