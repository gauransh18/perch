import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    let state = AppState()
    private var notch: NotchWindowController!
    private var server: HookServer!
    private var scanner: ProcessScanner!
    private var codex: CodexWatcher!
    private var statusItem: NSStatusItem!
    private(set) var hotkeys: HotkeyMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.registerDefaults()
        PerchPaths.ensureRoot()

        notch = NotchWindowController(state: state)
        notch.show()

        server = HookServer(state: state)
        do {
            try server.start()
        } catch {
            NSLog("Perch: failed to start hook server — \(error)")
        }

        if Prefs.autoInstallHooks && !ClaudeCodeInstaller.isInstalled {
            try? ClaudeCodeInstaller.install()
        }
        refreshInstallState()

        scanner = ProcessScanner(state: state)
        scanner.start()

        codex = CodexWatcher(state: state)
        codex.start()

        hotkeys = HotkeyMonitor(state: state)
        hotkeys.start()

        buildStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    func refreshInstallState() {
        state.hooksInstalled = ClaudeCodeInstaller.isInstalled
        rebuildMenu()
    }

    @objc private func screensChanged() {
        notch.refreshGeometry()
    }

    // MARK: menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Perch")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()

        let status = NSMenuItem(
            title: state.hooksInstalled ? "Hooks installed" : "Hooks not installed",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let port = NSMenuItem(title: "Listening on 127.0.0.1:\(state.serverPort)",
                              action: nil, keyEquivalent: "")
        port.isEnabled = false
        menu.addItem(port)
        menu.addItem(.separator())

        let approval = NSMenuItem(title: "Approve from notch",
                                  action: #selector(toggleApproval), keyEquivalent: "")
        approval.target = self
        approval.state = state.approvalMode ? .on : .off
        menu.addItem(approval)

        let pin = NSMenuItem(title: "Keep panel open", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = state.pinned ? .on : .off
        menu.addItem(pin)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Perch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleApproval() {
        state.approvalMode.toggle()
        hotkeys.start()
        rebuildMenu()
    }

    @objc private func togglePin() {
        state.pinned.toggle()
        rebuildMenu()
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
