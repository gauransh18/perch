import Foundation
import SwiftUI

// MARK: - Agent kinds

enum AgentKind: String, Codable, CaseIterable {
    case claudeCode, codex, gemini, cursor, opencode, aider, amp, droid, qwen, goose, crush, generic

    var display: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor Agent"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        case .amp: return "Amp"
        case .droid: return "Droid"
        case .qwen: return "Qwen Code"
        case .goose: return "Goose"
        case .crush: return "Crush"
        case .generic: return "Agent"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.30)
        case .codex: return Color(red: 0.40, green: 0.85, blue: 0.70)
        case .gemini: return Color(red: 0.40, green: 0.62, blue: 0.98)
        case .cursor: return Color(red: 0.75, green: 0.75, blue: 0.82)
        case .opencode: return Color(red: 0.98, green: 0.78, blue: 0.35)
        case .aider: return Color(red: 0.55, green: 0.82, blue: 0.45)
        case .amp: return Color(red: 0.98, green: 0.45, blue: 0.55)
        case .droid: return Color(red: 0.62, green: 0.55, blue: 0.98)
        case .qwen: return Color(red: 0.55, green: 0.72, blue: 0.98)
        case .goose: return Color(red: 0.90, green: 0.65, blue: 0.40)
        case .crush: return Color(red: 0.85, green: 0.55, blue: 0.95)
        case .generic: return Color(red: 0.65, green: 0.68, blue: 0.75)
        }
    }

    var glyph: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .cursor: return "cursorarrow"
        case .opencode: return "curlybraces"
        case .aider: return "hammer"
        case .amp: return "bolt"
        case .droid: return "cpu"
        case .qwen: return "circle.hexagongrid"
        case .goose: return "bird"
        case .crush: return "square.stack.3d.up"
        case .generic: return "terminal"
        }
    }

    /// Matches a process name from `ps`.
    static func fromCommand(_ command: String) -> AgentKind? {
        let name = (command.split(separator: " ").first.map(String.init) ?? command)
        let base = (name as NSString).lastPathComponent.lowercased()
        switch base {
        case "claude": return .claudeCode
        case "codex", "codex-cli": return .codex
        case "gemini": return .gemini
        case "cursor-agent": return .cursor
        case "opencode": return .opencode
        case "aider": return .aider
        case "amp": return .amp
        case "droid": return .droid
        case "qwen": return .qwen
        case "goose": return .goose
        case "crush": return .crush
        default: return nil
        }
    }
}

// MARK: - Session state

enum SessionState: String, Codable {
    case starting, thinking, working, waiting, idle, done, failed

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .idle: return "Idle"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .starting, .thinking: return Color(red: 0.45, green: 0.68, blue: 1.0)
        case .working: return Color(red: 0.40, green: 0.85, blue: 0.62)
        case .waiting: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .idle: return Color(white: 0.55)
        case .done: return Color(red: 0.40, green: 0.85, blue: 0.62)
        case .failed: return Color(red: 1.0, green: 0.40, blue: 0.42)
        }
    }

    var isBusy: Bool { self == .working || self == .thinking || self == .starting }
}

// MARK: - Terminal context

struct TerminalContext: Codable, Equatable {
    var program: String = ""       // TERM_PROGRAM, e.g. iTerm.app / Apple_Terminal / ghostty
    var tty: String = ""           // ttys004
    var itermSession: String = ""  // ITERM_SESSION_ID
    var termSession: String = ""   // TERM_SESSION_ID (Terminal.app)
    var tmuxPane: String = ""      // TMUX_PANE, e.g. %3
    var weztermPane: String = ""
    var kittyWindow: String = ""
    var kittyListen: String = ""   // KITTY_LISTEN_ON, needed for `kitty @ --to`
    var zellijSession: String = ""
    var screenSession: String = "" // STY
    var screenWindow: String = ""  // WINDOW
    var pid: String = ""
    /// Set once the parent chain has been walked, so it happens per session
    /// rather than per hook event.
    var resolvedOwner: Bool = false
    /// Bundle id of the app that owns the terminal. Taken from
    /// `__CFBundleIdentifier` when present, then corrected by walking the
    /// agent's parent chain, which works for terminals we have never seen.
    var bundleID: String = ""

    var isEmpty: Bool {
        program.isEmpty && tty.isEmpty && tmuxPane.isEmpty && bundleID.isEmpty
    }

    init() {}

    init(headers: [String: String]) {
        program = headers["x-perch-term"] ?? ""
        tty = headers["x-perch-tty"] ?? ""
        itermSession = headers["x-perch-iterm"] ?? ""
        termSession = headers["x-perch-termsession"] ?? ""
        tmuxPane = headers["x-perch-tmux"] ?? ""
        weztermPane = headers["x-perch-wezterm"] ?? ""
        kittyWindow = headers["x-perch-kitty"] ?? ""
        kittyListen = headers["x-perch-kitty-listen"] ?? ""
        zellijSession = headers["x-perch-zellij"] ?? ""
        screenSession = headers["x-perch-screen"] ?? ""
        screenWindow = headers["x-perch-screen-window"] ?? ""
        bundleID = headers["x-perch-bundle"] ?? ""
        pid = headers["x-perch-pid"] ?? ""
    }
}

// MARK: - Activity

struct ToolActivity: Identifiable, Equatable {
    enum Status: String { case running, ok, failed, denied, blocked }

