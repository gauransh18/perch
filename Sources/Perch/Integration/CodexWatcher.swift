import Foundation

/// Codex support.
///
/// Codex has no equivalent of Claude Code's `PreToolUse` hook — its only
/// callback (`notify` in config.toml) fires once a turn has already ended, which
/// is far too late to drive a live feed and useless for approvals. What it does
/// have is a rollout transcript per session, written as it goes:
///
///     ~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl
///
/// So Codex is watched rather than hooked. Each line is
/// `{type, timestamp, payload}`; the payloads we care about are:
///
///   session_meta                     cwd, session id, cli version
///   turn_context                     model, approval policy
///   event_msg/task_started|complete  turn boundaries -> session state
///   event_msg/token_count            cumulative usage -> cost
///   response_item/function_call      tool started    (call_id, name, arguments)
///   response_item/*_call_output      tool finished   (call_id, output)
///   event_msg/exec_command_end       exit code       -> ok / failed
///   event_msg/patch_apply_end        changed files   -> +/- lines
///
/// Reads are incremental — each pass seeks to where the last one stopped — for
/// the same reason `TranscriptStore` does: these files reach megabytes and
/// re-parsing one on every beat would dominate the app's CPU.
///
/// This yields presence, live tool feed, state and cost. It cannot yield
/// approvals; that is a limit of what Codex exposes, not an omission here.
@MainActor
final class CodexWatcher {
    private static let beat: TimeInterval = 2
    /// A rollout file untouched for this long is treated as a finished session.
    private static let liveWindow: TimeInterval = 20 * 60
    /// Only ever consider the newest few files, so an old ~/.codex does not turn
    /// every beat into a thousand-file stat sweep.
    private static let maxFiles = 12

    private let state: AppState
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.perch.codex", qos: .utility)
    private var readers: [String: Reader] = [:]   // file path -> parse cursor
    private var busy = false

    init(state: AppState) { self.state = state }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.beat, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        drop()
    }

    // MARK: Beat

    private func tick() {
        guard Prefs.watchCodex else {
            if state.sessions.contains(where: { $0.kind == .codex && !$0.isGhost }) { drop() }
            return
        }
        guard !busy else { return }          // a slow disk must not queue up passes
        busy = true

        let readers = self.readers
        queue.async { [weak self] in
            let files = Self.liveFiles()
            var next = readers
            var out: [Session] = []

            for path in files {
                let reader = next[path] ?? Reader()
                next[path] = reader
                reader.ingest(path: path)
                if let session = reader.session { out.append(session) }
            }
            // Forget cursors for files that dropped out of the window.
            next = next.filter { files.contains($0.key) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.readers = next
                self.apply(out)
                self.busy = false
            }
        }
    }

    /// Replaces the Codex slice of the session list in one assignment. Mutating
    /// per session re-rendered the notch once per Codex session per beat.
    private func apply(_ found: [Session]) {
        var next = state.sessions.filter { !($0.kind == .codex && !$0.isGhost) }

        for var session in found {
            // Carry over anything the user's selection depends on.
            if let existing = state.sessions.first(where: { $0.id == session.id }) {
                session.startedAt = existing.startedAt
            }
            next.append(session)
        }

        // A watched session supersedes the process-scan ghost for the same app.
        if !found.isEmpty {
            next.removeAll { $0.isGhost && $0.kind == .codex }
        }

        if next != state.sessions { state.sessions = next }
        if let sel = state.selected, !next.contains(where: { $0.id == sel }) { state.selected = nil }
    }

    private func drop() {
        let next = state.sessions.filter { !($0.kind == .codex && !$0.isGhost) }
        if next != state.sessions { state.sessions = next }
        readers = [:]
    }

    // MARK: Discovery

    /// Newest rollout files still inside the live window. Enumerates lazily and
    /// skips hidden files so a huge archive does not cost a full directory read.
    private static func liveFiles() -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: PerchPaths.codexSessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-liveWindow)
        var hits: [(String, Date)] = []

        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified > cutoff
            else { continue }
            hits.append((url.path, modified))
        }

        return hits.sorted { $0.1 > $1.1 }.prefix(maxFiles).map(\.0)
    }
}

// MARK: - Reader

/// One rollout file's parse cursor and the session it has built up. Lives on the
/// watcher's queue; never touched from the main actor.
private final class Reader {
    private var offset: UInt64 = 0
    private var partial = Data()

