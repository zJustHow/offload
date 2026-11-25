import Foundation
import OffloadCore
import OffloadUI

extension AppModel {
    func wireHome() {
        home.onAnalyze = { [weak self] in self?.startCycle() }
        home.onStop = { [weak self] in self?.stopCycle() }
        home.onOpenKnowledge = { [weak self] in self?.showKnowledge() }
        home.onOpenSuggestions = { [weak self] in self?.showSuggestions() }
        home.onOpenSettings = { [weak self] in self?.openSettings() }
        home.onOpenAssistant = { [weak self] in self?.openAssistant() }
        home.onShowGuide = { [weak self] in self?.showOnboarding(restart: true) }
        home.onOpenURL = { [weak self] url in
            // `offload://settings/<tab>` is how a row asks for one of our own settings pages.
            if url.scheme == "offload", url.host == "settings" {
                self?.openSettings(tab: SettingsTab(rawValue: url.lastPathComponent))
            } else { self?.openURL(url) }
        }
        refreshHome()
    }

    /// Recomputes the dashboard. The permission probes are async, so the data arrives a moment later.
    func refreshHome() {
        guard let rt = runtime else { return }
        let cfg = config, running = analysis
        Task { @MainActor in
            let health = await SystemHealth.check(config: cfg)
            var d = HomeData()
            let survivors = (try? rt.store.counts()) ?? [:]
            d.itemsRead = survivors["survivor"] ?? 0
            d.notes = ((try? rt.store.notePaths()) ?? []).filter { $0 != "README.md" }.count
            d.suggestions = cards.count
            d.analysis = running
            let byBucket = (try? rt.store.survivorCountsByBucket()) ?? [:]
            func ok(_ id: String) -> Bool { health.first { $0.id == id }?.status == .ok }
            d.sources = rt.connectors().map { c in
                let count = byBucket[c.bucket] ?? 0
                let state = Dashboard.sourceStatus(bucket: c.bucket, itemCount: count, hasFullDiskAccess: ok("fda"), hasCalendarAccess: ok("calendar"), isSignedInToGoogle: ok("google"))
                return HomeSource(id: c.bucket, title: SourceNames.friendly(c.bucket), symbol: Dashboard.symbol(forBucket: c.bucket), itemCount: count, status: HealthStatus(rawValue: state.status.rawValue) ?? .optional, detail: state.detail)
            }
            for h in health where h.status == .needsAction {
                let action = h.id == "google" ? ("Open Settings", URL(string: "offload://settings/sources")) : ("Open Settings", h.settingsURL)
                d.attention.append(HomeAttention(id: h.id, title: "Allow \(h.title)", detail: h.detail, actionTitle: action.0, url: action.1))
                if h.id == "google" { d.attention[d.attention.count - 1].title = "Sign in to Google" }
            }
            if cfg.knowledge.provider == .apple, d.itemsRead >= 10 {
                d.attention.append(HomeAttention(id: "weak-model", title: "Notes are written by the built-in model", detail: "A stronger model makes noticeably better notes.", actionTitle: "Choose a model", url: URL(string: "offload://settings/models")))
            }
            for note in rt.fallbackNotes {
                d.attention.append(HomeAttention(id: "fallback-\(note.prefix(12))", title: "A model isn't available", detail: note, actionTitle: "Open Settings", url: URL(string: "offload://settings/models")))
            }
            if let e = startupError { d.attention.append(HomeAttention(id: "startup", title: "Something went wrong", detail: e)) }
            let history = rt.history.recent(limit: 6)
            d.lastRun = history.first(where: { !$0.cancelled })?.date
            d.activity = history.map { r in HomeActivity(id: r.id, date: r.date, text: Dashboard.activityText(r), isWarning: !r.warnings.isEmpty) }
            home.data = d
        }
    }
}
