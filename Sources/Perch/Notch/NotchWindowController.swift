import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI tree and owns hover tracking.
///
/// SwiftUI's `.onHover` installs a tracking area scoped to the active app, so
/// the island only opened while Perch itself was frontmost — which is never,
/// in normal use. An `.activeAlways` area delivers enter/exit regardless of
/// which app the user is working in.
final class HoverContainer: NSView {
    /// Called when the pointer might have arrived. Leaving is decided by the
    /// controller polling the real pointer position, because resizing the panel
    /// tears down and rebuilds the tracking area and that emits a spurious exit
    /// while the cursor is still inside — which collapsed the island the
    /// instant it opened.
    var onPointerActivity: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
    override func mouseExited(with event: NSEvent) { onPointerActivity?() }
}

@MainActor
final class NotchWindowController {
    static private(set) var shared: NotchWindowController?

    private let state: AppState
    private var panel: NotchPanel!
    private var hostingView: NSHostingView<NotchRootView>!
    private var geometry: NotchGeometry
    private var bag = Set<AnyCancellable>()
    private var shrinkWork: DispatchWorkItem?
    private var hoverPoll: Timer?

    init(state: AppState) {
        self.state = state
        self.geometry = NotchGeometry.current()
        build()
        NotchWindowController.shared = self

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.layout() }
            .store(in: &bag)
    }

    private func build() {
        let panel = NotchPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none

        // Concrete type, not AnyView: AnyView erases the view tree's identity
        // and forces SwiftUI to re-diff the whole island on every update.
        let host = NSHostingView(rootView: NotchRootView(state: state, geometry: geometry))
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverContainer()
        container.wantsLayer = true
        container.onPointerActivity = { [weak self] in self?.syncHover() }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.contentView = container
        self.hostingView = host
        self.panel = panel
        layout(force: true)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func refreshGeometry() {
        let next = NotchGeometry.current()
        guard next != geometry else { return }
        geometry = next
        hostingView.rootView = NotchRootView(state: state, geometry: geometry)
        layout(force: true)
    }

    /// Single source of truth for hover: is the pointer inside the panel right
    /// now? While it is, poll — the panel resizes underneath the cursor and no
    /// enter/exit event describes that reliably.
    private func syncHover() {
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if state.hovering != inside {
            state.hovering = inside
            if !inside { state.selected = nil }
        }
        if inside {
            if hoverPoll == nil {
                hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.syncHover() }
                }
            }
        } else {
            hoverPoll?.invalidate()
            hoverPoll = nil
        }
    }

    /// Surface the card without taking the keyboard. `makeKey()` here pulled
    /// focus out of whatever the user was typing in, which is both rude and
    /// dangerous: their next Return landed on this panel's buttons. ⌘Y / ⌘N
    /// come from the global hotkey monitor instead, and clicking the feedback
    /// field makes the panel key on its own.
    func focusForApproval() {
        panel.orderFrontRegardless()
    }

    private func frame(for size: CGSize) -> CGRect {
        let origin = CGPoint(x: geometry.notchRect.midX - size.width / 2,
                             y: geometry.screenFrame.maxY - size.height - state.topOffset(notch: geometry))
        return CGRect(origin: origin, size: size).integral
    }

    private func layout(force: Bool = false) {
        let size = state.desiredSize(notch: geometry)
        let target = frame(for: size)
        guard force || target != panel.frame else { return }

        shrinkWork?.cancel()

        let grows = target.width > panel.frame.width || target.height > panel.frame.height
        if grows || force {
            panel.setFrame(target, display: true)
            panel.contentView?.needsDisplay = true
            // The frame moved under the pointer; re-check rather than wait for
            // an event that may never come.
            syncHover()
        } else {
            // Let the SwiftUI spring finish before clipping the window down.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let now = self.state.desiredSize(notch: self.geometry)
                self.panel.setFrame(self.frame(for: now), display: true)
                self.panel.contentView?.needsDisplay = true
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
        }

        // Note: don't try to hand key status back here. `resignKey()` is a
        // notification callback, not a setter, and calling it left the panel
        // believing it was still key.
    }
}
