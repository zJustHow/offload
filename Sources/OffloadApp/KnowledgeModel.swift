import AppKit
import Foundation
import OffloadCore
import OffloadUI

/// State of the Knowledge window: which note is open, the text being edited, search, and the graph.
@MainActor
final class KnowledgeModel: ObservableObject {
    enum Mode: String, CaseIterable { case read = "Read", edit = "Edit", graph = "Graph" }
    enum SaveState: Equatable { case saved, unsaved, saving, failed(String) }

    unowned let app: AppModel
    @Published private(set) var notes: [NoteRecord] = []
    @Published private(set) var overview: NoteRecord?
    @Published var selection: String?
    @Published var mode: Mode = .read { didSet { if oldValue != mode { modeChanged(from: oldValue) } } }
    @Published var draft = "" { didSet { if !loadingDraft, draft != oldValue { draftChanged() } } }
    @Published var query = ""
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var searching = false
    @Published private(set) var evidence: [ItemRecord] = []
    @Published private(set) var graph: KnowledgeGraph?
    @Published private(set) var positions: [CGPoint] = []
    @Published private(set) var saveState: SaveState = .saved
    @Published var error: String?
    @Published var showingNewNote = false
    @Published var confirmingDelete = false

    private var loadingDraft = false
    private var saveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var graphTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    var selectedNote: NoteRecord? { selection == "README.md" ? overview : notes.first { $0.path == selection } }
    var canEdit: Bool { selectedNote != nil && selection != "README.md" }
    var folders: [String] { Array(Set(notes.map { ($0.path as NSString).deletingLastPathComponent })).sorted() }

    // MARK: Loading

    func reload() {
        guard let rt = app.runtime else { return }
        Task { @MainActor in
            try? await rt.refreshNotesIndex()
            let all = (try? rt.store.allNotes()) ?? []
            overview = all.first { $0.path == "README.md" }
            notes = all.filter { $0.path != "README.md" }
            if selection == nil || selectedNote == nil { selection = overview != nil ? "README.md" : notes.first?.path }
            loadEvidence()
            graph = nil
            if mode == .graph { buildGraph() }
        }
    }

    func windowClosed() {
        Task { await flush() }
        app.setEditing(false)
    }

    func select(_ path: String) {
        guard path != selection else { return }
        Task { @MainActor in
            await flush()
            selection = path
            if mode == .graph { mode = .read }
            if mode == .edit { loadDraft() }
            loadEvidence()
        }
    }

    private func loadEvidence() {
        guard let rt = app.runtime, let path = selection else { evidence = []; return }
        evidence = (try? rt.store.evidenceItems(notePath: path)) ?? []
    }

    private func loadDraft() {
        loadingDraft = true
        draft = selectedNote?.body ?? ""
        loadingDraft = false
        saveState = .saved
    }

    // MARK: Editing

    private func modeChanged(from old: Mode) {
        if old == .edit { Task { await flush() } }
        switch mode {
        case .edit:
            guard canEdit else { mode = .read; if selection == "README.md" { error = "The Overview is written by Offload, so it can't be edited. Edit any other note." }; return }
            loadDraft()
        case .graph: buildGraph()
        case .read: break
        }
    }

    private func draftChanged() {
        saveState = .unsaved
        app.setEditing(true)     // the overnight update waits while you are typing
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes any pending edit right now (when leaving the note, switching mode, or closing).
    func flush() async {
        saveTask?.cancel()
        if saveState == .unsaved { await save() }
    }

    private func save() async {
        guard let rt = app.runtime, let path = selection, canEdit else { return }
        saveState = .saving
        let editor = VaultEditor(workspace: rt.workspace, store: rt.store, indexer: rt.indexer)
        do {
            try await editor.save(path: path, body: draft)
            if let i = notes.firstIndex(where: { $0.path == path }) {
                let n = notes[i]
                notes[i] = NoteRecord(path: n.path, title: Indexer.title(of: draft, fallbackPath: path), body: draft, hash: Hashing.sha256Hex(draft), mtime: Date())
            }
            saveState = draft == notes.first(where: { $0.path == path })?.body ? .saved : .unsaved
            if saveState == .saved { app.setEditing(false); graph = nil }
        } catch {
            saveState = .failed("\(error)")
            self.error = "Couldn't save: \(error)"
        }
    }

    func createNote(folder: String, title: String) {
        guard let rt = app.runtime else { return }
        Task { @MainActor in
            await flush()
            do {
                let editor = VaultEditor(workspace: rt.workspace, store: rt.store, indexer: rt.indexer)
                let path = try await editor.create(folder: folder, title: title)
                let all = (try? rt.store.allNotes()) ?? []
                notes = all.filter { $0.path != "README.md" }
                selection = path
                mode = .edit
                loadDraft()
                loadEvidence()
                graph = nil
            } catch { self.error = "\(error)" }
        }
    }

    func deleteSelected() {
        guard let rt = app.runtime, let path = selection, canEdit else { return }
        Task { @MainActor in
            saveTask?.cancel()
            do {
                try VaultEditor(workspace: rt.workspace, store: rt.store, indexer: rt.indexer).delete(path: path)
                notes.removeAll { $0.path == path }
                saveState = .saved; app.setEditing(false)
                mode = .read
                selection = overview != nil ? "README.md" : notes.first?.path
                loadEvidence(); graph = nil
            } catch { self.error = "\(error)" }
        }
    }

    // MARK: Links and search

    /// Opens the note a `[[wikilink]]` points at, if there is one.
    func openLink(_ title: String) {
        let key = title.lowercased()
        let target = notes.first { $0.title.lowercased() == key || (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == key }
        if let target { select(target.path) } else if key == "about" || key == "overview", overview != nil { select("README.md") }
    }

    func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let rt = app.runtime else { results = []; searching = false; return }
        searching = true
        searchTask = Task { @MainActor in
            var opts = SearchOptions(); opts.limit = 20
            let hits = (try? await rt.memory.search(q, options: opts)) ?? []
            guard !Task.isCancelled else { return }
            results = hits; searching = false
        }
    }

    func open(_ hit: SearchHit) {
        if let p = hit.notePath { select(p) }
        else if let p = hit.citedByNotes.first { select(p) }
        else if let uri = hit.source?.uri, uri.hasPrefix("/") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: uri)]) }
    }

    // MARK: Graph

    private func buildGraph() {
        guard graph == nil else { return }
        let input = ([overview].compactMap { $0 } + notes).map { (path: $0.path, title: $0.title, body: $0.body) }
        graphTask?.cancel()
        graphTask = Task { @MainActor in
            let (g, pts) = await Task.detached(priority: .userInitiated) { () -> (KnowledgeGraph, [CGPoint]) in
                let g = KnowledgeGraph.build(notes: input)
                return (g, GraphLayout.positions(for: g))
            }.value
            guard !Task.isCancelled else { return }
            graph = g; positions = pts
        }
    }
}
