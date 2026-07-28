import SwiftUI

/// Ignores clicks for a moment after a decision card appears.
///
/// The island lives above the menu bar and grows to several hundred points the
/// instant a card arrives. A click already on its way to whatever was under the
/// pointer gets delivered to the button that just materialised there instead —
/// so a decision could be made by a click that was aimed at something else
/// entirely. System permission dialogs guard against the same thing.
///
/// Half a second, no visual change: dimming for that long reads as a flicker,
/// and a click inside the window is meant to be ignored rather than explained.
struct ClickArming: ViewModifier {
    let id: UUID
    var delay: Duration = .milliseconds(500)

    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .disabled(!armed)
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
