import SwiftUI

struct ApprovalCard: View {
    @ObservedObject var state: AppState
    let request: ApprovalRequest

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.07))

            header
            body_
            actions
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 1, green: 0.72, blue: 0.25).opacity(0.18))
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.25))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(request.agent.display) wants to run \(request.tool)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(request.project.isEmpty ? request.cwd : request.project)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            if state.approvals.count > 1 {
                Tag(text: "+\(state.approvals.count - 1) QUEUED", tint: .white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.headline)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !request.detail.isEmpty {
                ScrollView {
                    Text(attributed(request.detail))
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 196)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.04)))
            }

            if request.added > 0 || request.removed > 0 {
                HStack(spacing: 8) {
                    Text("+\(request.added)")
                        .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.55))
                    Text("−\(request.removed)")
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    Spacer()
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
        }
        .padding(.horizontal, 14)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                state.resolveActive(.passthrough)
                SoundEngine.shared.play(.start)
            } label: {
                Text("Ask in terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            ActionButton(title: "Deny", shortcut: "⌘N", tint: Color(red: 1, green: 0.42, blue: 0.44)) {
                state.resolveActive(.deny)
                SoundEngine.shared.play(.deny)
            }
            .keyboardShortcut("n", modifiers: .command)

            ActionButton(title: "Allow", shortcut: "⌘Y",
                         tint: Color(red: 0.35, green: 0.85, blue: 0.55), filled: true) {
                state.resolveActive(.allow)
                SoundEngine.shared.play(.allow)
            }
            .keyboardShortcut("y", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .clickArmed(request.id)
    }

    /// Colourise the -/+ diff preview without pulling in a syntax engine.
    private func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            var piece = AttributedString(i == 0 ? line : "\n" + line)
            if line.hasPrefix("+") {
                piece.foregroundColor = Color(red: 0.48, green: 0.88, blue: 0.6)
            } else if line.hasPrefix("-") {
                piece.foregroundColor = Color(red: 1, green: 0.5, blue: 0.5)
            } else {
                piece.foregroundColor = .white.opacity(0.6)
            }
            out.append(piece)
        }
        return out
    }
}

private struct ActionButton: View {
    let title: String
    let shortcut: String
    let tint: Color
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
    }
}
