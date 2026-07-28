import AppKit
import SwiftUI

struct ExpandedPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.07))

            if state.sessions.isEmpty {
                EmptyState(state: state)
            } else {
                VStack(spacing: 2) {
                    ForEach(state.visibleSessions.prefix(5)) { session in
                        SessionRow(state: state, session: session)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                if let id = state.selected, let session = state.session(id) {
                    ActivityFeed(session: session)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                }
            }

            FooterBar(state: state)
        }
    }
}

// MARK: - Row

private struct SessionRow: View {
    @ObservedObject var state: AppState
    let session: Session

    private var isSelected: Bool { state.selected == session.id }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(session.kind.tint.opacity(0.16))
                Image(systemName: session.kind.glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.kind.tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    if session.isGhost { Tag(text: "DETECTED", tint: .white.opacity(0.4)) }
                    Text(session.kind.display)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    if session.netLines.added > 0 || session.netLines.removed > 0 {
                        Text("+\(session.netLines.added)")
                            .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.55))
                        Text("−\(session.netLines.removed)")
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))

                HStack(spacing: 5) {
                    Circle().fill(session.state.color).frame(width: 5, height: 5)
                    Text(session.state == .waiting ? "needs you" : elapsed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Button {
                TerminalJumper.jump(to: session)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Jump to \(session.terminal.friendlyName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.09 : 0.035))
        )
        .overlay(alignment: .leading) {
            if session.state == .waiting {
                Capsule().fill(session.state.color)
                    .frame(width: 2.5, height: 22)
                    .padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selected = isSelected ? nil : session.id }
    }

    private var subtitle: String {
        if let notice = session.notice, !notice.isEmpty { return notice }
        if let a = session.current { return "\(a.tool)  \(a.headline)" }
        if let a = session.activities.last { return "\(a.tool)  \(a.headline)" }
        if let p = session.lastPrompt { return p }
        return session.shortCwd
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(session.startedAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

// MARK: - Activity feed

private struct ActivityFeed: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(session.shortCwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if let u = session.usage {
                    Text("\(fmt(u.totalTokens)) tok  ·  " + String(format: "$%.3f", u.cost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.activities.suffix(40).reversed()) { a in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: a.glyph)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(a.tint)
                                .frame(width: 14)
                                .padding(.top, 1)
                            Text(a.tool)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(width: 62, alignment: .leading)
                            Text(a.headline)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if a.added > 0 || a.removed > 0 {
                                Text("+\(a.added)/−\(a.removed)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            if a.status == .running {
                                ProgressView().controlSize(.mini).scaleEffect(0.55)
                                    .frame(width: 12, height: 12)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 150)
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(0.035)))
        .padding(.top, 2)
    }

    private func fmt(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Chrome

private struct EmptyState: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state.hooksInstalled ? "moon.zzz" : "exclamationmark.triangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(state.hooksInstalled ? "No agents running" : "Hooks not installed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text(state.hooksInstalled
                 ? "Start Claude Code in any terminal and it shows up here."
                 : "Open Settings and install the Claude Code hooks.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

private struct FooterBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Label("\(state.sessions.count)", systemImage: "square.stack.3d.up")
            if state.busyCount > 0 { Label("\(state.busyCount) running", systemImage: "bolt") }
            Spacer()
            Button("Clear") { state.clearFinished() }
                .buttonStyle(.plain)
            Button("Settings") { SettingsWindow.shared.show() }
                .buttonStyle(.plain)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
