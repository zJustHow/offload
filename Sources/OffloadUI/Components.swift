import SwiftUI

/// The shared building blocks, so every screen speaks the same visual language.
public enum Theme {
    public static let gradient = LinearGradient(colors: [Color(hex: 0xF5B9EA), Color(hex: 0xBC82F3), Color(hex: 0x8D99FF)], startPoint: .leading, endPoint: .trailing)
    public static let text = Color.white
    public static let secondary = Color.white.opacity(0.62)
    public static let tertiary = Color.white.opacity(0.38)
    public static let good = Color(hex: 0x6EE7A8)
    public static let warn = Color(hex: 0xFFBA71)
    public static let radius: CGFloat = 14
}

/// Primary call to action: the intelligence gradient with dark text.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 22).frame(minHeight: 38)
            .foregroundStyle(Color.black.opacity(0.85))
            .background(Capsule().fill(Theme.gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.6))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(IntelligenceStyle.settle, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Secondary action: a quiet pill.
public struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(minHeight: 30)
            .foregroundStyle(.white.opacity(0.88))
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.11)))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Capsule())
    }
}

/// A switch drawn in SwiftUI (not the AppKit control) so it looks identical everywhere and renders in stills.
public struct PillSwitch: View {
    @Binding var isOn: Bool
    var label: String
    public init(isOn: Binding<Bool>, label: String) { _isOn = isOn; self.label = label }

    public var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.16)))
            .frame(width: 42, height: 24)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 2, y: 1).frame(width: 20, height: 20).padding(2)
            }
            .animation(IntelligenceStyle.settle, value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isOn.toggle() }
    }
}

public struct StatusDot: View {
    var status: HealthStatus
    public init(_ status: HealthStatus) { self.status = status }
    public var body: some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            .accessibilityLabel(label)
    }
    private var symbol: String { status == .ok ? "checkmark.circle.fill" : status == .needsAction ? "exclamationmark.circle.fill" : status == .unavailable ? "xmark.circle.fill" : "circle.dashed" }
    private var color: Color { status == .ok ? Theme.good : status == .needsAction ? Theme.warn : status == .unavailable ? Color(hex: 0xFF6778) : Theme.tertiary }
    private var label: String { status == .ok ? "Ready" : status == .needsAction ? "Needs attention" : status == .unavailable ? "Unavailable" : "Optional" }
}

/// A rounded square holding an SF Symbol, tinted by the intelligence palette.
public struct SymbolBadge: View {
    var symbol: String
    var size: CGFloat
    public init(_ symbol: String, size: CGFloat = 38) { self.symbol = symbol; self.size = size }
    public var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(LinearGradient(colors: [Color(hex: 0x8D99FF).opacity(0.55), Color(hex: 0xBC82F3).opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.7))
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
                Capsule().fill(i == current ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(i < current ? 0.5 : 0.18)))
                    .frame(width: i == current ? 26 : 7, height: 7)
            }
        }
        .animation(IntelligenceStyle.expressive, value: current)
        .accessibilityElement().accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

public struct GradientText: View {
    var text: String, size: CGFloat
    public init(_ text: String, size: CGFloat = 32) { self.text = text; self.size = size }
    public var body: some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(Theme.gradient).accessibilityAddTraits(.isHeader)
    }
}

/// A thin determinate bar filled with the intelligence gradient.
public struct GradientProgress: View {
    var fraction: Double
    public init(_ fraction: Double) { self.fraction = fraction }
    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(Theme.gradient).frame(width: max(8, g.size.width * min(1, max(0, fraction))))
                    .animation(IntelligenceStyle.entrance, value: fraction)
            }
        }
        .frame(height: 8)
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

public struct StatTile: View {
    var value: String, label: String
    public init(_ value: String, _ label: String) { self.value = value; self.label = label }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

/// A scroll view that becomes a plain stack in still renders (`ImageRenderer` cannot draw AppKit-backed scrolling).
public struct AdaptiveScroll<Content: View>: View {
    @Environment(\.stillMotion) private var still
    var content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        if still { VStack(spacing: 0) { content; Spacer(minLength: 0) } } else { ScrollView(showsIndicators: false) { content } }
    }
}
