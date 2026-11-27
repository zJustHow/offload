import AppKit
import OffloadCore
import OffloadUI
import SwiftUI

struct SuggestionsView: View {
    @ObservedObject var model: AppModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Heading("Prepared for you", size: 26).padding(.bottom, 4)
                    if model.cards.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nothing prepared yet.").font(.headline).foregroundStyle(Theme.text)
                            Text("Each night I look for replies you owe, deadlines and renewals, and prepare something to review. Nothing is ever sent or changed on its own.")
                                .foregroundStyle(Theme.secondary)
                            Button("Look now") { model.startCycle() }.buttonStyle(QuietButtonStyle()).disabled(model.cycleRunning)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
                    }
                    ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                        SuggestionCard(card: card, model: model)
                            // Cards arrive one after another with Apple's ease-out-expo curve.
                            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                            .animation(IntelligenceStyle.entrance.delay(0.06 * Double(index)), value: appeared)
                    }
                }.padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
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
                Text(card.title).font(.headline).foregroundStyle(Theme.text)
                Spacer()
                Text(card.confidence.rawValue.capitalized).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 3)
                    .background(confidenceFill, in: Capsule()).foregroundStyle(card.confidence == .high ? Color.black : Theme.text)
                    .overlay(Capsule().strokeBorder(card.confidence == .low ? Theme.borderStrong : .clear, lineWidth: 1))
                    .accessibilityLabel("Confidence: \(card.confidence.rawValue)")
            }
            Text(card.why).font(.callout).foregroundStyle(Theme.secondary)
            Text(card.preparedContent).textSelection(.enabled).foregroundStyle(Theme.text).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !card.sources.isEmpty { Text("Based on: " + card.sources.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.tertiary) }
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(card.preparedContent, forType: .string) }.buttonStyle(QuietButtonStyle())
                Button("Done") { withAnimation(IntelligenceStyle.settle) { model.setCard(card, status: "done") } }.buttonStyle(QuietButtonStyle())
                Button("Dismiss") { withAnimation(IntelligenceStyle.settle) { model.setCard(card, status: "dismissed") } }.buttonStyle(QuietButtonStyle())
                Spacer()
                Text("Nothing is sent or changed until you do it yourself.").font(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(16).surfaceCard()
    }

    /// Confidence is a brightness: a white pill for high, a gray one for medium, an outline for low.
    private var confidenceFill: Color {
        switch card.confidence { case .high: return Color.white.opacity(0.95); case .medium: return Theme.surfaceRaised; case .low: return .clear }
    }
}
