import OffloadCore
import OffloadUI
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
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Heading("Choose chats", size: 24)
                    Text("I only read the conversations you tick. Messages are read on this Mac.").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                SearchField(text: $filter, prompt: "Filter")
                if loading { HStack { Spacer(); ThinkingDot(size: 12); Spacer() }.padding() }
                ForEach(problems, id: \.self) { p in
                    Label(p, systemImage: "lock").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Messages", imessage, selected: \.imessageChats) { id, on in model.update { c in toggle(&c.imessageChats, id, on) } }
                        section("WhatsApp", whatsapp, selected: \.whatsappChats) { id, on in model.update { c in toggle(&c.whatsappChats, id, on) } }
                    }
                }
                HStack { Spacer(); Button("Done") { model.windows.close("chats") }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle()) }
            }
            .padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 22)
        }
        .environment(\.colorScheme, .dark).tint(Theme.text)
        .task { await load() }
    }

    @ViewBuilder private func section(_ title: String, _ chats: [ChatSummary], selected: KeyPath<OffloadConfig, [String]>, set: @escaping (String, Bool) -> Void) -> some View {
        let shown = chats.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, chat in
                        Toggle(isOn: Binding(get: { model.config[keyPath: selected].contains(chat.id) }, set: { set(chat.id, $0) })) {
                            HStack(spacing: 10) {
                                Image(systemName: chat.isGroup ? "person.2" : "person").foregroundStyle(Theme.tertiary).frame(width: 20)
                                Text(chat.name).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                Text("\(chat.messageCount)").font(.system(size: 12)).foregroundStyle(Theme.tertiary).monospacedDigit()
                            }
                        }
                        .toggleStyle(PillToggleStyle())
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        if i < shown.count - 1 { Divider().overlay(Theme.border) }
                    }
                }
                .surfaceCard()
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
