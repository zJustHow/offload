import AppKit
import OffloadCore
import OffloadUI
import SwiftUI

struct SuggestionsView: View {
    @ObservedObject var model: AppModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            IntelligenceBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        IntelligenceOrb(size: 22)
                        Text("Prepared for you").font(.title2.weight(.semibold)).foregroundStyle(.white).accessibilityAddTraits(.isHeader)
                    }.padding(.bottom, 4)
                    if model.cards.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nothing prepared yet.").font(.headline).foregroundStyle(.white)
                            Text("Each night I look for replies you owe, deadlines and renewals, and prepare something to review. Nothing is ever sent or changed on its own.")
                                .foregroundStyle(Theme.secondary)
                            Button("Look now") { model.startCycle() }.buttonStyle(QuietButtonStyle()).disabled(model.cycleRunning)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                    }
                    ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                        SuggestionCard(card: card, model: model)
                            // Cards arrive one after another with Apple's ease-out-expo curve.
                            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                            .animation(IntelligenceStyle.entrance.delay(0.06 * Double(index)), value: appeared)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { appeared = true }
    }
}

struct SuggestionCard: View {
    let card: Card
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.title).font(.headline).foregroundStyle(.white)
                Spacer()
                Text(card.confidence.rawValue.capitalized).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(confidenceGradient, in: Capsule()).foregroundStyle(.black.opacity(0.8))
                    .accessibilityLabel("Confidence: \(card.confidence.rawValue)")
            }
            Text(card.why).font(.callout).foregroundStyle(Theme.secondary)
            Text(card.preparedContent).textSelection(.enabled).foregroundStyle(.white.opacity(0.92)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !card.sources.isEmpty { Text("Based on: " + card.sources.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.tertiary) }
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(card.preparedContent, forType: .string) }.buttonStyle(QuietButtonStyle())
                Button("Done") { withAnimation(IntelligenceStyle.settle) { model.setCard(card, status: "done") } }.buttonStyle(QuietButtonStyle())
                Button("Dismiss") { withAnimation(IntelligenceStyle.settle) { model.setCard(card, status: "dismissed") } }.buttonStyle(QuietButtonStyle())
                Spacer()
                Text("Nothing is sent or changed until you do it yourself.").font(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(16).glassCard()
    }

    private var confidenceGradient: LinearGradient {
        let c: [Color] = card.confidence == .high ? [Color(hex: 0xC686FF), Color(hex: 0x8D99FF)]
            : card.confidence == .medium ? [Color(hex: 0xF5B9EA), Color(hex: 0xBC82F3)] : [Color(hex: 0xFFBA71), Color(hex: 0xFF6778)]
        return LinearGradient(colors: c, startPoint: .leading, endPoint: .trailing)
    }
}
