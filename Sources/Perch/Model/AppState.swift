import Foundation
import SwiftUI

enum Presentation: Equatable { case hidden, collapsed, expanded, approval }

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var hovering = false
    @Published var pinned = false
    @Published var selected: String?
    @Published var hooksInstalled = false
    @Published var serverPort: UInt16 = 0

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
        if activeApproval != nil { return .approval }
        if hovering || pinned { return .expanded }
        if sessions.isEmpty && !Prefs.alwaysShow { return .hidden }
        return .collapsed
    }

    var totalCost: Double {
        sessions.compactMap { $0.usage?.cost }.reduce(0, +)
    }

    // MARK: window sizing

    func desiredSize(notch: NotchGeometry) -> CGSize {
        let nw = notch.notchRect.width
        let nh = notch.notchRect.height
        switch presentation {
        case .hidden:
            return CGSize(width: nw + 80, height: nh)
        case .collapsed:
            return CGSize(width: nw + 236, height: nh + 4)
        case .expanded:
            let rows = min(max(visibleSessions.count, 1), 5)
            let detail = selected != nil ? 190.0 : 0.0
            return CGSize(width: max(nw + 380, 660), height: nh + 46 + Double(rows) * 58 + detail + 34)
        case .approval:
            return CGSize(width: max(nw + 380, 660), height: nh + 430)
        }
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

    func resolveActive(_ decision: ApprovalRequest.Decision) {
        guard !approvals.isEmpty else { return }
        let req = approvals.removeFirst()
        req.resolve(decision)
    }

    func clearFinished() {
        sessions.removeAll { $0.state == .done || $0.state == .failed || $0.isGhost }
    }

    /// Drop sessions that stopped reporting long ago so the notch stays honest.
    private func reap() {
        let cutoff = Prefs.idleHideSeconds
        let now = Date()
        sessions.removeAll { s in
            guard !s.state.isBusy, s.state != .waiting else { return false }
            return now.timeIntervalSince(s.lastEventAt) > cutoff
        }
        // Expire stale approvals (the hook has its own timeout too).
        while let first = approvals.first, now.timeIntervalSince(first.createdAt) > 240 {
            approvals.removeFirst()
            first.resolve(.passthrough)
        }
        objectWillChange.send()
    }
}
