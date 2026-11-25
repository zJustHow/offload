import SwiftUI

/// Apple-Intelligence-style glow: several strokes of the same shape, each a rotating angular
/// gradient of the intelligence palette, with progressively wider lines and heavier blur, so the
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

/// A small rotating-gradient orb: the assistant's "I'm here / I'm working" mark.
public struct IntelligenceOrb: View {
    var size: CGFloat
    var phase: Double?
    public init(size: CGFloat = 16, phase: Double? = nil) { self.size = size; self.phase = phase }

    public var body: some View { MotionClock(fixedPhase: phase) { orb($0) }.accessibilityHidden(true) }   // decoration

    private func orb(_ t: Double) -> some View {
        ZStack {
            Circle().fill(AngularGradient(stops: IntelligenceStyle.gradientStops(phase: t, layer: 0), center: .center, angle: .degrees(t * 90)))
                .blur(radius: size * 0.08)
            Circle().fill(AngularGradient(stops: IntelligenceStyle.gradientStops(phase: t + 1.7, layer: 2), center: .center, angle: .degrees(-t * 60)))
                .blur(radius: size * 0.3).opacity(0.7).scaleEffect(0.8)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.5))
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + 0.05 * sin(t * 2.2))
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

// MARK: - Surfaces for ordinary windows

/// Soft, slowly moving color behind a window, in the intelligence palette but dark and quiet.
public struct IntelligenceBackground: View {
    var phase: Double?
    var dark: Bool
    public init(phase: Double? = nil, dark: Bool = true) { self.phase = phase; self.dark = dark }

    public var body: some View { MotionClock(minimumInterval: 1 / 20, fixedPhase: phase) { mesh($0) } }

    private func mesh(_ t: Double) -> some View {
        func p(_ x: Double, _ y: Double, _ k: Double) -> SIMD2<Float> {
            SIMD2(Float(x + 0.07 * sin(t * 0.31 + k)), Float(y + 0.07 * cos(t * 0.27 + k * 1.3)))
        }
        let base = dark ? Color(hex: 0x0B0B12) : Color(hex: 0xF4F2FA)
        let a = dark ? 0.30 : 0.22
        let c = IntelligenceStyle.colors
        // The mesh's colors are translucent, so it needs a solid floor to blend with; without one
        // it picks up whatever is behind the window and comes out garish.
        return ZStack {
            base
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], p(0.5, 0.5, 1), [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                .clear, c[2].opacity(a * 0.6), .clear,
                c[0].opacity(a), c[1].opacity(a * 0.8), c[5].opacity(a * 0.7),
                .clear, c[3].opacity(a), c[4].opacity(a * 0.6),
            ], smoothsColors: true)
        }
    }
}

public extension View {
    /// A glowing border for a field while the assistant is working on it.
    func intelligenceGlowBorder(active: Bool, cornerRadius: CGFloat = 12) -> some View {
        overlay {
            AnimatedGlow(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), intensity: active ? 1 : 0, lineWidth: 1.6)
                .animation(IntelligenceStyle.settle, value: active)
                .allowsHitTesting(false)
        }
    }

    /// Dark glass card with Apple's rim-light edge.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(IntelligenceStyle.rimLight(opacity: 0.55), lineWidth: 0.8))
    }
}
