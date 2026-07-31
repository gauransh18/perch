import Foundation

enum PerchPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".perch", isDirectory: true)

    static let portFile = root.appendingPathComponent("port")
    static let tokenFile = root.appendingPathComponent("token")
    static let hookScript = root.appendingPathComponent("hook.sh")
    static let pricingFile = root.appendingPathComponent("pricing.json")

    static let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
    static let claudeSettings = claudeDir.appendingPathComponent("settings.json")

    static let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    static let codexSessions = codexDir.appendingPathComponent("sessions", isDirectory: true)

    static func ensureRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}
