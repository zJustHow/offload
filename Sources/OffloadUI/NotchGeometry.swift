import CoreGraphics
import Foundation

/// Where the notch is, in the coordinate space of the screen (origin bottom-left, as AppKit uses).
public struct NotchGeometry: Equatable, Sendable {
    public var screenFrame: CGRect
    /// The notch itself (or, on a Mac without one, a pill-sized stand-in under the menu bar).
    public var rect: CGRect
    public var hasHardwareNotch: Bool

    public var width: CGFloat { rect.width }
    public var height: CGFloat { rect.height }

    /// - Parameters mirror `NSScreen`: the safe-area inset at the top, and the menu-bar areas on
    ///   either side of the notch (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`).
    public static func compute(screenFrame: CGRect, safeAreaTop: CGFloat, topLeft: CGRect?, topRight: CGRect?) -> NotchGeometry {
        if safeAreaTop > 0, let left = topLeft, let right = topRight {
            let notchWidth = max(0, right.minX - left.maxX)
            return NotchGeometry(
                screenFrame: screenFrame,
                rect: CGRect(x: left.maxX, y: screenFrame.maxY - safeAreaTop, width: notchWidth, height: safeAreaTop),
                hasHardwareNotch: notchWidth > 0)
        }
        // No notch: a compact pill centered at the very top, about the size of a notch.
        let w: CGFloat = 190, h: CGFloat = 30
        return NotchGeometry(
            screenFrame: screenFrame, rect: CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h), hasHardwareNotch: false)
    }

    /// Whether a point (screen coordinates) falls in the notch, with a little forgiveness.
    public func contains(_ point: CGPoint, slop: CGFloat = 6) -> Bool { rect.insetBy(dx: -slop, dy: -slop).contains(point) }
}

/// How big the assistant's surface should be in each state. Pure so it can be tested; the view
/// animates between these sizes.
public enum NotchLayout {
    /// An answer longer than this (in characters) gets a scroll view, and its card fades into glass at the bottom.
    public static let longAnswer = 420

    /// Whether the surface should dissolve from black into glass along its bottom edge.
    public static func fadesToGlass(phase: NotchModel.Phase, answerLength: Int) -> Bool { phase == .answer && answerLength > longAnswer }

    /// - `checklist`: rows of the assistant's checklist being drawn; `planLines`: lines of a plan awaiting
    ///   approval (0 for an ordinary question); `options`: answer buttons under a question.
    public static func size(phase: NotchModel.Phase, notch: CGSize, steps: Int = 0, answerLength: Int = 0, checklist: Int = 0, planLines: Int = 0, options: Int = 0) -> CGSize {
        let top = notch.height
        switch phase {
        case .hidden: return CGSize(width: notch.width, height: notch.height)
        case .compact: return CGSize(width: notch.width + 2 * 104, height: notch.height)
        case .input: return CGSize(width: 500, height: top + 104)
        case .thinking: return CGSize(width: 420, height: top + 52)
        case .working:
            let list = checklist > 0 ? 8 + 20 * CGFloat(min(checklist, NotchModel.maxChecklistRows)) : 0
            return CGSize(width: 480, height: top + 40 + 21 * CGFloat(min(max(steps, 1), 4)) + list)
        case .confirm:
            return CGSize(width: 480, height: planLines > 0 ? top + 124 + 22 * CGFloat(min(planLines, NotchModel.maxPlanLines)) : top + 168)
        case .question:
            return CGSize(width: 480, height: top + 118 + 34 * CGFloat(min(options, NotchModel.maxOptions)))
        case .error: return CGSize(width: 440, height: top + 84)
        case .answer:
            let lines = max(2, Int((Double(answerLength) / 56).rounded(.up)))
            return CGSize(width: 540, height: top + min(380, 72 + CGFloat(lines) * 21))
        }
    }

    /// Corner radii: tight when tucked into the notch, generous when open.
    public static func radii(phase: NotchModel.Phase) -> (top: CGFloat, bottom: CGFloat) {
        switch phase {
        case .hidden, .compact: return (6, 12)
        case .thinking, .error: return (8, 22)
        default: return (10, 28)
        }
    }
}
