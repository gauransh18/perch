import Foundation

/// Gemini CLI support.
///
/// Unlike Codex, Gemini CLI has a real hook system with a `BeforeTool` event
/// that can return `decision: "deny"` — so it gets the full treatment, approvals
/// included, rather than being watched from a transcript.
///
/// Its vocabulary differs from Claude Code's in three places: event names, tool
/// names, and a couple of argument keys. All three are normalised here at the
/// edge so `HookRouter`, `ToolSummary`, the glyph table and the approval flow
/// stay one pipeline rather than growing a parallel one per agent.
///
/// Contract: https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md
enum GeminiCLI {

    // MARK: Events

    /// Gemini event -> the canonical name `HookRouter` already switches on.
    /// `BeforeModel`, `AfterModel` and `BeforeToolSelection` are deliberately
    /// not subscribed: they fire per model request (and `AfterModel` per
    /// streamed chunk), which would be a hook process per chunk for no gain.
    static let eventMap: [String: String] = [
        "SessionStart": "SessionStart",
        "BeforeAgent": "UserPromptSubmit",
        "BeforeTool": "PreToolUse",
        "AfterTool": "PostToolUse",
        "AfterAgent": "Stop",
        "Notification": "Notification",
        "SessionEnd": "SessionEnd",
        "PreCompress": "PreCompact",
    ]

    static func canonicalEvent(_ event: String) -> String? { eventMap[event] }

    /// Only these two are tool-scoped and so need a matcher.
    static let toolEvents: Set<String> = ["BeforeTool", "AfterTool"]

    // MARK: Tools

    /// Gemini tool -> Claude Code's name for the same thing. Keeping one
    /// vocabulary means `ToolSummary`, `readOnly` auto-allow and the glyph table
    /// need no per-agent branches.
    static let toolMap: [String: String] = [
        "read_file": "Read",
        "read_many_files": "Read",
        "write_file": "Write",
        "replace": "Edit",
        "edit": "Edit",
        "run_shell_command": "Bash",
        "shell": "Bash",
        "glob": "Glob",
        "search_file_content": "Grep",
        "grep": "Grep",
        "list_directory": "LS",
        "ls": "LS",
        "web_fetch": "WebFetch",
        "google_web_search": "WebSearch",
        "save_memory": "TodoWrite",
    ]

    static func canonicalTool(_ tool: String) -> String {
        if let mapped = toolMap[tool] { return mapped }
        // MCP tools arrive as mcp_<server>_<tool>; leave them recognisable.
        return tool
    }

    /// Argument keys that mean the same thing under a different name.
    /// Everything else already lines up — Gemini's `replace` carries
    /// `old_string`/`new_string` and `run_shell_command` carries `command`,
    /// exactly as `ToolSummary` expects.
    static func canonicalInput(tool: String, _ input: [String: Any]) -> [String: Any] {
        var out = input
        if out["file_path"] == nil {
            for alias in ["absolute_path", "path", "file"] {
                if let value = out[alias] as? String { out["file_path"] = value; break }
            }
        }
        if tool == "Grep", out["glob"] == nil, let include = out["include"] as? String {
            out["glob"] = include
        }
        if tool == "WebSearch", out["query"] == nil, let prompt = out["prompt"] as? String {
            out["query"] = prompt
        }
        return out
    }

    /// Gemini expects a flat `{decision, reason}` on stdout, where Claude Code
    /// expects the nested `hookSpecificOutput` shape.
    static func decisionJSON(allow: Bool, reason: String) -> String {
        let obj: [String: Any] = ["decision": allow ? "allow" : "deny", "reason": reason]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Installer

/// Wires ~/.gemini/settings.json to the Perch hook shim. Same contract as
/// `ClaudeCodeInstaller`: idempotent, backs up before writing, and removes only
/// entries it recognises as its own.
enum GeminiCLIInstaller {

    private static let marker = ".perch/hook.sh"

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isInstalled: Bool {
        guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
        return GeminiCLI.eventMap.keys.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String ?? "").contains(marker)
                }
            }
        }
    }

    static func install() throws {
        HookScript.write(port: 0)
        guard FileManager.default.fileExists(atPath: PerchPaths.hookScript.path) else {
            throw InstallError(message: "Could not write \(PerchPaths.hookScript.path)")
        }

        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in GeminiCLI.eventMap.keys.sorted() {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups = strip(groups)
            let entry: [String: Any] = [
                "type": "command",
                "name": "perch",
                // The shim's second argument tells Perch which agent is calling,
                // so one script serves every agent.
                "command": "\"$HOME/.perch/hook.sh\" \(event) gemini",
                // Gemini measures this in milliseconds; Claude Code uses seconds.
                "timeout": event == "BeforeTool" ? 300_000 : 10_000,
            ]
            var group: [String: Any] = ["hooks": [entry]]
            // Gemini matchers are regular expressions, so ".*" rather than "*".
            if GeminiCLI.toolEvents.contains(event) { group["matcher"] = ".*" }
            groups.append(group)
            hooks[event] = groups
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in GeminiCLI.eventMap.keys {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = strip(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeSettings(settings)
    }

    /// True only when Gemini CLI itself looks installed.
    ///
    /// Deliberately does not accept "~/.gemini exists" as proof: Antigravity and
    /// other Google tools share that directory, so the bare folder says nothing
    /// about the CLI. Writing a settings.json on that evidence would leave a
    /// config file behind for a tool the user never installed.
    static var isPresent: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: PerchPaths.geminiSettings.path) { return true }

        let candidates = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map { String($0) + "/gemini" }
        return candidates.contains { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: private

    private static func strip(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            guard var entries = group["hooks"] as? [[String: Any]] else { return group }
            entries.removeAll { ($0["command"] as? String ?? "").contains(marker) }
            if entries.isEmpty { return nil }
            var g = group
            g["hooks"] = entries
            return g
        }
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: PerchPaths.geminiSettings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PerchPaths.geminiDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: PerchPaths.geminiSettings.path) {
            let backup = PerchPaths.geminiDir.appendingPathComponent("settings.json.perch-backup")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: PerchPaths.geminiSettings, to: backup)
        }

        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: PerchPaths.geminiSettings, options: .atomic)
    }
}
