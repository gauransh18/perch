import SwiftUI

/// Ignores clicks for a moment after a decision card appears.
///
/// The island lives above the menu bar and grows to several hundred points the
/// instant a card arrives. If the pointer happens to be resting where a button
/// lands — and after a resize it very often is — an in-flight click is delivered
/// straight to that button. In testing this approved plans by itself within
/// seconds, repeatedly, with nobody aiming at anything.
///
/// System permission dialogs guard against exactly this. Same idea here: the
/// buttons are inert and visibly dimmed until the card has been on screen long
/// enough that a click has to be deliberate.
struct ClickArming: ViewModifier {
    let id: UUID
    var delay: Duration = .milliseconds(500)

    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .disabled(!armed)
            .opacity(armed ? 1 : 0.5)
            .allowsHitTesting(armed)
            .task(id: id) {
                armed = false
                try? await Task.sleep(for: delay)
                armed = true
            }
    }
}

extension View {
    /// Applied to a card's action row. `id` restarts the delay for each new card
    /// so a queued second decision cannot inherit the first one's armed state.
    func clickArmed(_ id: UUID) -> some View {
        modifier(ClickArming(id: id))
    }
}
