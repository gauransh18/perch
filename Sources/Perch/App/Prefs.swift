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
        static let watchCodex = "watchCodex"
        static let idleHideSeconds = "idleHideSeconds"
        static let trackCost = "trackCost"
        static let notchStyle = "notchStyle"
        static let planReview = "planReview"
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
            Key.planReview: true,
            // notchStyle is deliberately absent: with no stored value the
            // getter picks a default from the hardware.
        ])
    }

    /// Defaults to floating on a Mac with no notch, where there is nothing to
    /// merge with and a flush island just looks like a stuck menu bar.
    static var notchStyle: NotchStyle {
        get {
            if let raw = d.string(forKey: Key.notchStyle), let s = NotchStyle(rawValue: raw) {
                return s
            }
            return NotchGeometry.current().hasNotch ? .notch : .floating
        }
        set { d.set(newValue.rawValue, forKey: Key.notchStyle) }
    }

    /// When on, Perch answers Claude Code's PreToolUse hook with allow/deny.
    /// When off (default) Perch only observes and never influences permissions.
    static var approvalMode: Bool {
        get { d.bool(forKey: Key.approvalMode) }
        set { d.set(newValue, forKey: Key.approvalMode) }
    }

    /// Intercept ExitPlanMode and review the plan in the notch. Separate from
    /// `approvalMode` because it replaces a prompt the agent already shows,
    /// rather than pre-empting the user's own permission rules.
    static var planReview: Bool {
        get { d.bool(forKey: Key.planReview) }
        set { d.set(newValue, forKey: Key.planReview) }
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

    static var watchCodex: Bool {
        // Defaults on: unlike hooks, watching costs nothing until Codex runs.
        get { d.object(forKey: Key.watchCodex) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.watchCodex) }
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
