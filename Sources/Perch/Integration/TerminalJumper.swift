import AppKit
import Foundation

/// Brings the exact terminal an agent is running in back to the front.
///
/// Resolution order is multiplexer, then terminal, then owning app, then the
/// project folder. Each step narrows as far as that terminal's own tooling
/// allows and then hands off — focusing a tmux pane still needs the window it
/// lives in raised afterwards, and a terminal with no scripting interface at
/// least gets activated rather than ignored.
enum TerminalJumper {

    static func jump(to session: Session) {
        let terminal = session.terminal

        // 1. Multiplexers own the pane; the host terminal owns the window.
        switch terminal.multiplexer {
        case .tmux(let pane):
            focusTmux(pane: pane, terminal: terminal)
        case .screen(let name, let window):
            focusScreen(session: name, window: window)
        case .zellij:
            break   // zellij's CLI has no focus-by-id; the window is the best we can do
        case .none:
            break
        }

        // 2. Terminal-specific precision.
        if case .none = terminal.multiplexer, focusExactly(terminal, cwd: session.cwd) {
            return
        }

        // 3. Whatever app owns it, named or not.
        if activateOwner(of: terminal) { return }

        // 4. Never a dead end.
        if !session.cwd.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        }
    }

    // MARK: - Exact targets

    /// Returns true when it both located and raised the precise pane/tab/window.
    private static func focusExactly(_ t: TerminalContext, cwd: String) -> Bool {
        switch t.app?.id {
        case "iterm", "iterm-nightly":
            guard !t.itermSession.isEmpty, focusITerm(sessionID: t.itermSession) else { return false }
            return true

        case "terminal":
            guard !t.tty.isEmpty, focusAppleTerminal(tty: devPath(t.tty)) else { return false }
            return true

        case "wezterm":
            guard !t.weztermPane.isEmpty else { return false }
            run("wezterm", ["cli", "activate-pane", "--pane-id", t.weztermPane])
            return activateOwner(of: t)

        case "kitty":
            guard !t.kittyWindow.isEmpty else { return false }
            // `--to` matters: without it the command only reaches kitty when a
            // single instance is listening on the default socket.
            var args = ["@"]
            if !t.kittyListen.isEmpty { args += ["--to", t.kittyListen] }
            args += ["focus-window", "--match", "id:\(t.kittyWindow)"]
            run("kitty", args)
            return activateOwner(of: t)

        case "vscode", "cursor", "windsurf":
            // No API for focusing an integrated terminal tab, but reusing the
            // window already open on this folder lands in the right place.
            guard !cwd.isEmpty else { return false }
            let cli = ["vscode": "code", "cursor": "cursor", "windsurf": "windsurf"][t.app?.id ?? ""] ?? "code"
            run(cli, ["-r", cwd])
            return activateOwner(of: t)

        default:
            return false
        }
    }

    // MARK: - Multiplexers

    private static func focusTmux(pane: String, terminal: TerminalContext) {
        run("tmux", ["select-window", "-t", pane])
        run("tmux", ["select-pane", "-t", pane])

        // The pane may be in a session this client is not attached to.
        if let session = output("tmux", ["display-message", "-p", "-t", pane, "#{session_name}"]),
           !session.isEmpty {
            run("tmux", ["switch-client", "-t", session])
        }

        // The host terminal is not in the agent's parent chain when tmux is in
        // the way — the chain ends at the tmux server. Ask tmux which client is
        // attached and resolve the app from that process instead.
        if terminal.bundleID.isEmpty,
           let clientPID = output("tmux", ["list-clients", "-F", "#{client_pid}"])?
            .split(separator: "\n").first.flatMap({ pid_t($0) }),
           let app = ProcessTree.owningApp(of: clientPID) {
            activate(app)
        }
    }

    private static func focusScreen(session: String, window: String) {
        guard !window.isEmpty else { return }
        run("screen", ["-S", session, "-X", "select", window])
    }

    // MARK: - Activation

    @discardableResult
    private static func activateOwner(of t: TerminalContext) -> Bool {
        if let pid = pid_t(t.pid), let app = ProcessTree.owningApp(of: pid) {
            return activate(app)
        }
        if !t.bundleID.isEmpty, activate(bundleID: t.bundleID) { return true }
        for candidate in t.app?.bundleIDs ?? [] where activate(bundleID: candidate) {
            return true
        }
        return false
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateAllWindows])
    }

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first {
            return activate(running)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }

    // MARK: - Scripting

    private static func devPath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }

    private static func focusITerm(sessionID raw: String) -> Bool {
        // ITERM_SESSION_ID looks like "w0t2p0:8A1F-…-UUID"; the UUID is the id.
        let uuid = raw.contains(":") ? String(raw.split(separator: ":").last!) : raw
        return appleScript("""
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is "\(uuid)" then
                  select w
                  select t
                  select s
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "miss"
        """) == "ok"
    }

    private static func focusAppleTerminal(tty: String) -> Bool {
        appleScript("""
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if tty of t is "\(tty)" then
                  set selected tab of w to t
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end try
            end repeat
          end repeat
        end tell
        return "miss"
        """) == "ok"
    }

    @discardableResult
    private static func appleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Perch: AppleScript error \(error)")
            return nil
        }
        return result.stringValue
    }

    // MARK: - Shell

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> String? {
        output(tool, args)
    }

    /// Runs a CLI off the user's likely PATH. Missing tools fail silently — a
    /// terminal without its helper installed still gets activated by step 3.
    private static func output(_ tool: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args

        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          "/Applications/kitty.app/Contents/MacOS",
                          NSHomeDirectory() + "/.local/bin"]
        environment["PATH"] = ((environment["PATH"] ?? "").split(separator: ":").map(String.init)
                               + extraPaths).joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