    private var sessionID = ""
    private var cwd = ""
    private var model = ""
    private var usage = Usage()
    private var activities: [ToolActivity] = []
    private var byCall: [String: Int] = [:]     // call_id -> index in activities
    private var sessionState: SessionState = .starting
    private var lastEvent = Date.distantPast
    private var lastPrompt: String?

    /// Keeps the feed bounded the way the notch renders it anyway.
    private static let activityCap = 120

    var session: Session? {
        guard !sessionID.isEmpty else { return nil }
        var s = Session(id: "codex:\(sessionID)", kind: .codex, cwd: cwd)
        s.state = sessionState
        s.activities = activities
        s.usage = usage.totalTokens > 0 ? usage : nil
        s.lastEventAt = lastEvent
        s.lastPrompt = lastPrompt
        // Codex runs as a desktop app, so there is no pane to jump back to.
        // Saying so is better than offering a button that cannot work.
        s.notice = "Watched — Codex has no approval hook"
        return s
    }

    func ingest(path: String) {
        guard let file = FileHandle(forReadingAtPath: path) else { return }
        defer { try? file.close() }

        // A rewritten or rotated file is shorter than where we left off.
        let size = (try? file.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data() }
        guard size > offset else { return }

        try? file.seek(toOffset: offset)
        guard let chunk = try? file.readToEnd(), !chunk.isEmpty else { return }
        offset = size

        var buffer = partial + chunk
        partial = Data()
        // Hold back a trailing fragment; the writer may be mid-line.
        if buffer.last != 0x0A, let cut = buffer.lastIndex(of: 0x0A) {
            partial = buffer[buffer.index(after: cut)...]
            buffer = buffer[..<cut]
        }

        for line in buffer.split(separator: 0x0A) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(envelope: obj)
        }

