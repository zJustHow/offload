import SwiftUI

/// The notch's silhouette, grown into a panel: concave "shoulders" where it meets the top of the
/// screen (so it reads as the hardware notch swelling downward) and rounded bottom corners. Both
/// radii animate, which is what lets the surface morph smoothly between sizes.
public struct NotchShape: InsettableShape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    public init(topRadius: CGFloat, bottomRadius: CGFloat) { self.topRadius = topRadius; self.bottomRadius = bottomRadius }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    public func inset(by amount: CGFloat) -> NotchShape { var s = self; s.insetAmount += amount; return s }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let t = min(topRadius, r.width / 4, r.height / 2), b = min(bottomRadius, r.width / 4, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}
