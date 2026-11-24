import AppKit
import SwiftUI

/// Every duration and curve the UI uses, in one place. Perch's feel is "crisp":
/// short, decisive, no overshoot — it sits beside a terminal and should never
/// make the user wait for it. To make the whole app softer or snappier, edit
/// the numbers here and nothing else.
enum Motion {
    // MARK: island

    /// Island opening or changing while open. Barely-underdamped: settles
    /// without a visible bounce.
    static let islandOpen = Animation.spring(response: 0.30, dampingFraction: 0.88)
    /// Island collapsing. Leaving is quicker than arriving, and critically
    /// damped so it never overshoots back past the notch.
    static let islandClose = Animation.spring(response: 0.22, dampingFraction: 1.0)
    /// How long the window controller waits before clipping the window down to
    /// a smaller frame. Must outlast whichever spring is running when it shrinks
    /// (shrinks can happen while still open, e.g. a session ending).
    static let windowShrinkDelay: TimeInterval = 0.38

    // MARK: small UI

    /// Content appearing inside the island: cards, the activity feed, the plan
    /// feedback field.
    static let enter = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.18)
    /// ~70% of `enter`, accelerating away: the user has already moved on.
    static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.12)
    /// Hover tints on buttons and rows.
    static let hover = Animation.easeOut(duration: 0.10)
    /// Press down: near-instant so it lands within a frame or two of mouse-down.
    static let pressDown = Animation.easeOut(duration: 0.05)
    /// Release: a quick spring back so the click feels physical, not mechanical.
    static let pressUp = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let pressScale: CGFloat = 0.97

    // MARK: reduced motion

    /// Under Reduce Motion, geometry still has to change (the window resizes),
    /// so it changes fast and flat instead of springing.
    static let reducedResize = Animation.easeOut(duration: 0.12)
    static let reducedFade = Animation.easeOut(duration: 0.12)

    /// Content entering the island: drops in from the notch, fades out in place.
    static func content(reduced: Bool) -> AnyTransition {
        if reduced { return .opacity.animation(reducedFade) }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -4))
                .animation(enter),
            removal: .opacity.animation(exit)
        )
    }

    /// Reads the system setting directly, for code paths outside a view body.
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Shared press feedback for every button in the island. Responds on mouse-down,
/// releases on mouse-up; the action still fires exactly when it did before.
/// Under Reduce Motion it dims instead of scaling.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = Motion.pressScale

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, scale: scale)
    }

    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .contentShape(Rectangle())
                .scaleEffect(pressed && !reduceMotion ? scale : 1)
                .brightness(pressed ? (reduceMotion ? -0.12 : -0.06) : 0)
                .animation(pressed ? Motion.pressDown : Motion.pressUp, value: pressed)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
