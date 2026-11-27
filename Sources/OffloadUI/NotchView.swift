import SwiftUI

private struct SurfaceRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The assistant that lives in the notch. It grows out of the notch's own silhouette and shrinks back
/// when it is done. It is black, white and gray only: no colored glow, no accent colors.
public struct NotchView: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    /// A fixed animation clock for still renders; nil means "use the real clock".
    var fixedPhase: Double?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public static let canvas = CGSize(width: 660, height: 520)

    public init(model: NotchModel, geometry: NotchGeometry, fixedPhase: Double? = nil) {
        self.model = model; self.geometry = geometry; self.fixedPhase = fixedPhase
    }

    private var phase: NotchModel.Phase { model.phase }
    private var planLines: [String] { model.approval?.kind == .plan ? NotchModel.planLines(from: model.approval?.detail ?? "") : [] }
    private var size: CGSize {
        NotchLayout.size(
            phase: phase, notch: geometry.rect.size, steps: model.steps.count, answerLength: model.answer.count,
            checklist: model.visibleChecklist.count, planLines: planLines.count, options: model.options.count)
    }
    /// A long answer's card dissolves from black into glass along its bottom edge.
    private var fadesToGlass: Bool { NotchLayout.fadesToGlass(phase: phase, answerLength: model.answer.count) }
    private var shape: NotchShape { let r = NotchLayout.radii(phase: phase); return NotchShape(topRadius: r.top, bottomRadius: r.bottom) }

    public var body: some View {
        ZStack(alignment: .top) {
            if phase != .hidden {
                ZStack(alignment: .top) {
                    NotchSurface(shape: shape, fade: fadesToGlass ? 1 : 0)
                    // A thin white rim light on the edge, the only ornament the surface has.
                    shape.strokeBorder(IntelligenceStyle.rimLight(opacity: 0.55), lineWidth: 0.7)
                    content
                        .padding(.top, phase == .compact ? 0 : geometry.height + 8).padding(.horizontal, phase == .compact ? 10 : 22).padding(.bottom, phase == .compact ? 0 : 14)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipShape(shape)
                }
                .frame(width: size.width, height: size.height)
                .background(GeometryReader { g in Color.clear.preference(key: SurfaceRectKey.self, value: g.frame(in: .named("panel"))) })
                .transition(still(.opacity.combined(with: .scale(scale: 0.9, anchor: .top))))
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(SurfaceRectKey.self) { rect in
            // Publishing from inside a layout pass can re-enter SwiftUI; hop to the next turn.
            DispatchQueue.main.async { model.interactiveRect = rect.insetBy(dx: -24, dy: -8) }
        }
        // Reduce Motion: surfaces still change size and content, but with a quick fade, not a spring.
        .animation(reduceMotion ? .easeOut(duration: 0.15) : IntelligenceStyle.notchSpring, value: phase)
        .animation(reduceMotion ? nil : IntelligenceStyle.entrance, value: model.steps.count)
        .animation(reduceMotion ? nil : IntelligenceStyle.entrance, value: model.checklist)
        .onKeyPress(.escape) { model.dismiss(); return .handled }
        .onChange(of: phase) { _, p in if p == .input || (p == .question && model.options.isEmpty) { focused = true } }
        .onAppear { if phase == .input || (phase == .question && model.options.isEmpty) { focused = true } }
    }

    /// Still renders (previews, tests) capture a view the instant it is inserted, when a transition
    /// would still hold it at zero opacity; they get no transition at all.
    private func still(_ t: AnyTransition) -> AnyTransition { fixedPhase != nil ? .identity : reduceMotion ? .opacity : t }
    private var contentTransition: AnyTransition { fixedPhase != nil ? .identity : reduceMotion ? .opacity : AnyTransition(.blurReplace) }   // Apple's "replace" cross-fade through a blur

    // MARK: content per phase

    @ViewBuilder private var content: some View {
        switch phase {
        case .hidden: EmptyView()
        case .compact: compact
        case .input: inputRow.transition(contentTransition)
        case .thinking: thinking.transition(contentTransition)
        case .working: working.transition(contentTransition)
        case .confirm: confirm.transition(contentTransition)
        case .question: questionView.transition(contentTransition)
        case .answer: answer.transition(contentTransition)
        case .error: error.transition(contentTransition)
        }
    }

    /// Lives in the menu-bar band beside the hardware notch: orb on the left, a short status on the right.
    private var compact: some View {
        HStack(spacing: 0) {
            ThinkingDot(size: 9, phase: fixedPhase)
            Spacer(minLength: geometry.width)
            Text(model.status).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .frame(height: geometry.height)
    }

    /// ChatGPT's composer: a round field with the send arrow at its end, and the mode as quiet pills under it.
    private var inputRow: some View {
        VStack(spacing: 10) {
            let placeholder = Self.placeholder(for: model.mode)
            let canSend = !model.input.isEmpty || model.mode == .reply   // a reply needs no instruction
            HStack(spacing: 10) {
                if fixedPhase != nil {
                    // `ImageRenderer` cannot draw AppKit-backed controls, so stills use static text.
                    Text(model.input.isEmpty ? placeholder : model.input).font(.system(size: 16))
                        .foregroundStyle(model.input.isEmpty ? Theme.tertiary : Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $model.input, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
                        .textFieldStyle(.plain).font(.system(size: 16)).foregroundStyle(Theme.text).focused($focused)
                        .onSubmit { model.submit() }
                }
                SendButton(Self.sendLabel(for: model.mode), enabled: canSend, size: 32) { model.submit() }
            }
            .padding(.leading, 18).padding(.trailing, 7).frame(height: 46)
            .background(Theme.surface, in: Capsule())
            HStack(spacing: 6) {
                ForEach(NotchModel.Mode.allCases, id: \.self) { m in
                    Button { withAnimation(.easeOut(duration: 0.15)) { model.mode = m } } label: {
                        Text(m.rawValue).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(model.mode == m ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(.clear), in: Capsule())
                            .overlay(Capsule().strokeBorder(model.mode == m ? .clear : Theme.border, lineWidth: 1))
                            .foregroundStyle(model.mode == m ? Theme.text : Theme.secondary)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.mode == m ? .isSelected : [])
                        .accessibilityHint(Self.hint(for: m))
                }
                Spacer()
                Text("esc to close").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    /// A source's file name, cut in the middle when long, so a few capsules and the buttons fit on one row.
    static func shortName(_ source: String, limit: Int = 20) -> String {
        let name = source.split(separator: "/").last.map(String.init) ?? source
        guard name.count > limit else { return name }
        let head = (limit - 1) / 2 + (limit - 1) % 2, tail = (limit - 1) / 2
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }

    static func placeholder(for mode: NotchModel.Mode) -> String {
        switch mode {
        case .ask: return "Ask about anything you know…"
        case .act: return "What should I do on this Mac?"
        case .reply: return "Say what to reply, or just press return"
        }
    }

    static func sendLabel(for mode: NotchModel.Mode) -> String {
        switch mode {
        case .ask: return "Ask"
        case .act: return "Do it"
        case .reply: return "Draft a reply"
        }
    }

    static func hint(for mode: NotchModel.Mode) -> String {
        switch mode {
        case .ask: return "Answer from what Offload knows"
        case .act: return "Let Offload operate this Mac, asking before anything risky"
        case .reply: return "Draft a reply to the message on screen, then review it before it goes anywhere"
        }
    }

    private var thinking: some View {
        HStack(spacing: 12) {
            ThinkingDot(size: 11, phase: fixedPhase)
            ShimmerText(model.status, phase: fixedPhase)
            Spacer()
            stopButton
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                ThinkingDot(size: 11, phase: fixedPhase)
                ShimmerText("Working", phase: fixedPhase)
                Spacer()
                stopButton
            }
            let shown = Array(model.steps.suffix(4))
            ForEach(Array(shown.enumerated()), id: \.offset) { i, step in
                Text(step).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(.white.opacity(i == shown.count - 1 ? 0.85 : 0.4))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            checklistRows
        }
    }

    /// The assistant's own checklist, when it keeps one: done, in progress, still to do.
    @ViewBuilder private var checklistRows: some View {
        let rows = model.visibleChecklist
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 7) {
                        Image(systemName: Self.symbol(for: item.state)).font(.system(size: 11))
                            .foregroundStyle(.white.opacity(item.state == .done ? 0.85 : item.state == .active ? 0.95 : 0.4))
                            .frame(width: 14)
                        Text(item.text).font(.system(size: 12)).lineLimit(1)
                            .foregroundStyle(.white.opacity(item.state == .active ? 0.95 : item.state == .done ? 0.5 : 0.6))
                            .strikethrough(item.state == .done, color: .white.opacity(0.35))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.text), \(Self.spoken(item.state))")
                }
            }
            .padding(.top, 6)
        }
    }

    static func symbol(for state: NotchModel.ChecklistItem.State) -> String {
        switch state { case .pending: return "circle"; case .active: return "circle.dotted.circle"; case .done: return "checkmark.circle.fill" }
    }
    static func spoken(_ state: NotchModel.ChecklistItem.State) -> String {
        switch state { case .pending: return "to do"; case .active: return "in progress"; case .done: return "done" }
    }

    private var confirm: some View {
        let request = model.approval ?? NotchModel.Approval(kind: .irreversible, detail: model.confirmation ?? "")
        return VStack(alignment: .leading, spacing: 10) {
            Label(request.kind == .plan ? "Here's my plan" : request.title, systemImage: request.kind == .plan ? "list.bullet.rectangle" : "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if request.kind == .plan {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(planLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Nothing is changed until you go ahead.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            } else {
                Text(request.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(request.kind == .irreversible ? "This cannot be undone." : request.reason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
            }
            HStack {
                Spacer()
                Button(request.kind == .plan ? "Not this plan" : "Don't allow") { model.resolveConfirmation(false) }.buttonStyle(NotchButton(prominent: false))
                Button(request.kind == .plan ? "Go ahead" : "Allow") { model.resolveConfirmation(true) }.buttonStyle(NotchButton(prominent: true))
                    .accessibilityHint(request.kind == .plan ? "Lets the assistant carry out this plan. It still asks before anything that cannot be undone." : "")
            }
        }
    }

    /// A question from the assistant while it works: answer buttons when it has a few likely answers,
    /// and always a field to type something else.
    private var questionView: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("A question", systemImage: "questionmark.bubble.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(model.question).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
            ForEach(Array(model.options.enumerated()), id: \.offset) { _, option in
                Button { model.answerQuestion(option) } label: {
                    Text(option).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white.opacity(0.92))
                }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                if fixedPhase != nil {
                    Text(model.answerInput.isEmpty ? (model.options.isEmpty ? "Type your answer" : "Or type your own answer") : model.answerInput)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(model.answerInput.isEmpty ? 0.4 : 1)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(model.options.isEmpty ? "Type your answer" : "Or type your own answer", text: $model.answerInput)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white).focused($focused)
                        .onSubmit { model.answerQuestion() }
                }
                Button("Skip") { model.skipQuestion() }.buttonStyle(NotchButton(prominent: false))
                Button("Send") { model.answerQuestion() }.buttonStyle(NotchButton(prominent: true)).disabled(model.answerInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let text = Text(model.answer).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Theme.text)
            // Only long answers need a scroll view (and `ImageRenderer` cannot draw one for stills).
            if model.answer.count > NotchLayout.longAnswer && fixedPhase == nil {
                // The text fades out above the footer, and the padding lets the last line scroll clear of the fade.
                ScrollView { text.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16) }
                    .mask(LinearGradient(stops: GlassFade.textStops(), startPoint: .top, endPoint: .bottom))
            } else {
                text.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                // A draft's buttons need the room, so it shows fewer sources.
                ForEach(Array(model.sources.prefix(model.isDraft ? 2 : 3).enumerated()), id: \.offset) { _, s in
                    let name = Self.shortName(s)
                    Text(name).font(.system(size: 10)).lineLimit(1)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Theme.surface, in: Capsule()).foregroundStyle(Theme.secondary)
                        .accessibilityLabel("Source: \(name)")
                }
                Spacer()
                if model.isDraft {
                    Button(model.copied ? "Copied" : "Copy") { model.copyDraft() }.buttonStyle(NotchButton(prominent: false))
                    Button("Insert") { model.insertDraft() }.buttonStyle(NotchButton(prominent: true))
                        .accessibilityHint("Pastes the draft into the field you were using. It is not sent.")
                }
                Button("Done") { model.dismiss() }.buttonStyle(NotchButton(prominent: false))   // always there, with or without sources
            }
        }
    }

    private var error: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white.opacity(0.85))
            Text(model.errorText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
            Spacer()
            Button("Close") { model.dismiss() }.buttonStyle(NotchButton(prominent: false))
        }
    }

    private var stopButton: some View {
        Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.secondary) }
            .buttonStyle(.plain).accessibilityLabel("Stop")
    }
}

/// The notch's buttons are ChatGPT's: a white pill for the one thing to press, an outlined pill for the rest.
struct NotchButton: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.horizontal, 15).padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.black : Theme.text)
            .background {
                if prominent { Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.78 : 0.95)) }
                else { Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)).overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1)) }
            }
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