        if activities.count > Self.activityCap {
            let drop = activities.count - Self.activityCap
            activities.removeFirst(drop)
            byCall = byCall.compactMapValues { $0 >= drop ? $0 - drop : nil }
        }
    }

    // MARK: Line handling

    private func handle(envelope: [String: Any]) {
        guard let payload = envelope["payload"] as? [String: Any] else { return }
        let envelopeType = envelope["type"] as? String ?? ""
        if let stamp = envelope["timestamp"] as? String, let date = Self.date(stamp) { lastEvent = date }

        switch envelopeType {
        case "session_meta":
            sessionID = payload["session_id"] as? String ?? payload["id"] as? String ?? sessionID
            cwd = payload["cwd"] as? String ?? cwd
            if sessionState == .starting { sessionState = .idle }

        case "turn_context":
            model = payload["model"] as? String ?? model
            usage.model = model
            cwd = payload["cwd"] as? String ?? cwd

        case "event_msg":
            handleEvent(payload)

        case "response_item":
            handleResponseItem(payload)

        default:
            break
        }
    }

    private func handleEvent(_ p: [String: Any]) {
        switch p["type"] as? String {
        case "task_started":
            sessionState = .working

        case "task_complete":
            sessionState = .idle
            finishDangling()

        case "turn_aborted":
            sessionState = .idle
            finishDangling(as: .denied)

        case "error":
            sessionState = .failed
            finishDangling(as: .failed)

        case "user_message":
            if let text = p["message"] as? String, !text.isEmpty {
                lastPrompt = String(text.prefix(300))
            }

        case "token_count":
            // info is absent on some lines; only total_token_usage is cumulative.
            guard let info = p["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            let cachedIn = total["cached_input_tokens"] as? Int ?? 0
            // Codex reports cached tokens inside input_tokens; Perch bills the
            // two at different rates, so split them rather than double-count.
            usage.input = max(0, (total["input_tokens"] as? Int ?? 0) - cachedIn)
            usage.cacheRead = cachedIn
            usage.output = total["output_tokens"] as? Int ?? 0
            usage.cacheWrite = 0
            if usage.model.isEmpty { usage.model = model }

        case "exec_command_end":
            guard let id = p["call_id"] as? String else { return }
            let code = p["exit_code"] as? Int ?? 0
            close(callID: id, status: code == 0 ? .ok : .failed)

        case "patch_apply_end":
            guard let id = p["call_id"] as? String else { return }
            let ok = p["success"] as? Bool ?? true
            let (added, removed) = Self.patchCounts(p["changes"])
            close(callID: id, status: ok ? .ok : .failed, added: added, removed: removed)

        case "web_search_end", "mcp_tool_call_end", "view_image_tool_call":
            if let id = p["call_id"] as? String { close(callID: id, status: .ok) }

        default:
            break
        }
    }

    private func handleResponseItem(_ p: [String: Any]) {
        switch p["type"] as? String {
        case "function_call", "custom_tool_call":
            guard let id = p["call_id"] as? String else { return }
            let name = p["name"] as? String ?? "tool"
            let raw = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
            var activity = ToolActivity(tool: name, headline: Self.headline(tool: name, raw: raw))
            activity.status = .running
            byCall[id] = activities.count
            activities.append(activity)
            sessionState = .working

        case "function_call_output", "custom_tool_call_output":
            guard let id = p["call_id"] as? String else { return }
            // exec/patch carry richer end events; those set the real status.
            close(callID: id, status: .ok, onlyIfRunning: true)

        case "web_search_call", "tool_search_call":
            let name = p["type"] as? String == "web_search_call" ? "web_search" : "tool_search"
            var activity = ToolActivity(tool: name, headline: "")
            activity.status = .ok
            activity.endedAt = Date()
            activities.append(activity)

        default:
            break
        }
    }

    // MARK: Activity bookkeeping

    private func close(callID: String, status: ToolActivity.Status,
                       added: Int = 0, removed: Int = 0, onlyIfRunning: Bool = false) {
        guard let index = byCall[callID], activities.indices.contains(index) else { return }
        if onlyIfRunning && activities[index].status != .running { return }
        activities[index].status = status
        activities[index].endedAt = Date()
        if added > 0 { activities[index].added = added }
        if removed > 0 { activities[index].removed = removed }
    }

    /// A turn can end with tools still marked running — an abort, or an end
    /// event we never saw. Leaving them spinning forever reads as a hang.
    private func finishDangling(as status: ToolActivity.Status = .ok) {
        for index in activities.indices where activities[index].status == .running {
            activities[index].status = status
            activities[index].endedAt = Date()
        }
    }

    // MARK: Parsing helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }

    /// `changes` maps a file path to its diff stats. Shapes vary between Codex
    /// versions, so pull whatever integers are on offer and ignore the rest.
    static func patchCounts(_ changes: Any?) -> (Int, Int) {
        guard let map = changes as? [String: Any] else { return (0, 0) }
        var added = 0, removed = 0
        for value in map.values {
            guard let entry = value as? [String: Any] else { continue }
            added += entry["added"] as? Int ?? entry["added_lines"] as? Int ?? 0
            removed += entry["removed"] as? Int ?? entry["removed_lines"] as? Int ?? 0
        }
        return (added, removed)
    }

    /// One line describing the call. Codex passes arguments as a JSON string for
    /// most tools and a raw patch for `apply_patch`, so both are handled.
    static func headline(tool: String, raw: String) -> String {
        if tool == "apply_patch" || tool == "exec" {
            if let path = patchTarget(raw) { return path }
            return trim(raw)
        }

        guard let data = raw.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return trim(raw) }

        switch tool {
        case "exec_command":
            if let cmd = args["cmd"] as? String { return trim(cmd) }
            if let parts = args["cmd"] as? [String] { return trim(parts.joined(separator: " ")) }
        case "view_image":
            if let path = args["path"] as? String { return shorten(path) }
        case "js":
            if let title = args["title"] as? String, !title.isEmpty { return trim(title) }
            if let code = args["code"] as? String { return trim(code) }
        case "update_plan":
            if let why = args["explanation"] as? String, !why.isEmpty { return trim(why) }
            return "Updated the plan"
        case "write_stdin":
            if let chars = args["chars"] as? String { return trim(chars) }
        default:
            break
        }

        if let patch = args["patch"] as? String, let path = patchTarget(patch) { return path }
        return trim(raw)
    }

    /// `*** Update File: path` / `Add File:` / `Delete File:` inside a patch body.
    private static func patchTarget(_ patch: String) -> String? {
        for line in patch.split(separator: "\n").prefix(40) {
            guard line.hasPrefix("*** ") else { continue }
            for marker in ["Update File: ", "Add File: ", "Delete File: ", "Move File: "] {
                if let range = line.range(of: marker) {
                    return shorten(String(line[range.upperBound...]))
                }
            }
        }
        return nil
    }

    private static func shorten(_ path: String) -> String {
        let home = PerchPaths.home.path
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path.dropFirst(0)
        return String(short)
    }

    private static func trim(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }
}
