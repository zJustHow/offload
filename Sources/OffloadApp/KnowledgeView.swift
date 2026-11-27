import AppKit
import OffloadCore
import OffloadUI
import SwiftUI

/// The knowledge base, laid out like ChatGPT: a dark sidebar with a round search field and the list of
/// notes (as it lists chats), and the chosen note on the canvas beside it with the view switcher on top.
struct KnowledgeView: View {
    @ObservedObject var model: KnowledgeModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(text: $model.query, prompt: "Search by meaning or exact words") { model.runSearch() }
                    .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 10)   // clears the window's traffic lights
                sidebar
            }
            .frame(width: 284).frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebar)
            ZStack(alignment: .top) {
                AppBackground()
                VStack(spacing: 0) {
                    topBar
                    detail
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(Theme.text)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .onChange(of: model.query) { _, q in if q.isEmpty { model.runSearch() } }
        .sheet(isPresented: $model.showingNewNote) { NewNoteSheet(model: model) }
        .confirmationDialog("Move “\(model.selectedNote?.title ?? "")” to the Trash?", isPresented: $model.confirmingDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteSelected() }
        } message: { Text("You can put it back from the Trash.") }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") {} } message: { Text(model.error ?? "") }
        .frame(minWidth: 800, minHeight: 500)
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            PillPicker(selection: $model.mode, options: KnowledgeModel.Mode.allCases, title: { $0.rawValue })
            HStack(spacing: 4) {
                Spacer()
                Button { model.showingNewNote = true } label: { barIcon("square.and.pencil") }
                    .buttonStyle(.plain).help("New note (⌘N)").keyboardShortcut("n").accessibilityLabel("New note")
                Menu {
                    Button("Show in Finder") { if let p = model.selection, let rt = model.app.runtime { NSWorkspace.shared.activateFileViewerSelecting([rt.workspace.root.appendingPathComponent(p)]) } }.disabled(model.selection == nil)
                    Button("Delete note…", role: .destructive) { model.confirmingDelete = true }.disabled(!model.canEdit)
                } label: { barIcon("ellipsis") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 16).frame(height: 56)
    }

    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.secondary)
            .frame(width: 34, height: 34).contentShape(Circle())
    }

    // MARK: Sidebar

    @ViewBuilder private var sidebar: some View {
        if !model.query.isEmpty { searchResults } else if model.notes.isEmpty && model.overview == nil { emptySidebar } else { tree }
    }

    private var tree: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.overview != nil {
                    SidebarRow(symbol: "person.text.rectangle", title: "Overview", selected: model.selection == "README.md") { model.select("README.md") }
                }
                ForEach(model.folders, id: \.self) { folder in
                    Text(folder).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                    ForEach(model.notes.filter { ($0.path as NSString).deletingLastPathComponent == folder }) { n in
                        SidebarRow(title: n.title, selected: model.selection == n.path) { model.select(n.path) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
    }

    private var emptySidebar: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(Theme.tertiary)
            Text("No notes yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Your knowledge base fills in after the first analysis.").font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button("Analyze now") { model.app.startCycle() }.buttonStyle(QuietButtonStyle()).disabled(model.app.cycleRunning)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchResults: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.searching { HStack(spacing: 8) { ThinkingDot(size: 9); Text("Searching…").foregroundStyle(Theme.secondary) }.padding(10) }
                else if model.results.isEmpty { Text("No results. Press Return to search.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(10) }
                ForEach(model.results) { h in
                    ResultRow(hit: h) { model.open(h) }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
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
                        Divider().overlay(Theme.border).padding(.vertical, 10)
                        Text("Built from \(model.evidence.count) source item\(model.evidence.count == 1 ? "" : "s")").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        VStack(spacing: 0) {
                            ForEach(Array(model.evidence.enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 12) {
                                    Image(systemName: icon(item.kind)).frame(width: 20).foregroundStyle(Theme.tertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.system(size: 14)).foregroundStyle(Theme.text)
                                        Text(item.uri).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if item.uri.hasPrefix("/") { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.uri)]) }.buttonStyle(QuietButtonStyle()) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                if i < model.evidence.count - 1 { Divider().overlay(Theme.border) }
                            }
                        }
                        .surfaceCard()
                    }
                }
                .padding(.horizontal, 36).padding(.top, 12).padding(.bottom, 32).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("Select a note", systemImage: "book", description: Text("Your knowledge base is a plain folder of Markdown files."))
        }
    }

    @ViewBuilder private var editor: some View {
        if model.canEdit {
            VStack(spacing: 0) {
                TextEditor(text: $model.draft)
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text).scrollContentBackground(.hidden)
                    .padding(.horizontal, 30).padding(.vertical, 14)
                    .accessibilityLabel("Note text")
                Divider().overlay(Theme.border)
                HStack {
                    Text("Saves automatically. Link notes with [[Note title]].").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    saveBadge
                }.padding(.horizontal, 20).padding(.vertical, 9)
            }
        } else { ContentUnavailableView("Nothing to edit", systemImage: "square.and.pencil", description: Text("Pick a note first. The Overview is written by Offload and can't be edited.")) }
    }

    @ViewBuilder private var saveBadge: some View {
        switch model.saveState {
        case .saved: Label("Saved", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        case .saving: Label("Saving…", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        case .unsaved: Label("Editing", systemImage: "pencil").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
        }
    }

    @ViewBuilder private var graphView: some View {
        ZStack {
            AppBackground()
            if let g = model.graph, g.nodes.count > 1 {
                GraphView(graph: g, points: model.positions, selection: model.selection) { model.select($0) }
                VStack { Spacer(); legend(g) }.padding(14)
            } else if model.graph == nil && !model.notes.isEmpty {
                VStack(spacing: 12) { ThinkingDot(size: 14); ShimmerText("Arranging your notes…") }
            } else {
                ContentUnavailableView("Not much to connect yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Notes link to each other with [[double brackets]]. Once there are a few, they appear here as a constellation."))
            }
        }
    }

    private func legend(_ g: KnowledgeGraph) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(g.domains.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 6) { Circle().fill(GraphView.palette[i % GraphView.palette.count]).frame(width: 8, height: 8); Text(d).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            Text("\(g.nodes.count) notes · \(g.edges.count) links").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).surfaceCard(cornerRadius: 14)
    }

    private func icon(_ k: SourceKind) -> String {
        switch k { case .file: "doc"; case .image: "photo"; case .note: "note.text"; case .chat: "bubble.left.and.bubble.right"; case .mail: "envelope"; case .calendar: "calendar" }
    }
}