    let id = UUID()
    var tool: String
    var headline: String        // one-line summary, e.g. "Sources/Perch/main.swift"
    // Deliberately no `detail`: the multi-line preview is only ever read by the
    // approval card, which carries its own copy. Keeping it here cost ~4 KB per
    // tool call for a string nothing rendered.
    var status: Status = .running
    var startedAt = Date()
    var endedAt: Date?
    var added = 0
    var removed = 0

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    var glyph: String {
        switch tool {
        case "Read", "NotebookRead": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil.line"
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Glob", "Grep": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return "circle.dotted"
        }
    }

    var tint: Color {
        switch status {
        case .running: return Color(red: 0.45, green: 0.68, blue: 1.0)
        case .ok: return Color(white: 0.62)
        case .failed: return Color(red: 1.0, green: 0.40, blue: 0.42)
        case .denied, .blocked: return Color(red: 1.0, green: 0.72, blue: 0.25)
        }
    }
}

// MARK: - Usage

struct Usage: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var model = ""

    var totalTokens: Int { input + output + cacheWrite + cacheRead }

    var cost: Double { Pricing.shared.cost(self) }
}

// MARK: - Session

struct Session: Identifiable, Equatable {
    var id: String
    var kind: AgentKind
    var cwd: String
    var terminal = TerminalContext()
    var state: SessionState = .starting
    var activities: [ToolActivity] = []
    var lastPrompt: String?
    var notice: String?
    var usage: Usage?
    var transcriptPath: String?
    var startedAt = Date()
    var lastEventAt = Date()
    var isGhost = false          // discovered by process scan, no hook integration
    var pid: Int32?

    var project: String {
        let n = (cwd as NSString).lastPathComponent
        return n.isEmpty ? "~" : n
    }

    var shortCwd: String {
        let home = PerchPaths.home.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    var current: ToolActivity? { activities.last(where: { $0.status == .running }) }

    var netLines: (added: Int, removed: Int) {
        activities.reduce(into: (0, 0)) { acc, a in acc.0 += a.added; acc.1 += a.removed }
    }
}

// MARK: - Transcript

struct ToolChip: Identifiable, Equatable {
    let id: String            // tool_use id
    var name: String
    var summary: String
    var input: String
    var result: String?
    var isError = false
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, summary }

    let id: String
    var role: Role
    var text: String = ""
    var thinking: String = ""
    var chips: [ToolChip] = []
    var timestamp: Date?
    var model: String?
    var isMeta = false         // hook-injected, not something the human typed

    var isEmpty: Bool { text.isEmpty && thinking.isEmpty && chips.isEmpty }
}

// MARK: - Approval

struct ApprovalRequest: Identifiable, Equatable {
    enum Decision: Equatable {
        case allow
        case deny
        /// Rejected with a message for the agent to act on. Claude Code feeds
        /// `permissionDecisionReason` back into the conversation, which is what
        /// makes plan feedback work without touching the terminal.
        case feedback(String)
        /// Hand the decision back to the agent's own prompt.
        case passthrough
    }

    enum Kind { case tool, plan }

    let id = UUID()
    var kind: Kind = .tool
    var sessionID: String
    var agent: AgentKind
    var project: String
    var cwd: String
    var tool: String
    var headline: String
    var detail: String
    /// Raw Markdown, for `.plan` requests.
    var plan: String = ""
    var added = 0
    var removed = 0
    var createdAt = Date()
    var resolve: (Decision) -> Void

    /// Plans take longer to read than a one-line command. Both stay under the
    /// hook shim's 300s ceiling so Perch always answers before curl gives up.
    var expiry: TimeInterval { kind == .plan ? 270 : 240 }

    static func == (a: ApprovalRequest, b: ApprovalRequest) -> Bool { a.id == b.id }
}

// MARK: - Pricing

/// Approximate list prices, USD per million tokens. Override by dropping a
/// `pricing.json` in ~/.perch/ shaped like: {"claude-sonnet": {"in":3,"out":15,"cw":3.75,"cr":0.3}}
final class Pricing {
    static let shared = Pricing()

    struct Rate { var input: Double; var output: Double; var cacheWrite: Double; var cacheRead: Double }

    private var table: [String: Rate] = [
        "opus":   .init(input: 15,  output: 75, cacheWrite: 18.75, cacheRead: 1.50),
        "sonnet": .init(input: 3,   output: 15, cacheWrite: 3.75,  cacheRead: 0.30),
        "haiku":  .init(input: 1,   output: 5,  cacheWrite: 1.25,  cacheRead: 0.10),
        "fable":  .init(input: 3,   output: 15, cacheWrite: 3.75,  cacheRead: 0.30),
    ]

    private init() { loadOverrides() }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: PerchPaths.pricingFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        else { return }
        for (key, v) in obj {
            table[key.lowercased()] = Rate(input: v["in"] ?? 0, output: v["out"] ?? 0,
                                           cacheWrite: v["cw"] ?? 0, cacheRead: v["cr"] ?? 0)
        }
    }

    func cost(_ u: Usage) -> Double {
        let model = u.model.lowercased()
        let rate = table.first(where: { model.contains($0.key) })?.value ?? table["sonnet"]!
        return (Double(u.input) * rate.input
                + Double(u.output) * rate.output
                + Double(u.cacheWrite) * rate.cacheWrite
                + Double(u.cacheRead) * rate.cacheRead) / 1_000_000
    }
}
