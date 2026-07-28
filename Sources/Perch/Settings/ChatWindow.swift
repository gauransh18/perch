import AppKit
import SwiftUI

/// One chat window per session, reused. Reads the transcript the agent is
/// already writing, so it works for live sessions and finished ones alike.
@MainActor
final class ChatWindow {
    static let shared = ChatWindow()

    private var windows: [String: NSWindow] = [:]

    func open(for session: Session) {
        guard let path = session.transcriptPath else { return }

        if let w = windows[session.id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "\(session.project) — \(session.kind.display)"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 400)
        w.center()
        w.contentView = NSHostingView(rootView: ChatView(path: path, session: session))
        windows[session.id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ChatView: View {
    let path: String
    let session: Session

    @State private var messages: [ChatMessage] = []
    @State private var usage = Usage()
    @State private var filter = ""
    @State private var showMeta = false
    @State private var loaded = false

    private var visible: [ChatMessage] {
        messages.filter { m in
            if m.isMeta && !showMeta { return false }
            guard !filter.isEmpty else { return true }
            let needle = filter.lowercased()
            return m.text.lowercased().contains(needle)
                || m.chips.contains { $0.summary.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                Text(messages.isEmpty ? "Transcript is empty." : "Nothing matches “\(filter)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(visible) { message in
                                MessageBlock(message: message).id(message.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(18)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onAppear {
                        // First layout lands after the initial load, so the
                        // count change above has nothing to scroll yet.
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await follow() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(session.shortCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)

            Spacer(minLength: 12)

            if usage.totalTokens > 0 {
                Text("\(compact(usage.totalTokens)) tok · " + String(format: "$%.3f", usage.cost))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(usage.model)
            }

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Toggle("Hooks", isOn: $showMeta)
                .toggleStyle(.checkbox)
                .help("Show hook-injected messages")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help("Reveal transcript in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Poll rather than watch: the file is append-only and a 2s beat is far
    /// cheaper than an FSEvents stream per open window. MainActor because the
    /// continuation resumes on the store's utility queue otherwise, and these
    /// are `@State` writes.
    @MainActor
    private func follow() async {
        while !Task.isCancelled {
            let (u, m) = await withCheckedContinuation { continuation in
                TranscriptStore.shared.conversation(path: path) { u, m in
                    continuation.resume(returning: (u, m))
                }
            }
            usage = u
            if m.count != messages.count || m.last != messages.last { messages = m }
            loaded = true
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Message

private struct MessageBlock: View {
    let message: ChatMessage
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bubble))
            }

            if !message.thinking.isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(message.thinking)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text("Thinking")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(message.chips) { chip in
                ChipBlock(chip: chip)
            }
        }
        .opacity(message.isMeta ? 0.55 : 1)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(accent)
            if message.isMeta {
                Text("HOOK")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let t = message.timestamp {
                Text(t.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var label: String {
        switch message.role {
        case .user: return "YOU"
        case .assistant: return "CLAUDE"
        case .summary: return "SUMMARY"
        }
    }

    private var accent: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return Color(red: 0.85, green: 0.47, blue: 0.30)
        case .summary: return .secondary
        }
    }

    private var bubble: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.10)
        case .assistant: return Color.primary.opacity(0.05)
        case .summary: return Color.primary.opacity(0.03)
        }
    }
}

private struct ChipBlock: View {
    let chip: ToolChip
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(chip.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(chip.isError ? Color.red : Color.secondary)
                    Text(chip.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !chip.input.isEmpty {
                    codeBlock(chip.input, title: "Input")
                }
                if let result = chip.result, !result.isEmpty {
                    codeBlock(result, title: chip.isError ? "Error" : "Result")
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
    }

    private func codeBlock(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
    }
}
