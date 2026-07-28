import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowController {
    static private(set) var shared: NotchWindowController?

    private let state: AppState
    private var panel: NotchPanel!
    private var geometry: NotchGeometry
    private var bag = Set<AnyCancellable>()
    private var shrinkWork: DispatchWorkItem?

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
        panel.contentView = host
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
        (panel.contentView as? NSHostingView<NotchRootView>)?.rootView =
            NotchRootView(state: state, geometry: geometry)
        layout(force: true)
    }

    /// Bring the panel up as key so ⌘Y / ⌘N reach the approval card without
    /// stealing focus from the editor the user is typing in.
    func focusForApproval() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func layout(force: Bool = false) {
        let size = state.desiredSize(notch: geometry)
        let origin = CGPoint(x: geometry.notchRect.midX - size.width / 2,
                             y: geometry.screenFrame.maxY - size.height)
        let target = CGRect(origin: origin, size: size).integral
        guard force || target != panel.frame else { return }

        shrinkWork?.cancel()

        let grows = target.width > panel.frame.width || target.height > panel.frame.height
        if grows || force {
            panel.setFrame(target, display: true)
            panel.contentView?.needsDisplay = true
        } else {
            // Let the SwiftUI spring finish before clipping the window down.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let now = self.state.desiredSize(notch: self.geometry)
                let o = CGPoint(x: self.geometry.notchRect.midX - now.width / 2,
                                y: self.geometry.screenFrame.maxY - now.height)
                self.panel.setFrame(CGRect(origin: o, size: now).integral, display: true)
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
