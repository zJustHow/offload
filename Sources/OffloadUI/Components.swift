import SwiftUI

/// The shared building blocks, so every screen speaks the same visual language: flat, quiet and
/// neutral, in the manner of ChatGPT's dark theme. One canvas, one raised surface, hairline borders,
/// white pills for the one thing to press, and an outline for everything else. No gradients, no
/// glow, no hue.
///
/// Provenance, stated plainly. OpenAI publishes no design tokens, so every value here is read by
/// eye from the product (and third-party write-ups put the main area near #212121 and the sidebar
/// near #171717). Treat the grays as an approximation to tune, not as a spec.
public enum Theme {
    /// The main area behind everything.
    public static let canvas = Color(hex: 0x212121)
    /// The sidebar, one step darker than the canvas.
    public static let sidebar = Color(hex: 0x171717)
    /// Raised things sitting on the canvas: cards, the composer, chips.
    public static let surface = Color(hex: 0x2F2F2F)
    /// Hover / pressed / selected, one step above `surface`.
    public static let surfaceRaised = Color(hex: 0x3C3C3C)
    public static let border = Color.white.opacity(0.10)
    public static let borderStrong = Color.white.opacity(0.22)
    public static let text = Color(hex: 0xECECEC)
    public static let secondary = Color(hex: 0xB4B4B4)
    public static let tertiary = Color(hex: 0x8E8E8E)
    /// "Good" and "needs attention" are told apart by their icon and wording, not by color.
    public static let good = Color(hex: 0xECECEC)
    public static let warn = Color(hex: 0xECECEC)
    /// Corner radius of a card; the composer and buttons are fully round.
    public static let radius: CGFloat = 16
}

/// The flat canvas every window sits on.
public struct AppBackground: View {
    public init() {}
    public var body: some View { Theme.canvas.ignoresSafeArea() }
}

public extension View {
    /// A raised, borderless card: ChatGPT's way of grouping things on the canvas.
    func surfaceCard(cornerRadius: CGFloat = Theme.radius) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The one thing to press: a white pill with black text.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18).frame(minHeight: 36)
            .foregroundStyle(Color.black)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.78 : 0.95)))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Everything else: an outlined pill.
public struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 16).frame(minHeight: 34)
            .foregroundStyle(Theme.text)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0)))
            .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A text-only button for the small "Show in Finder" kind of action: the text color, underlined, with no blue link color.
public struct PlainLinkButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).underline().foregroundStyle(Theme.text)
            .opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}

/// The round "send" arrow of ChatGPT's composer, as a picture (for a composer that is itself a button).
public struct SendGlyph: View {
    var enabled: Bool
    var size: CGFloat
    public init(enabled: Bool = true, size: CGFloat = 32) { self.enabled = enabled; self.size = size }
    public var body: some View {
        Image(systemName: "arrow.up").font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(enabled ? Color.black : Theme.tertiary)
            .frame(width: size, height: size)
            .background(Circle().fill(enabled ? Color.white : Theme.surfaceRaised))
            .accessibilityHidden(true)
    }
}

/// A working send button: a white circle with a black arrow, gray and inert when there is nothing to send.
public struct SendButton: View {
    var label: String
    var enabled: Bool
    var size: CGFloat
    var action: () -> Void
    public init(_ label: String, enabled: Bool = true, size: CGFloat = 32, action: @escaping () -> Void) {
        self.label = label; self.enabled = enabled; self.size = size; self.action = action
    }
    public var body: some View {
        Button(action: action) { SendGlyph(enabled: enabled, size: size) }
            .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
    }
}

/// A switch drawn in SwiftUI (not the AppKit control) so it looks identical everywhere and renders in stills.
public struct PillSwitch: View {
    @Binding var isOn: Bool
    var label: String
    public init(isOn: Binding<Bool>, label: String) { _isOn = isOn; self.label = label }

    public var body: some View {
        Capsule()
            .fill(isOn ? Color.white.opacity(0.95) : Theme.surfaceRaised)
            .frame(width: 40, height: 24)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(isOn ? Theme.canvas : Color.white).frame(width: 18, height: 18).padding(3)
            }
            .animation(.easeOut(duration: 0.16), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isOn.toggle() }
    }
}

