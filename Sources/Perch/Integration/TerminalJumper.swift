import AppKit
import Foundation

/// Brings the exact terminal tab / split / tmux pane an agent is running in back
/// to the front. Falls back to activating the app, then to opening the folder.
enum TerminalJumper {

    static func jump(to session: Session) {
        let t = session.terminal

        if !t.tmuxPane.isEmpty {
            tmuxSelect(pane: t.tmuxPane)
        }

        switch t.program {
        case "iTerm.app":
            if !t.itermSession.isEmpty, jumpITerm(sessionID: t.itermSession) { return }
            activate(bundleID: "com.googlecode.iterm2"); return

        case "Apple_Terminal":
            if !t.tty.isEmpty, jumpAppleTerminal(tty: devPath(t.tty)) { return }
            activate(bundleID: "com.apple.Terminal"); return

        case "WezTerm":
            if !t.weztermPane.isEmpty {
                run("/usr/bin/env", ["wezterm", "cli", "activate-pane", "--pane-id", t.weztermPane])
            }
            activate(bundleID: "com.github.wez.wezterm"); return

        case "ghostty":
            activate(bundleID: "com.mitchellh.ghostty"); return

        case "vscode":
            if !activate(bundleID: "com.microsoft.VSCode") {
                activate(bundleID: "com.todesktop.230313mzl4w4u92")   // Cursor
            }
            return

        case "Warp":
            activate(bundleID: "dev.warp.Warp-Stable"); return

        case "Hyper":
            activate(bundleID: "co.zeit.hyper"); return

        case "Alacritty":
            activate(bundleID: "org.alacritty"); return

        default:
            break
        }

        if !t.kittyWindow.isEmpty {
            run("/usr/bin/env", ["kitty", "@", "focus-window", "--match", "id:\(t.kittyWindow)"])
            activate(bundleID: "net.kovidgoyal.kitty")
            return
        }

        // Unknown terminal: try to match the tty across the two scriptable ones,
        // otherwise just reveal the project so the jump is never a dead end.
        if !t.tty.isEmpty, jumpAppleTerminal(tty: devPath(t.tty)) { return }
        if !session.cwd.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
        }
    }

    // MARK: helpers

    private static func devPath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        return true
    }

    private static func tmuxSelect(pane: String) {
        run("/usr/bin/env", ["tmux", "select-window", "-t", pane])
        run("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
    }

    private static func jumpITerm(sessionID raw: String) -> Bool {
        // ITERM_SESSION_ID looks like "w0t2p0:8A1F-…-UUID"; the UUID is the session id.
        let uuid = raw.contains(":") ? String(raw.split(separator: ":").last!) : raw
        let script = """
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
        """
        return appleScript(script) == "ok"
    }

    private static func jumpAppleTerminal(tty: String) -> Bool {
        let script = """
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
        """
        return appleScript(script) == "ok"
    }

    @discardableResult
    private static func appleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error { NSLog("Perch: AppleScript error \(error)") ; return nil }
        return result.stringValue
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
