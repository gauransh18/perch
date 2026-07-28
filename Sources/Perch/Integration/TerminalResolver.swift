import AppKit
import Darwin
import Foundation

// MARK: - Known terminals

/// Terminals we can name, and what we can actually do with each one.
///
/// The list matters less than it looks: `ProcessTree` resolves the owning app
/// from the agent's parent chain, so a terminal missing from here still gets
/// focused correctly — it just doesn't get a pretty name or a precise jump.
struct TerminalApp {
    enum Precision: Int, Comparable {
        case app, window, tab, pane
        static func < (a: Precision, b: Precision) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .app: return "app"
            case .window: return "window"
            case .tab: return "tab"
            case .pane: return "pane"
            }
        }
    }

    var id: String
    var name: String
    var bundleIDs: [String]
    /// Values of TERM_PROGRAM that identify this terminal.
    var termProgram: [String] = []
    var precision: Precision = .app

    static let all: [TerminalApp] = [
        .init(id: "iterm", name: "iTerm2", bundleIDs: ["com.googlecode.iterm2"],
              termProgram: ["iTerm.app"], precision: .pane),
        .init(id: "terminal", name: "Terminal", bundleIDs: ["com.apple.Terminal"],
              termProgram: ["Apple_Terminal"], precision: .tab),
        .init(id: "wezterm", name: "WezTerm",
              bundleIDs: ["com.github.wez.wezterm", "org.wezfurlong.wezterm"],
              termProgram: ["WezTerm"], precision: .pane),
        .init(id: "kitty", name: "kitty", bundleIDs: ["net.kovidgoyal.kitty"],
              termProgram: ["kitty"], precision: .window),
        .init(id: "vscode", name: "VS Code",
              bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss"],
              termProgram: ["vscode"], precision: .window),
        .init(id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
              precision: .window),
        .init(id: "windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"],
              precision: .window),
        .init(id: "ghostty", name: "Ghostty", bundleIDs: ["com.mitchellh.ghostty"],
              termProgram: ["ghostty"]),
        .init(id: "warp", name: "Warp",
              bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
              termProgram: ["WarpTerminal", "Warp"]),
        .init(id: "alacritty", name: "Alacritty", bundleIDs: ["org.alacritty"],
              termProgram: ["Alacritty"]),
        .init(id: "hyper", name: "Hyper", bundleIDs: ["co.zeit.hyper"], termProgram: ["Hyper"]),
        .init(id: "tabby", name: "Tabby", bundleIDs: ["org.tabby"], termProgram: ["Tabby"]),
        .init(id: "rio", name: "Rio", bundleIDs: ["com.raphaelamorim.rio"], termProgram: ["rio"]),
        .init(id: "zed", name: "Zed", bundleIDs: ["dev.zed.Zed"], termProgram: ["zed"]),
        .init(id: "wave", name: "Wave", bundleIDs: ["dev.commandline.waveterm"]),
        .init(id: "iterm-nightly", name: "iTerm2", bundleIDs: ["com.googlecode.iterm2.nightly"],
              precision: .pane),
    ]

    static func byBundleID(_ bundleID: String) -> TerminalApp? {
        all.first { $0.bundleIDs.contains(bundleID) }
    }

    static func byTermProgram(_ program: String) -> TerminalApp? {
        guard !program.isEmpty else { return nil }
        return all.first { $0.termProgram.contains(program) }
    }
}

// MARK: - Process ancestry

/// Walks the agent's parent chain to find the app that owns its terminal.
///
/// This is what makes coverage open-ended. `TERM_PROGRAM` is set by some
/// terminals and not others, and multiplexers overwrite it; the parent chain is
/// always there. Whatever GUI application launched the shell is the thing to
/// bring forward, whether or not it appears in the table above.
enum ProcessTree {

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// First ancestor that is a running GUI application.
    static func owningApp(of pid: pid_t, maxDepth: Int = 12) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<maxDepth {
            if let app = NSRunningApplication(processIdentifier: current),
               app.bundleIdentifier != nil {
                return app
            }
            guard let next = parent(of: current) else { return nil }
            current = next
        }
        return nil
    }
}

// MARK: - Resolution

extension TerminalContext {

    /// The multiplexer in play, if any. Checked before the host terminal
    /// because focusing a pane and focusing the window are both required, in
    /// that order.
    enum Multiplexer { case tmux(String), screen(session: String, window: String), zellij(String), none }

    var multiplexer: Multiplexer {
        if !tmuxPane.isEmpty { return .tmux(tmuxPane) }
        if !screenSession.isEmpty { return .screen(session: screenSession, window: screenWindow) }
        if !zellijSession.isEmpty { return .zellij(zellijSession) }
        return .none
    }

    /// Best guess at the terminal application, in confidence order.
    var app: TerminalApp? {
        if !bundleID.isEmpty, let known = TerminalApp.byBundleID(bundleID) { return known }
        if let known = TerminalApp.byTermProgram(program) { return known }
        return nil
    }

    /// How precisely `TerminalJumper` can land, given what this session knows.
    var precision: TerminalApp.Precision {
        switch multiplexer {
        case .tmux: return .pane
        case .screen: return .window
        case .zellij: return .app          // no focus-by-id in zellij's CLI
        case .none: break
        }
        guard let app else { return bundleID.isEmpty ? .app : .app }
        switch app.id {
        case "iterm": return itermSession.isEmpty ? .app : .pane
        case "terminal": return tty.isEmpty ? .app : .tab
        case "wezterm": return weztermPane.isEmpty ? .app : .pane
        case "kitty": return kittyWindow.isEmpty ? .app : .window
        case "vscode", "cursor", "windsurf": return .window
        default: return .app
        }
    }

    var friendlyName: String {
        switch multiplexer {
        case .tmux(let pane): return "tmux \(pane)"
        case .screen(let session, _): return "screen \(session)"
        case .zellij(let session): return "zellij \(session)"
        case .none: break
        }
        if let app { return app.name }
        if !bundleID.isEmpty {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        if !program.isEmpty { return program }
        return tty.isEmpty ? "Terminal" : tty
    }

    /// Shown in the jump button's tooltip so the promise matches the behaviour.
    var jumpDescription: String {
        let where_ = friendlyName
        switch precision {
        case .pane: return "Jump to \(where_) — exact pane"
        case .tab: return "Jump to \(where_) — exact tab"
        case .window: return "Jump to \(where_) — exact window"
        case .app: return "Bring \(where_) forward"
        }
    }
}