/// A `Toggle` drawn as the pill switch, so a toggle inside a native `Form` looks like the rest of the app. The label sits on the left.
public struct PillToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            PillSwitch(isOn: configuration.$isOn, label: "")
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// A small segmented control in ChatGPT's manner: a gray capsule with the chosen option raised inside it.
public struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [Value]
    var title: (Value) -> String
    public init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        _selection = selection; self.options = options; self.title = title
    }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = option } } label: {
                    Text(title(option)).font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .foregroundStyle(selection == option ? Theme.text : Theme.secondary)
                        .background(Capsule().fill(selection == option ? Theme.surfaceRaised : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(3).background(Capsule().fill(Theme.surface))
    }
}

/// A round search field with a magnifier and a clear button, as at the top of ChatGPT's sidebar.
public struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void
    public init(text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {}) { _text = text; self.prompt = prompt; self.onSubmit = onSubmit }
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.text).onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Capsule().fill(Theme.surface))
    }
}

/// A text field drawn as a round gray field (for sheets and forms).
public struct PillTextFieldStyle: TextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Capsule().fill(Theme.surface))
    }
}

/// One line of a sidebar: a quiet icon and title that lights up under the pointer (and stays lit when chosen),
/// like a chat in ChatGPT's history. With no `action` it is information only.
public struct SidebarRow: View {
    var symbol: String?
    var title: String
    var trailing: String?
    var status: HealthStatus?
    var help: String?
    var selected: Bool
    var action: (() -> Void)?
    @State private var hovering = false

    public init(symbol: String? = nil, title: String, trailing: String? = nil, status: HealthStatus? = nil, help: String? = nil, selected: Bool = false, action: (() -> Void)?) {
        self.symbol = symbol; self.title = title; self.trailing = trailing; self.status = status; self.help = help; self.selected = selected; self.action = action
    }

    public var body: some View {
        let row = HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.text).frame(width: 20) }
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if let status { StatusDot(status).font(.system(size: 12)) }
            if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Theme.tertiary).monospacedDigit() }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.surfaceRaised : (hovering && action != nil ? Theme.surface : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        if let action {
            Button(action: action) { row }.buttonStyle(.plain).help(help ?? "").accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            row.help(help ?? "").accessibilityElement(children: .combine)
        }
    }
}

public struct StatusDot: View {
    var status: HealthStatus
    public init(_ status: HealthStatus) { self.status = status }
    public var body: some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(color)
            .accessibilityLabel(label)
    }
    private var symbol: String { status == .ok ? "checkmark.circle.fill" : status == .needsAction ? "exclamationmark.circle.fill" : status == .unavailable ? "xmark.circle.fill" : "circle.dashed" }
    private var color: Color { status == .ok ? Theme.good : status == .needsAction ? Theme.warn : status == .unavailable ? Theme.secondary : Theme.tertiary }
    private var label: String { status == .ok ? "Ready" : status == .needsAction ? "Needs attention" : status == .unavailable ? "Unavailable" : "Optional" }
}

/// A rounded square holding an SF Symbol, on a soft gray tile.
public struct SymbolBadge: View {
    var symbol: String
    var size: CGFloat
    public init(_ symbol: String, size: CGFloat = 36) { self.symbol = symbol; self.size = size }
    public var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.46, weight: .regular)).foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Color.white.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

/// Dots showing progress through a guided flow; the current one stretches.
public struct StepDots: View {
    var count: Int, current: Int
    public init(count: Int, current: Int) { self.count = count; self.current = current }
    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == current ? Theme.text : Color.white.opacity(i < current ? 0.45 : 0.16))
                    .frame(width: i == current ? 22 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement().accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// A screen's title: plain, semibold, no decoration.
public struct Heading: View {
    var text: String, size: CGFloat
    public init(_ text: String, size: CGFloat = 28) { self.text = text; self.size = size }
    public var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
    }
}

/// A thin determinate bar: white on a gray track.
public struct ProgressBar: View {
    var fraction: Double
    public init(_ fraction: Double) { self.fraction = fraction }
    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule().fill(Color.white.opacity(0.95)).frame(width: max(6, g.size.width * min(1, max(0, fraction))))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

public struct StatTile: View {
    var value: String, label: String
    public init(_ value: String, _ label: String) { self.value = value; self.label = label }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text).contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }
}

/// A scroll view that becomes a top-aligned, clipped column in still renders (`ImageRenderer` cannot draw AppKit-backed scrolling).
public struct AdaptiveScroll<Content: View>: View {
    @Environment(\.stillMotion) private var still
    var content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        if still { Color.clear.overlay(alignment: .top) { content }.clipped() } else { ScrollView(showsIndicators: false) { content } }
    }
}