/// One hit in the sidebar's search results: title, a snippet and where it came from, lit under the pointer.
private struct ResultRow: View {
    let hit: SearchHit
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: hit.kind == .note ? "doc.text" : "tray.full").foregroundStyle(Theme.tertiary).font(.system(size: 12))
                    Text(hit.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                }
                Text(hit.snippet).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(3)
                if hit.kind == .chunk, let u = hit.source?.uri { Text(u).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.surface : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
        VStack(alignment: .leading, spacing: 16) {
            Heading("New note", size: 20)
            TextField("Title", text: $title).textFieldStyle(PillTextFieldStyle()).focused($focused).onSubmit(create)
            HStack {
                Text("Folder").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                Spacer()
                Picker("Folder", selection: $folder) {
                    ForEach(model.folders, id: \.self) { Text($0).tag($0) }
                    Text("New folder…").tag("__new__")
                }.labelsHidden().frame(width: 210)
            }
            if folder == "__new__" { TextField("Folder name", text: $newFolder).textFieldStyle(PillTextFieldStyle()) }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle())
                Button("Create", action: create).keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || (folder == "__new__" && newFolder.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24).frame(width: 420)
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark).tint(Theme.text)
        .onAppear { folder = model.selection.map { ($0 as NSString).deletingLastPathComponent }.flatMap { model.folders.contains($0) ? $0 : nil } ?? model.folders.first ?? "__new__"; focused = true }
    }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.createNote(folder: chosenFolder, title: t)
        dismiss()
    }
}
