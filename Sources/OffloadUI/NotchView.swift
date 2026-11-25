import SwiftUI

private struct SurfaceRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The assistant that lives in the notch. It grows out of the notch's own silhouette, wears an
/// Apple-Intelligence glow while it works, and shrinks back when it is done.
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
    private var size: CGSize { NotchLayout.size(phase: phase, notch: geometry.rect.size, steps: model.steps.count, answerLength: model.answer.count) }
    private var shape: NotchShape { let r = NotchLayout.radii(phase: phase); return NotchShape(topRadius: r.top, bottomRadius: r.bottom) }

    public var body: some View {
        ZStack(alignment: .top) {
            if phase != .hidden {
                ZStack(alignment: .top) {
                    shape.fill(Color.black)
                    // The glow sits ON the edge of the surface (above the black fill, below the
                    // content): its inner half is the bright line, its outer half the halo.
                    glow
                    shape.strokeBorder(IntelligenceStyle.rimLight(opacity: 0.6 * (1 - model.glow * 0.6)), lineWidth: 0.7)
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
        .onKeyPress(.escape) { model.dismiss(); return .handled }
        .onChange(of: phase) { _, p in if p == .input { focused = true } }
        .onAppear { if phase == .input { focused = true } }
    }

    /// Still renders (previews, tests) capture a view the instant it is inserted, when a transition
    /// would still hold it at zero opacity; they get no transition at all.
    private func still(_ t: AnyTransition) -> AnyTransition { fixedPhase != nil ? .identity : reduceMotion ? .opacity : t }
    private var contentTransition: AnyTransition { fixedPhase != nil ? .identity : reduceMotion ? .opacity : AnyTransition(.blurReplace) }   // Apple's "replace" cross-fade through a blur

    // MARK: glow

    @ViewBuilder private var glow: some View {
        Group {
            if let p = fixedPhase {
                IntelligenceGlow(shape: shape, phase: p, intensity: model.glow, lineWidth: 2.2)
            } else {
                AnimatedGlow(shape: shape, intensity: model.glow, lineWidth: 2.2)
                    .animation(IntelligenceStyle.settle, value: model.glow)
            }
        }
        // The top of the surface is flush with the top of the screen (it IS the notch), so nothing
        // should glow there: fade the light in over the first few points below the shoulders.
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: phase == .compact ? 8 : 26)
                Color.black
            }
            // Top-aligned with the glow, and taller than it so the halo below the surface survives.
            // (An extra offset here once pushed the mask below short surfaces and erased their glow.)
            .frame(width: size.width + 200, height: size.height + 200)
        }
    }

    // MARK: content per phase

    @ViewBuilder private var content: some View {
        switch phase {
        case .hidden: EmptyView()
        case .compact: compact
        case .input: inputRow.transition(contentTransition)
        case .thinking: thinking.transition(contentTransition)
        case .working: working.transition(contentTransition)
        case .confirm: confirm.transition(contentTransition)
        case .answer: answer.transition(contentTransition)
        case .error: error.transition(contentTransition)
        }
    }

    /// Lives in the menu-bar band beside the hardware notch: orb on the left, a short status on the right.
    private var compact: some View {
        HStack(spacing: 0) {
            IntelligenceOrb(size: 15, phase: fixedPhase)
            Spacer(minLength: geometry.width)
            Text(model.status).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
        }
        .frame(height: geometry.height)
    }

    private var inputRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                IntelligenceOrb(size: 18, phase: fixedPhase)
                let placeholder = model.mode == .ask ? "Ask about anything you know…" : "What should I do on this Mac?"
                if fixedPhase != nil {
                    // `ImageRenderer` cannot draw AppKit-backed controls, so stills use static text.
                    Text(model.input.isEmpty ? placeholder : model.input).font(.system(size: 16))
                        .foregroundStyle(.white.opacity(model.input.isEmpty ? 0.4 : 1)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $model.input)
                        .textFieldStyle(.plain).font(.system(size: 16)).foregroundStyle(.white).focused($focused)
                        .onSubmit { model.submit() }
                }
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(model.input.isEmpty ? .white.opacity(0.25) : .white)
                }.buttonStyle(.plain).disabled(model.input.isEmpty)
                    .accessibilityLabel(model.mode == .ask ? "Ask" : "Do it")
            }
            HStack(spacing: 6) {
                ForEach(NotchModel.Mode.allCases, id: \.self) { m in
                    Button { withAnimation(IntelligenceStyle.settle) { model.mode = m } } label: {
                        Text(m.rawValue).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(model.mode == m ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                            .foregroundStyle(.white.opacity(model.mode == m ? 1 : 0.5))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.mode == m ? .isSelected : [])
                        .accessibilityHint(m == .ask ? "Answer from what Offload knows" : "Let Offload operate this Mac, asking before anything risky")
                }
                Spacer()
                Text("esc to close").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private var thinking: some View {
        HStack(spacing: 12) {
            IntelligenceOrb(size: 18, phase: fixedPhase)
            ShimmerText(model.status, phase: fixedPhase)
            Spacer()
            stopButton
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                IntelligenceOrb(size: 18, phase: fixedPhase)
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
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs your OK", systemImage: "hand.raised.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(model.confirmation ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("This cannot be undone.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            HStack {
                Spacer()
                Button("Don't allow") { model.resolveConfirmation(false) }.buttonStyle(NotchButton(prominent: false))
                Button("Allow") { model.resolveConfirmation(true) }.buttonStyle(NotchButton(prominent: true))
            }
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let text = Text(model.answer).font(.system(size: 14)).foregroundStyle(.white.opacity(0.92))
            // Only long answers need a scroll view (and `ImageRenderer` cannot draw one for stills).
            if model.answer.count > 420 && fixedPhase == nil {
                ScrollView { text.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                text.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                ForEach(Array(model.sources.prefix(3).enumerated()), id: \.offset) { _, s in
                    let name = s.split(separator: "/").last.map(String.init) ?? s
                    Text(name).font(.system(size: 10)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.1), in: Capsule()).foregroundStyle(.white.opacity(0.65))
                        .accessibilityLabel("Source: \(name)")
                }
                Spacer()
                Button("Done") { model.dismiss() }.buttonStyle(NotchButton(prominent: false))   // always there, with or without sources
            }
        }
    }

    private var error: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFBA71))
            Text(model.errorText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
            Spacer()
            Button("Close") { model.dismiss() }.buttonStyle(NotchButton(prominent: false))
        }
    }

    private var stopButton: some View {
        Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.55)) }
            .buttonStyle(.plain).accessibilityLabel("Stop")
    }
}

struct NotchButton: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.85))
            .background {
                if prominent { Capsule().fill(LinearGradient(colors: [Color(hex: 0xF5B9EA), Color(hex: 0xBC82F3), Color(hex: 0x8D99FF)], startPoint: .leading, endPoint: .trailing)) }
                else { Capsule().fill(.white.opacity(0.12)) }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(IntelligenceStyle.settle, value: configuration.isPressed)
    }
}
