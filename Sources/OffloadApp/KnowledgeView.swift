import AppKit
import OffloadCore
import OffloadUI
import SwiftUI

struct KnowledgeView: View {
    @ObservedObject var model: KnowledgeModel

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search by meaning or exact words")
        .onSubmit(of: .search) { model.runSearch() }
        .onChange(of: model.query) { _, q in if q.isEmpty { model.runSearch() } }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("View", selection: $model.mode) { ForEach(KnowledgeModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 220)
            }
            ToolbarItemGroup {
                Button { model.showingNewNote = true } label: { Label("New note", systemImage: "square.and.pencil") }.help("New note (⌘N)").keyboardShortcut("n")
                Menu {
                    Button("Show in Finder") { if let p = model.selection, let rt = model.app.runtime { NSWorkspace.shared.activateFileViewerSelecting([rt.workspace.root.appendingPathComponent(p)]) } }.disabled(model.selection == nil)
                    Button("Delete note…", role: .destructive) { model.confirmingDelete = true }.disabled(!model.canEdit)
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $model.showingNewNote) { NewNoteSheet(model: model) }
        .confirmationDialog("Move “\(model.selectedNote?.title ?? "")” to the Trash?", isPresented: $model.confirmingDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteSelected() }
        } message: { Text("You can put it back from the Trash.") }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") {} } message: { Text(model.error ?? "") }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: Sidebar

    @ViewBuilder private var sidebar: some View {
        if !model.query.isEmpty { searchResults } else if model.notes.isEmpty && model.overview == nil { emptySidebar } else { tree }
    }

    private var tree: some View {
        List(selection: Binding(get: { model.selection }, set: { if let p = $0 { model.select(p) } })) {
            if model.overview != nil { Label("Overview", systemImage: "person.text.rectangle").tag("README.md") }
            ForEach(model.folders, id: \.self) { folder in
                Section(folder) {
                    ForEach(model.notes.filter { ($0.path as NSString).deletingLastPathComponent == folder }) { n in
                        Text(n.title).lineLimit(1).tag(n.path)
                    }
                }
            }
        }
    }

    private var emptySidebar: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No notes yet").font(.headline)
            Text("Your knowledge base fills in after the first analysis.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Analyze now") { model.app.startCycle() }.disabled(model.app.cycleRunning)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchResults: some View {
        List {
            if model.searching { HStack { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) } }
            else if model.results.isEmpty { Text("No results. Press Return to search.").foregroundStyle(.secondary) }
            ForEach(model.results) { h in
                Button { model.open(h) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: h.kind == .note ? "doc.text" : "tray.full").foregroundStyle(.secondary).font(.caption)
                            Text(h.title).font(.headline).lineLimit(1)
                        }
                        Text(h.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        if h.kind == .chunk, let u = h.source?.uri { Text(u).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch model.mode {
        case .graph: graphView
        case .edit: editor
        case .read: reader
        }
    }

    @ViewBuilder private var reader: some View {
        if let note = model.selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownView(text: note.body, openNote: model.openLink)
                    if !model.evidence.isEmpty {
                        Divider().padding(.vertical, 8)
                        Text("Built from \(model.evidence.count) source item\(model.evidence.count == 1 ? "" : "s")").font(.headline)
                        ForEach(model.evidence, id: \.id) { item in
                            HStack(spacing: 10) {
                                Image(systemName: icon(item.kind)).frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading) { Text(item.title); Text(item.uri).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                Spacer()
                                if item.uri.hasPrefix("/") { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.uri)]) }.buttonStyle(.link) }
                            }
                        }
                    }
                }
                .padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("Select a note", systemImage: "book", description: Text("Your knowledge base is a plain folder of Markdown files."))
        }
    }

    @ViewBuilder private var editor: some View {
        if model.canEdit {
            VStack(spacing: 0) {
                TextEditor(text: $model.draft)
                    .font(.system(size: 14, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .accessibilityLabel("Note text")
                Divider()
                HStack {
                    Text("Saves automatically. Link notes with [[Note title]].").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    saveBadge
                }.padding(.horizontal, 14).padding(.vertical, 7)
            }
        } else { ContentUnavailableView("Nothing to edit", systemImage: "square.and.pencil", description: Text("Pick a note first. The Overview is written by Offload and can't be edited.")) }
    }

    @ViewBuilder private var saveBadge: some View {
        switch model.saveState {
        case .saved: Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .saving: Label("Saving…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .unsaved: Label("Editing", systemImage: "pencil").foregroundStyle(.orange)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(1)
        }
    }

    @ViewBuilder private var graphView: some View {
        ZStack {
            IntelligenceBackground()
            if let g = model.graph, g.nodes.count > 1 {
                GraphView(graph: g, points: model.positions, selection: model.selection) { model.select($0) }
                VStack { Spacer(); legend(g) }.padding(14)
            } else if model.graph == nil && !model.notes.isEmpty {
                VStack(spacing: 10) { IntelligenceOrb(size: 28); ShimmerText("Arranging your notes…") }
            } else {
                ContentUnavailableView("Not much to connect yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Notes link to each other with [[double brackets]]. Once there are a few, they appear here as a constellation."))
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func legend(_ g: KnowledgeGraph) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(g.domains.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 5) { Circle().fill(GraphView.palette[i % GraphView.palette.count]).frame(width: 8, height: 8); Text(d).font(.caption).foregroundStyle(.white.opacity(0.8)) }
            }
            Spacer()
            Text("\(g.nodes.count) notes · \(g.edges.count) links").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 14).padding(.vertical, 8).glassCard(cornerRadius: 12)
    }

    private func icon(_ k: SourceKind) -> String {
        switch k { case .file: "doc"; case .image: "photo"; case .note: "note.text"; case .chat: "bubble.left.and.bubble.right"; case .mail: "envelope"; case .calendar: "calendar" }
    }
}

struct NewNoteSheet: View {
    @ObservedObject var model: KnowledgeModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var folder = ""
    @State private var newFolder = ""
    @FocusState private var focused: Bool

    private var chosenFolder: String { folder == "__new__" ? newFolder : folder }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New note").font(.title3.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(create)
            Picker("Folder", selection: $folder) {
                ForEach(model.folders, id: \.self) { Text($0).tag($0) }
                Text("New folder…").tag("__new__")
            }
            if folder == "__new__" { TextField("Folder name", text: $newFolder).textFieldStyle(.roundedBorder) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || (folder == "__new__" && newFolder.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(22).frame(width: 380)
        .onAppear { folder = model.selection.map { ($0 as NSString).deletingLastPathComponent }.flatMap { model.folders.contains($0) ? $0 : nil } ?? model.folders.first ?? "__new__"; focused = true }
    }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.createNote(folder: chosenFolder, title: t)
        dismiss()
    }
}
