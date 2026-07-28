import SwiftUI

/// Two-step button for the one direction that is hard to undo.
///
/// Denying a tool call or sending plan feedback is recoverable — the agent just
/// asks again. Approving is not: the edit lands, the command runs. The island
/// sits above every other window and resizes itself under whatever the pointer
/// happens to be doing, so a single press arriving at the wrong moment must not
/// be able to say yes. First press arms and relabels, second press commits, and
/// it disarms itself if nothing follows.
struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    let shortcut: String
    let tint: Color
    var window: Duration = .seconds(4)
    let action: () -> Void

    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            if armed {
                disarm?.cancel()
                armed = false
                action()
            } else {
                armed = true
                disarm?.cancel()
                disarm = Task {
                    try? await Task.sleep(for: window)
                    if !Task.isCancelled { armed = false }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if armed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(armed ? confirmTitle : title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(armed ? Color(red: 1, green: 0.72, blue: 0.25) : tint))
            .animation(.easeOut(duration: 0.15), value: armed)
        }
        .buttonStyle(.plain)
        .onDisappear { disarm?.cancel() }
    }
}
