import Foundation

/// Thin typed wrapper over UserDefaults. Everything is local; nothing leaves the machine.
enum Prefs {
    private static let d = UserDefaults.standard

    enum Key {
        static let approvalMode = "approvalMode"
        static let autoAllowReadOnly = "autoAllowReadOnly"
        static let sounds = "sounds"
        static let alwaysShow = "alwaysShow"
        static let autoInstallHooks = "autoInstallHooks"
        static let scanProcesses = "scanProcesses"
        static let idleHideSeconds = "idleHideSeconds"
        static let trackCost = "trackCost"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.approvalMode: false,
            Key.autoAllowReadOnly: true,
            Key.sounds: true,
            Key.alwaysShow: false,
            Key.autoInstallHooks: true,
            Key.scanProcesses: true,
            Key.idleHideSeconds: 90.0,
            Key.trackCost: true,
        ])
    }

    /// When on, Perch answers Claude Code's PreToolUse hook with allow/deny.
    /// When off (default) Perch only observes and never influences permissions.
    static var approvalMode: Bool {
        get { d.bool(forKey: Key.approvalMode) }
        set { d.set(newValue, forKey: Key.approvalMode) }
    }

    static var autoAllowReadOnly: Bool {
        get { d.bool(forKey: Key.autoAllowReadOnly) }
        set { d.set(newValue, forKey: Key.autoAllowReadOnly) }
    }

    static var sounds: Bool {
        get { d.bool(forKey: Key.sounds) }
        set { d.set(newValue, forKey: Key.sounds) }
    }

    static var alwaysShow: Bool {
        get { d.bool(forKey: Key.alwaysShow) }
        set { d.set(newValue, forKey: Key.alwaysShow) }
    }

    static var autoInstallHooks: Bool {
        get { d.bool(forKey: Key.autoInstallHooks) }
        set { d.set(newValue, forKey: Key.autoInstallHooks) }
    }

    static var scanProcesses: Bool {
        get { d.bool(forKey: Key.scanProcesses) }
        set { d.set(newValue, forKey: Key.scanProcesses) }
    }

    static var trackCost: Bool {
        get { d.bool(forKey: Key.trackCost) }
        set { d.set(newValue, forKey: Key.trackCost) }
    }

    static var idleHideSeconds: TimeInterval {
        get { d.double(forKey: Key.idleHideSeconds) }
        set { d.set(newValue, forKey: Key.idleHideSeconds) }
    }
}
