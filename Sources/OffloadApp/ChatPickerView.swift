import OffloadCore
import SwiftUI

/// Chooses which conversations may be read. Nothing from a chat that is not ticked here is ever read.
struct ChatPickerView: View {
    @ObservedObject var model: AppModel
    @State private var imessage: [ChatSummary] = []
    @State private var whatsapp: [ChatSummary] = []
    @State private var problems: [String] = []
    @State private var loading = true
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose chats").font(.title3.weight(.semibold))
            Text("I only read the conversations you tick. Messages are read on this Mac.").font(.callout).foregroundStyle(.secondary)
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            if loading { ProgressView().frame(maxWidth: .infinity, alignment: .center).padding() }
            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "lock").font(.callout).foregroundStyle(.orange)
            }
            List {
                section("Messages", imessage, selected: \.imessageChats) { id, on in model.update { c in toggle(&c.imessageChats, id, on) } }
                section("WhatsApp", whatsapp, selected: \.whatsappChats) { id, on in model.update { c in toggle(&c.whatsappChats, id, on) } }
            }
            HStack { Spacer(); Button("Done") { model.windows.close("chats") }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .task { await load() }
    }

    @ViewBuilder private func section(_ title: String, _ chats: [ChatSummary], selected: KeyPath<OffloadConfig, [String]>, set: @escaping (String, Bool) -> Void) -> some View {
        let shown = chats.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        if !shown.isEmpty {
            Section(title) {
                ForEach(shown, id: \.id) { chat in
                    Toggle(isOn: Binding(get: { model.config[keyPath: selected].contains(chat.id) }, set: { set(chat.id, $0) })) {
                        HStack {
                            Image(systemName: chat.isGroup ? "person.2" : "person").foregroundStyle(.secondary)
                            Text(chat.name).lineLimit(1)
                            Spacer()
                            Text("\(chat.messageCount)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ list: inout [String], _ id: String, _ on: Bool) {
        if on { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
    }

    private func load() async {
        let result = await Task.detached { () -> ([ChatSummary], [ChatSummary], [String]) in
            var errors: [String] = []
            let a: [ChatSummary]; let b: [ChatSummary]
            if FileManager.default.fileExists(atPath: IMessageConnector.defaultDatabase.path) {
                do { a = try IMessageConnector.listChats() } catch { a = []; errors.append("Messages can't be read. Allow Full Disk Access for Offload in System Settings → Privacy & Security.") }
            } else { a = [] }
            if FileManager.default.fileExists(atPath: WhatsAppConnector.defaultDatabase.path) {
                do { b = try WhatsAppConnector.listChats() } catch { b = []; errors.append("WhatsApp's data can't be read (Full Disk Access, or an unsupported WhatsApp version).") }
            } else { b = [] }
            return (Array(a.prefix(200)), Array(b.prefix(200)), errors)
        }.value
        imessage = result.0; whatsapp = result.1; problems = result.2; loading = false
    }
}
