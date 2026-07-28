import SwiftUI

struct NotchRootView: View {
    @ObservedObject var state: AppState
    let geometry: NotchGeometry

    private var notchWidth: CGFloat { geometry.notchRect.width }
    private var notchHeight: CGFloat { geometry.notchRect.height }
    private var mode: Presentation { state.presentation }
    private var open: Bool { mode == .expanded || mode == .approval }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One animation modifier only: stacking several `.animation(_:value:)`
        // on the same view leaves in-flight transitions stranded.
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: animationKey)
    }

    /// Everything that should trigger the island's spring, folded into one value.
    private var animationKey: String {
        "\(mode)|\(state.selected ?? "-")|\(state.sessions.count)|\(state.activeApproval?.id.uuidString ?? "-")"
    }

    private var island: some View {
        VStack(spacing: 0) {
            HeadBar(state: state, notchWidth: notchWidth, height: notchHeight, mode: mode)

            // ZStack, not VStack: during a crossfade the outgoing panel must
            // overlay the incoming one instead of pushing it down the screen.
            ZStack(alignment: .top) {
                if mode == .approval, let request = state.activeApproval {
                    ApprovalCard(state: state, request: request)
                        .id(request.id)
                        .transition(.opacity)
                } else if mode == .expanded {
                    ExpandedPanel(state: state)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(background)
        .overlay(alignment: .topLeading) { flare(mirrored: false) }
        .overlay(alignment: .topTrailing) { flare(mirrored: true) }
        .compositingGroup()
        .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 24, y: 10)
        .onHover { hovering in
            state.hovering = hovering
            if !hovering { state.selected = nil }
        }
    }

    @ViewBuilder private var background: some View {
        if mode == .hidden {
            Color.black.opacity(0.001)
        } else {
            NotchShape(bottomRadius: open ? 20 : 13)
                .fill(Color.black)
                .overlay(
                    NotchShape(bottomRadius: open ? 20 : 13)
                        .stroke(Color.white.opacity(open ? 0.10 : 0.04), lineWidth: 1)
                )
        }
    }

    @ViewBuilder private func flare(mirrored: Bool) -> some View {
        if mode != .hidden {
            Flare(mirrored: mirrored)
                .fill(Color.black)
                .frame(width: 9, height: 9)
                .offset(x: mirrored ? 9 : -9)
        }
    }
}

// MARK: - Head bar (the strip level with the physical notch)

private struct HeadBar: View {
    @ObservedObject var state: AppState
    let notchWidth: CGFloat
    let height: CGFloat
    let mode: Presentation

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Color.clear.frame(width: notchWidth)
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { state.pinned.toggle() }
    }

    @ViewBuilder private var leading: some View {
        if mode == .hidden {
            EmptyView()
        } else {
            HStack(spacing: 7) {
                Pulse(color: state.headline.color, animating: state.headline.isBusy)
                if mode == .collapsed {
                    Text(collapsedLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                } else {
                    Text("PERCH")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if mode == .hidden {
            EmptyView()
        } else if mode == .collapsed {
            HStack(spacing: 8) {
                if let s = state.visibleSessions.first, let a = s.current {
                    Image(systemName: a.glyph)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                ActivityBars(active: state.busyCount > 0)
            }
        } else {
            HStack(spacing: 10) {
                if state.approvalMode {
                    Tag(text: "APPROVAL", tint: Color(red: 1, green: 0.72, blue: 0.25))
                }
                if state.totalCost > 0 {
                    Text(String(format: "$%.3f", state.totalCost))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(state.pinned ? 0.8 : 0.35))
            }
        }
    }

    private var collapsedLabel: String {
        if state.waitingCount > 0 { return "\(state.waitingCount) waiting" }
        if state.busyCount > 0 {
            if let s = state.visibleSessions.first, let a = s.current {
                return ToolSummary.truncate("\(a.tool) \(a.headline)", 26)
            }
            return "\(state.busyCount) running"
        }
        return state.sessions.isEmpty ? "no agents" : "\(state.sessions.count) idle"
    }
}

// MARK: - Small parts

struct Pulse: View {
    let color: Color
    var animating: Bool
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(phase ? 2.1 : 1)
                    .opacity(phase ? 0 : 0.9)
            )
            .onAppear { if animating { start() } }
            .onChange(of: animating) { _, on in if on { start() } else { phase = false } }
    }

    private func start() {
        phase = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = true }
    }
}

struct ActivityBars: View {
    let active: Bool
    @State private var t: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = active
                        ? 3 + 8 * (0.5 + 0.5 * sin(time * 5 + Double(i) * 0.9))
                        : 3
                    Capsule()
                        .fill(Color.white.opacity(active ? 0.75 : 0.22))
                        .frame(width: 2, height: h)
                }
            }
            .frame(height: 12)
        }
    }
}

struct Tag: View {
    let text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}
