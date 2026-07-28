import Foundation

/// Coverage net for agents that have no hook integration. Polls `ps` for known
/// agent binaries and surfaces them as read-only "ghost" rows so the notch shows
/// everything that is running, not just what talks to us.
@MainActor
final class ProcessScanner {
    private static let beat: TimeInterval = 6
    /// When nothing has been found for a while, only scan every Nth beat. `ps`
    /// and `lsof` are process spawns; running them forever on an idle Mac is
    /// pure waste.
    private static let idleSkip = 4

    private let state: AppState
    private var timer: Timer?
    private var cwdCache: [Int32: String] = [:]
    private var skipped = 0
    private var quiet = false

    init(state: AppState) { self.state = state }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.beat, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard Prefs.scanProcesses else {
            if state.sessions.contains(where: { $0.isGhost }) {
                state.sessions.removeAll { $0.isGhost }
            }
            return
        }

        if quiet {
            skipped += 1
            guard skipped >= Self.idleSkip else { return }
        }
        skipped = 0

        let found = Self.scan()
        quiet = found.isEmpty
        cwdCache = cwdCache.filter { pid, _ in found.contains { $0.pid == pid } }

        // Build the whole next list, then assign once: mutating the published
        // array per process fired a re-render for every agent on the machine.
        var next = state.sessions.filter { !$0.isGhost }
        let now = Date()

        for proc in found {
            let cwd = cwd(for: proc.pid)
            // A hook-backed session already covers this project; no ghost needed.
            if next.contains(where: { $0.kind == proc.kind && !cwd.isEmpty && $0.cwd == cwd }) { continue }

            let id = "pid:\(proc.pid)"
            if var existing = state.sessions.first(where: { $0.id == id }) {
                existing.lastEventAt = now
                next.append(existing)
                continue
            }
            var s = Session(id: id, kind: proc.kind, cwd: cwd)
            s.isGhost = true
            s.pid = proc.pid
            s.state = .working
            s.terminal.tty = proc.tty
            s.notice = "Detected — no hook integration"
            next.append(s)
        }

        if next != state.sessions { state.sessions = next }
        if let sel = state.selected, !next.contains(where: { $0.id == sel }) { state.selected = nil }
    }

    private func cwd(for pid: Int32) -> String {
        if let c = cwdCache[pid] { return c }
        let out = Self.shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) ?? ""
        let path = out.split(separator: "\n").first(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) } ?? ""
        cwdCache[pid] = path
        return path
    }

    // MARK: ps

    struct Found { var pid: Int32; var kind: AgentKind; var tty: String }

    private static func scan() -> [Found] {
        guard let out = shell("/bin/ps", ["-axo", "pid=,tty=,comm="]) else { return [] }
        var result: [Found] = []
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]) else { continue }
            let tty = String(fields[1])
            let comm = fields[2...].joined(separator: " ")
            guard let kind = AgentKind.fromCommand(comm) else { continue }
            guard tty != "??" else { continue }   // ignore daemons / GUI helpers
            result.append(Found(pid: pid, kind: kind, tty: tty))
        }
        return result
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
