import Foundation

/// Coverage net for agents that have no hook integration. Polls `ps` for known
/// agent binaries and surfaces them as read-only "ghost" rows so the notch shows
/// everything that is running, not just what talks to us.
@MainActor
final class ProcessScanner {
    private let state: AppState
    private var timer: Timer?
    private var cwdCache: [Int32: String] = [:]

    init(state: AppState) { self.state = state }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard Prefs.scanProcesses else {
            state.sessions.removeAll { $0.isGhost }
            return
        }

        let found = Self.scan()
        let liveIDs = Set(found.map { "pid:\($0.pid)" })

        // Retire ghosts whose process disappeared.
        state.sessions.removeAll { $0.isGhost && !liveIDs.contains($0.id) }

        for proc in found {
            // If a hook-backed session already covers this cwd + kind, skip it.
            let cwd = cwd(for: proc.pid)
            let covered = state.sessions.contains {
                !$0.isGhost && $0.kind == proc.kind && (!cwd.isEmpty && $0.cwd == cwd)
            }
            let id = "pid:\(proc.pid)"
            if covered {
                state.remove(id)
                continue
            }
            if let i = state.sessions.firstIndex(where: { $0.id == id }) {
                state.sessions[i].lastEventAt = Date()
                continue
            }
            var s = Session(id: id, kind: proc.kind, cwd: cwd)
            s.isGhost = true
            s.pid = proc.pid
            s.state = .working
            s.terminal.tty = proc.tty
            s.notice = "Detected — no hook integration"
            state.sessions.append(s)
        }
    }

    private func cwd(for pid: Int32) -> String {
        if let c = cwdCache[pid] { return c }
        let out = Self.shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) ?? ""
        let path = out.split(separator: "\n").first(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) } ?? ""
        cwdCache[pid] = path
        if cwdCache.count > 200 { cwdCache.removeAll() }
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
