import Foundation
import SwiftUI

enum Presentation: Equatable { case hidden, collapsed, expanded, approval, plan }

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var hovering = false
    @Published var pinned = false
    @Published var selected: String?
    @Published var hooksInstalled = false
    @Published var serverPort: UInt16 = 0

    /// Mirrors Prefs so the notch actually re-renders when it is toggled.
    @Published var approvalMode: Bool = Prefs.approvalMode {
        didSet { Prefs.approvalMode = approvalMode }
    }

    @Published var style: NotchStyle = Prefs.notchStyle {
        didSet { Prefs.notchStyle = style }
    }

    private var reaper: Timer?

    init() {
        reaper = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reap() }
        }
    }

    // MARK: derived

    var activeApproval: ApprovalRequest? { approvals.first }

    var visibleSessions: [Session] {
        sessions.sorted { a, b in
            if a.state.isBusy != b.state.isBusy { return a.state.isBusy }
            if (a.state == .waiting) != (b.state == .waiting) { return a.state == .waiting }
            return a.lastEventAt > b.lastEventAt
        }
    }

    var busyCount: Int { sessions.filter { $0.state.isBusy }.count }
    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }

    var headline: SessionState {
        if waitingCount > 0 { return .waiting }
        if busyCount > 0 { return .working }
        if sessions.contains(where: { $0.state == .failed }) { return .failed }
        return sessions.isEmpty ? .idle : .done
    }

    var presentation: Presentation {
        if let active = activeApproval { return active.kind == .plan ? .plan : .approval }
        if hovering || pinned { return .expanded }
        if sessions.isEmpty && !Prefs.alwaysShow { return .hidden }
        return .collapsed
    }

    var totalCost: Double {
        sessions.compactMap { $0.usage?.cost }.reduce(0, +)
    }

    // MARK: window sizing

    /// Gap kept between the head bar and the first divider when the panel is
    /// open. Without it the divider lands exactly on the notch's bottom edge
    /// and the hardware clips it.
    static let headClearance: CGFloat = 12

    func desiredSize(notch: NotchGeometry) -> CGSize {
        // Floating has no hole to leave in the middle of its head bar.
        let nw = style.mergesWithNotch ? notch.notchRect.width : 0
        let nh = notch.notchRect.height
        let clearance = Self.headClearance

        switch presentation {
        case .hidden:
            return CGSize(width: nw + 80, height: nh)
        case .collapsed:
            let flanks: CGFloat = style == .compact ? 116 : 236
            return CGSize(width: nw + flanks, height: nh + 4)
        case .expanded:
            let rows = min(max(visibleSessions.count, 1), 5)
            let detail = selected != nil ? 190.0 : 0.0
            return CGSize(width: max(nw + 420, 700),
                          height: nh + clearance + 46 + Double(rows) * 58 + detail + 34)
        case .approval:
            return CGSize(width: max(nw + 420, 700), height: nh + clearance + 430)
        case .plan:
            // Plans are prose. Give them room, but stay clear of the Dock.
            let cap = (notch.screenFrame.height * 0.72) - nh - clearance
            return CGSize(width: max(nw + 480, 760), height: nh + clearance + min(560, cap))
        }
    }

    /// Distance from the top of the screen down to the top of the island.
    func topOffset(notch: NotchGeometry) -> CGFloat {
        style.topGap(menuBarHeight: notch.notchRect.height)
    }

    // MARK: mutation

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    @discardableResult
    func upsert(id: String, kind: AgentKind, cwd: String, terminal: TerminalContext) -> Int {
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            if !cwd.isEmpty { sessions[i].cwd = cwd }
            if !terminal.isEmpty { sessions[i].terminal = terminal }
            sessions[i].lastEventAt = Date()
            sessions[i].isGhost = false
            return i
        }
        var s = Session(id: id, kind: kind, cwd: cwd)
        s.terminal = terminal
        sessions.append(s)
        return sessions.count - 1
    }

    func mutate(_ id: String, _ body: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[i])
        sessions[i].lastEventAt = Date()
    }

    func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        if selected == id { selected = nil }
    }

    func enqueue(_ req: ApprovalRequest) {
        approvals.append(req)
    }

    /// Two-step guard for ⌘Y, mirroring `ConfirmButton`. Returns true once the
    /// shortcut has been pressed twice inside the window; the first press only
    /// arms. Keeps a single stray key event from approving anything.
    private var approvalArmedAt: Date?

    func armApproval(window: TimeInterval = 4) -> Bool {
        let now = Date()
        if let armed = approvalArmedAt, now.timeIntervalSince(armed) <= window {
            approvalArmedAt = nil
            return true
        }
        approvalArmedAt = now
        return false
    }

    func resolveActive(_ decision: ApprovalRequest.Decision) {
        approvalArmedAt = nil
        guard !approvals.isEmpty else { return }
        let req = approvals.removeFirst()
        req.resolve(decision)
    }

    func clearFinished() {
        sessions.removeAll { $0.state == .done || $0.state == .failed || $0.isGhost }
    }

    /// Drop sessions that stopped reporting long ago so the notch stays honest.
    /// Only publishes when something actually changed — an unconditional
    /// `objectWillChange` here re-rendered the whole island every 5s while idle.
    private func reap() {
        let cutoff = Prefs.idleHideSeconds
        let now = Date()

        let before = sessions.count
        sessions.removeAll { s in
            guard !s.state.isBusy, s.state != .waiting else { return false }
            return now.timeIntervalSince(s.lastEventAt) > cutoff
        }
        if sessions.count != before, let sel = selected, session(sel) == nil { selected = nil }

        // Expire stale approvals (the hook has its own timeout too).
        while let first = approvals.first, now.timeIntervalSince(first.createdAt) > first.expiry {
            approvals.removeFirst()
            first.resolve(.passthrough)
        }
    }
}
