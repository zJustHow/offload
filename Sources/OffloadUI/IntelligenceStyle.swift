import SwiftUI

/// The visual language shared by every surface: the colors of Apple's "intelligence" glow and the
/// motion curves Apple's own pages use.
///
/// Provenance, stated plainly. The *easing curves* below are read from the CSS of
/// apple.com/apple-intelligence (`cubic-bezier(0.66,0,0.1,1)`, `(0.165,0.84,0.44,1)`,
/// `(0.28,0.11,0.32,1)`), as is the white "rim light" conic gradient used on glass edges. The
/// *glow colors* are NOT in that CSS (the glow is video there); they are the seven values widely used
/// in community re-creations of the Apple Intelligence glow, so treat them as an approximation.
public enum IntelligenceStyle {
    public static let hexes: [UInt32] = [0xBC82F3, 0xF5B9EA, 0x8D99FF, 0xAA6EEE, 0xFF6778, 0xFFBA71, 0xC686FF]
    public static let colors: [Color] = hexes.map { Color(hex: $0) }

    /// Expressive ease in/out: surfaces growing out of the notch.
    public static let expressive = Animation.timingCurve(0.66, 0, 0.1, 1, duration: 0.6)
    /// Fast-out, long settle: content arriving.
    public static let entrance = Animation.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.5)
    /// Gentle ease for fades.
    public static let settle = Animation.timingCurve(0.28, 0.11, 0.32, 1, duration: 0.4)
    public static let notchSpring = Animation.spring(duration: 0.55, bounce: 0.18)

    /// Conic highlight Apple puts on glass edges: bright on two opposite arcs, clear between them.
    public static func rimLight(opacity: Double = 1) -> AngularGradient {
        func w(_ a: Double) -> Color { .white.opacity(a * opacity) }
        return AngularGradient(stops: [
            .init(color: w(0.08), location: 0), .init(color: w(0.48), location: 64.8 / 360), .init(color: w(0.48), location: 115.2 / 360),
            .init(color: w(0.08), location: 0.5), .init(color: w(0), location: 208.8 / 360), .init(color: w(0), location: 331.2 / 360),
            .init(color: w(0.08), location: 1),
        ], center: .center, angle: .degrees(90))
    }

    /// Gradient stops for one glow layer at a moment in time. Colors keep their order; only their
    /// positions drift, by less than half the gap between neighbours, so the stops never cross
    /// (crossing would make colors jump) and the first and last stop share a color so the sweep
    /// closes into a seamless ring.
    public static func gradientStops(phase: Double, layer: Int, hexes: [UInt32] = IntelligenceStyle.hexes) -> [Gradient.Stop] {
        let n = hexes.count
        let amplitude = 0.38 / Double(n)
        var stops: [Gradient.Stop] = [.init(color: Color(hex: hexes[0]), location: 0)]
        for i in 1..<n {
            let drift = amplitude * sin(phase * (0.55 + 0.11 * Double(i)) + Double(i) * 2.1 + Double(layer) * 0.9)
            stops.append(.init(color: Color(hex: hexes[i]), location: Double(i) / Double(n) + drift))
        }
        stops.append(.init(color: Color(hex: hexes[0]), location: 1))
        return stops
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
