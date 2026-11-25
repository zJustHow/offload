import SwiftUI

/// The glow around the whole display, shown while the assistant is operating the Mac so there is
/// never any doubt about who has the mouse.
public struct ScreenEdgeGlowView: View {
    var visible: Bool
    var phase: Double?
    var cornerRadius: CGFloat
    public init(visible: Bool, phase: Double? = nil, cornerRadius: CGFloat = 14) { self.visible = visible; self.phase = phase; self.cornerRadius = cornerRadius }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let phase { IntelligenceGlow(shape: shape, phase: phase, intensity: visible ? 1 : 0, lineWidth: 3.2) }
            else { AnimatedGlow(shape: shape, intensity: visible ? 1 : 0, lineWidth: 3.2) }
        }
        .animation(IntelligenceStyle.entrance, value: visible)
        .allowsHitTesting(false)
    }
}
