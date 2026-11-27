import SwiftUI

/// A long answer's card: solid black where the text starts, dissolving into dark glass along the
/// bottom edge so the desktop shows through and the last lines of text fade out instead of being
/// cut off. It is modelled on the response card in Apple's new Siri.
///
/// Provenance, stated plainly. Apple has not published numbers for this effect, so every value here
/// is read off screenshots by eye (solid for the top half, then an eased fade to a dark, still-blurred
/// floor); treat them as an approximation to tune, not as a spec.
enum GlassFade {
    /// Where the black starts to let go, as a fraction of the card's height.
    static let solidUntil: CGFloat = 0.5
    /// How much black is left at the very bottom. Never zero: the footer buttons and the last
    /// line of text sit on this, and white text on bare glass is unreadable over a bright desktop.
    static let floorOpacity: Double = 0.2
    /// Where the answer text starts to fade, as a fraction of the scroll area's height.
    static let textSolidUntil: CGFloat = 0.82

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// The black fill's opacity from top to bottom. `fade` 0 is a plain black card and 1 is the full
    /// fade; the stops keep the same locations either way so a change in `fade` interpolates cleanly.
    static func surfaceStops(fade: Double) -> [Gradient.Stop] {
        let f = min(max(fade, 0), 1)
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: solidUntil)]
        for i in 1...4 {
            let t = Double(i) / 4
            // An eased curve, not a straight line: a linear ramp shows a visible "start" of the fade.
            let opacity = 1 - f * (1 - floorOpacity) * smoothstep(t)
            stops.append(.init(color: .black.opacity(opacity), location: solidUntil + (1 - solidUntil) * CGFloat(t)))
        }
        return stops
    }

    /// The mask for the answer text: fully visible, then fading to nothing at the bottom of its area.
    static func textStops() -> [Gradient.Stop] {
        [.init(color: .black, location: 0), .init(color: .black, location: textSolidUntil), .init(color: .clear, location: 1)]
    }
}

/// The black layer's mask, as an `Animatable` view so its gradient is recomputed on every frame of
/// an animation (a plain gradient would jump from one state to the other).
private struct FadeMask: View, Animatable {
    var fade: Double
    var animatableData: Double { get { fade } set { fade = newValue } }
    var body: some View { LinearGradient(stops: GlassFade.surfaceStops(fade: fade), startPoint: .top, endPoint: .bottom) }
}

/// The notch's surface: black, or (for a long answer) black that dissolves into dark glass.
struct NotchSurface: View {
    var shape: NotchShape
    /// 0 is an ordinary black surface; 1 is fully faded into glass at the bottom.
    var fade: Double

    var body: some View {
        ZStack {
            // The glass sits underneath, and only shows where the black has thinned out. It is forced
            // dark so it never turns pale glass over a light desktop.
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark).opacity(fade)
            shape.fill(Color.black).mask(FadeMask(fade: fade))
        }
    }
}
