import AppKit
import ApplicationServices

/// ⌘Y / ⌘N have to work while the user is still typing in their editor, so the
/// panel never takes focus. Reading keys from another app needs Accessibility,
/// which we ask for only when the user turns approvals on.
@MainActor
final class HotkeyMonitor {
    private let state: AppState
    private var monitor: Any?
    private var localMonitor: Any?

    init(state: AppState) { self.state = state }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        stop()
        // Local monitor works whenever the panel itself is key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.consume(event) ? nil : event
        }
        guard Self.isTrusted else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.consume(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard state.activeApproval != nil,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else { return false }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "y":
            state.resolveActive(.allow)
            SoundEngine.shared.play(.allow)
            return true
        case "n":
            state.resolveActive(.deny)
            SoundEngine.shared.play(.deny)
            return true
        default:
            return false
        }
    }
}
