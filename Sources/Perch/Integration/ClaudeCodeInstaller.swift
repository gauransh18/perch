import Foundation

/// Wires ~/.claude/settings.json up to the Perch hook shim. Idempotent, backs
/// up before writing, and removes only entries it recognises as its own.
enum ClaudeCodeInstaller {

    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SubagentStop", "PreCompact", "SessionEnd",
    ]

    private static let marker = ".perch/hook.sh"

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isInstalled: Bool {
        guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
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

        for event in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups = strip(groups)
            let entry: [String: Any] = [
                "type": "command",
                "command": "\"$HOME/.perch/hook.sh\" \(event)",
                "timeout": event == "PreToolUse" ? 300 : 10,
            ]
            var group: [String: Any] = ["hooks": [entry]]
            if event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = strip(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeSettings(settings)
    }

    // MARK: private

    /// Removes Perch entries, and any hook group left empty as a result.
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
        guard let data = try? Data(contentsOf: PerchPaths.claudeSettings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PerchPaths.claudeDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: PerchPaths.claudeSettings.path) {
            let backup = PerchPaths.claudeDir
                .appendingPathComponent("settings.json.perch-backup")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: PerchPaths.claudeSettings, to: backup)
        }

        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: PerchPaths.claudeSettings, options: .atomic)
    }
}
