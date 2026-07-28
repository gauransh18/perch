import SwiftUI

/// Plan review. Approve, or send the agent feedback and let it keep planning —
/// Claude Code passes `permissionDecisionReason` back into the conversation, so
/// a rejection with a note reads to the agent exactly like typing it yourself.
struct PlanCard: View {
    @ObservedObject var state: AppState
    let request: ApprovalRequest

    @State private var feedback = ""
    @State private var showingFeedback = false
    @FocusState private var feedbackFocused: Bool

    private var canSend: Bool {
        !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.07))
            header
            plan
            Spacer(minLength: 0)
            if showingFeedback { feedbackField }
            actions
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.45, green: 0.68, blue: 1).opacity(0.18))
                Image(systemName: "list.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.68, blue: 1))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(request.agent.display) finished planning")
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
            Countdown(from: request.createdAt, limit: request.expiry)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: plan

    private var plan: some View {
        ScrollView {
            MarkdownView(source: request.plan)
                .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04)))
        .padding(.horizontal, 14)
    }

    // MARK: feedback

    private var feedbackField: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("What should change?", text: $feedback, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1...4)
                .focused($feedbackFocused)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
                .onSubmit(send)

            Text("Sent back to the agent as the reason it can't proceed. ⌘⏎ to send.")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                state.resolveActive(.passthrough)
            } label: {
                Text("Ask in terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if showingFeedback {
                PlanButton(title: "Send", shortcut: "⌘⏎",
                           tint: Color(red: 1, green: 0.72, blue: 0.25), filled: true, action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
            } else {
                PlanButton(title: "Feedback", shortcut: "⌘F",
                           tint: Color(red: 1, green: 0.72, blue: 0.25)) {
                    showingFeedback = true
                    feedbackFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)

                PlanButton(title: "Approve", shortcut: "⌘Y",
                           tint: Color(red: 0.35, green: 0.85, blue: 0.55), filled: true) {
                    state.resolveActive(.allow)
                    SoundEngine.shared.play(.allow)
                }
                .keyboardShortcut("y", modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .clickArmed(request.id)
    }

    private func send() {
        guard canSend else { return }
        state.resolveActive(.feedback(feedback.trimmingCharacters(in: .whitespacesAndNewlines)))
        SoundEngine.shared.play(.deny)
        feedback = ""
        showingFeedback = false
    }
}

// MARK: - Parts

private struct PlanButton: View {
    let title: String
    let shortcut: String
    let tint: Color
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(filled ? tint : tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// The hook shim gives up at 300s. Showing the remaining time makes it obvious
/// that walking away hands the decision back to the terminal rather than
/// silently approving or denying anything.
private struct Countdown: View {
    let from: Date
    let limit: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: from, by: 1)) { context in
            let left = max(0, Int(limit - context.date.timeIntervalSince(from)))
            if left <= 60 {
                Text("\(left)s")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(left <= 20 ? 0.75 : 0.35))
                    .monospacedDigit()
            }
        }
    }
}
