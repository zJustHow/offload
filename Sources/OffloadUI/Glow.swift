import SwiftUI

/// Apple-Intelligence-style glow, in white and gray: several strokes of the same shape, each a rotating angular
/// gradient of the (monochrome) palette, with progressively wider lines and heavier blur, so the
/// light has a crisp bright core and a soft halo. `phase` (seconds) drives the rotation and the
/// slow drift of the color stops; pass a fixed value to get a still frame.
public struct IntelligenceGlow<S: InsettableShape>: View {
    let shape: S
    var phase: Double
    var intensity: Double
    var lineWidth: CGFloat

    public init(shape: S, phase: Double, intensity: Double = 1, lineWidth: CGFloat = 2.5) {
        self.shape = shape; self.phase = phase; self.intensity = intensity; self.lineWidth = lineWidth
    }

    private static var layers: [(width: CGFloat, blur: CGFloat, opacity: Double, speed: Double)] {
        [(1.0, 0, 1.0, 34), (2.0, 3, 0.95, 28), (3.2, 9, 0.7, 22), (5.0, 20, 0.5, 16)]
    }

    public var body: some View {
        ZStack {
            ForEach(Array(Self.layers.enumerated()), id: \.offset) { i, l in
                shape
                    .strokeBorder(
                        AngularGradient(stops: IntelligenceStyle.gradientStops(phase: phase, layer: i), center: .center, angle: .degrees(phase * l.speed)),
                        lineWidth: lineWidth * l.width)
                    .blur(radius: l.blur)
                    .opacity(l.opacity * intensity)
            }
        }
        .compositingGroup()
    }
}

/// The same glow, animated by the clock.
public struct AnimatedGlow<S: InsettableShape>: View {
    let shape: S
    var intensity: Double
    var lineWidth: CGFloat
    public init(shape: S, intensity: Double = 1, lineWidth: CGFloat = 2.5) { self.shape = shape; self.intensity = intensity; self.lineWidth = lineWidth }
    public var body: some View {
        MotionClock { IntelligenceGlow(shape: shape, phase: $0, intensity: intensity, lineWidth: lineWidth) }
    }
}

/// ChatGPT's "working on it" mark: a small solid white dot that breathes. It is the only animated
/// ornament the interface has, besides the shimmering status text.
public struct ThinkingDot: View {
    var size: CGFloat
    var phase: Double?
    public init(size: CGFloat = 12, phase: Double? = nil) { self.size = size; self.phase = phase }

    public var body: some View { MotionClock(fixedPhase: phase) { dot($0) }.accessibilityHidden(true) }   // decoration

    /// 0...1, a slow breath. Pure so it can be tested.
    static func breath(_ t: Double) -> Double { 0.5 + 0.5 * sin(t * 3.0) }

    private func dot(_ t: Double) -> some View {
        let b = Self.breath(t)
        return Circle().fill(Color.white)
            .frame(width: size, height: size)
            .scaleEffect(0.82 + 0.18 * b)
            .opacity(0.7 + 0.3 * b)
            .frame(width: size, height: size)
    }
}

/// Offload's mark: a white disc with a dark sparkle, for the welcome and done screens.
public struct AppMark: View {
    var size: CGFloat
    public init(size: CGFloat = 56) { self.size = size }
    public var body: some View {
        Image(systemName: "sparkle").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(Color.black)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.95)))
            .accessibilityHidden(true)
    }
}

/// Text with a band of light sweeping across it — Apple's "working on it" treatment.
public struct ShimmerText: View {
    var text: String
    var font: Font
    var phase: Double?
    public init(_ text: String, font: Font = .system(size: 14, weight: .medium), phase: Double? = nil) { self.text = text; self.font = font; self.phase = phase }

    public var body: some View { MotionClock(fixedPhase: phase) { render($0) } }

    private func render(_ t: Double) -> some View {
        let sweep = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8 * 1.6 - 0.3   // -0.3 ... 1.3
        return Text(text).font(font).foregroundStyle(.white.opacity(0.42))
            .overlay {
                LinearGradient(stops: [
                    .init(color: .clear, location: sweep - 0.22), .init(color: .white, location: sweep), .init(color: .clear, location: sweep + 0.22),
                ], startPoint: .leading, endPoint: .trailing)
                .mask(Text(text).font(font))
            }
    }
}
