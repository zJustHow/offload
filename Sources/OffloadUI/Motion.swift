import SwiftUI

private struct StillMotionKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    /// Forces still frames (previews and tests). The system's Reduce Motion setting has the same effect.
    var stillMotion: Bool {
        get { self[StillMotionKey.self] }
        set { self[StillMotionKey.self] = newValue }
    }
}

/// The one clock every continuous animation reads. With Reduce Motion on (or `stillMotion` set) it
/// stops: content is drawn once at a pleasant fixed moment instead of animating forever.
struct MotionClock<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillMotion) private var still
    var minimumInterval: Double?
    var fixedPhase: Double?
    @ViewBuilder var content: (Double) -> Content

    static var restingPhase: Double { 2.6 }

    var body: some View {
        if let fixedPhase { content(fixedPhase) }
        else if reduceMotion || still { content(Self.restingPhase) }
        else if let minimumInterval { TimelineView(.animation(minimumInterval: minimumInterval)) { content($0.date.timeIntervalSinceReferenceDate) } }
        else { TimelineView(.animation) { content($0.date.timeIntervalSinceReferenceDate) } }
    }
}

/// An animation that does nothing when the user asked for less motion.
public func intelligentAnimation(_ animation: Animation?, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }
