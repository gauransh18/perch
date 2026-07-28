import Foundation
import Network

// MARK: - Minimal HTTP/1.1 request

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let complete: Bool

    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data.subdata(in: data.startIndex..<sep.lowerBound), encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        lines.removeFirst()

        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            h[key] = value
        }
        headers = h

        let declared = Int(h["content-length"] ?? "0") ?? 0
        let available = data.count - (sep.upperBound - data.startIndex)
        complete = available >= declared
        body = complete
            ? data.subdata(in: sep.upperBound..<(sep.upperBound + declared))
            : Data()
    }
}

// MARK: - Server

/// Loopback-only HTTP endpoint that agent hooks POST into. Nothing is ever sent
/// off the machine; the port is ephemeral and gated by a 0600 token file.
final class HookServer {
    private let state: AppState
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.perch.server")
    private var token = ""
    private(set) var port: UInt16 = 0

    init(state: AppState) { self.state = state }

    func start() throws {
        PerchPaths.ensureRoot()
        token = Self.loadOrCreateToken()

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                guard let p = l.port else { return }
                self.port = p.rawValue
                try? String(p.rawValue).write(to: PerchPaths.portFile, atomically: true, encoding: .utf8)
                HookScript.write(port: p.rawValue)
                Task { @MainActor in self.state.serverPort = p.rawValue }
            case .failed(let e):
                NSLog("Perch: listener failed \(e)")
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(at: PerchPaths.portFile)
    }

    private static func loadOrCreateToken() -> String {
        if let s = try? String(contentsOf: PerchPaths.tokenFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        try? t.write(to: PerchPaths.tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: PerchPaths.tokenFile.path)
        return t
    }

    // MARK: connection handling

    private func accept(_ conn: NWConnection) {
        var buffer = Data()

        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] chunk, _, isDone, error in
                guard let self else { conn.cancel(); return }
                if let chunk { buffer.append(chunk) }
                if let req = HTTPRequest(buffer), req.complete {
                    self.handle(req, on: conn)
                    return
                }
                if isDone || error != nil { conn.cancel(); return }
                if buffer.count > 8 << 20 { conn.cancel(); return }
                read()
            }
        }

        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: read()
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func respond(_ conn: NWConnection, status: String = "200 OK", json: String = "") {
        let body = Data(json.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r\n
        """
        conn.send(content: Data(head.utf8) + body,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) {
        // Browsers can reach loopback; refuse anything that smells like a page.
        guard req.headers["origin"] == nil,
              req.headers["sec-fetch-mode"] == nil,
              req.headers["x-perch-token"] == token else {
            respond(conn, status: "403 Forbidden", json: #"{"error":"forbidden"}"#)
            return
        }

        if req.path == "/health" {
            respond(conn, json: #"{"ok":true,"app":"perch"}"#)
            return
        }

        guard req.method == "POST",
              let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        else {
            respond(conn, json: "")
            return
        }

        let eventFromPath = req.path.hasPrefix("/hook/") ? String(req.path.dropFirst("/hook/".count)) : nil
        let event = eventFromPath ?? (payload["hook_event_name"] as? String) ?? "Unknown"
        let terminal = TerminalContext(headers: req.headers)

        Task { @MainActor [weak self] in
            guard let self else { return }
            HookRouter(state: self.state).route(event: event, payload: payload, terminal: terminal) { reply in
                self.respond(conn, json: reply ?? "")
            }
        }
    }
}

// MARK: - Hook shim

enum HookScript {
    /// Written to ~/.perch/hook.sh. Deliberately fails open: if Perch is not
    /// running, or curl errors, the script exits 0 with no stdout so the agent
    /// behaves exactly as it would without Perch installed.
    static func write(port: UInt16) {
        PerchPaths.ensureRoot()
        let script = """
        #!/bin/sh
        # Perch hook shim — generated, safe to delete. Fails open by design.
        PERCH_DIR="$HOME/.perch"
        PORT=$(cat "$PERCH_DIR/port" 2>/dev/null) || exit 0
        TOKEN=$(cat "$PERCH_DIR/token" 2>/dev/null) || exit 0
        [ -n "$PORT" ] && [ -n "$TOKEN" ] || exit 0

        EVENT="${1:-Unknown}"
        TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' \\n')

        curl -sS --max-time 300 \\
          -H "Content-Type: application/json" \\
          -H "X-Perch-Token: $TOKEN" \\
          -H "X-Perch-Term: ${TERM_PROGRAM:-}" \\
          -H "X-Perch-Tty: ${TTY:-}" \\
          -H "X-Perch-Iterm: ${ITERM_SESSION_ID:-}" \\
          -H "X-Perch-Termsession: ${TERM_SESSION_ID:-}" \\
          -H "X-Perch-Tmux: ${TMUX_PANE:-}" \\
          -H "X-Perch-Wezterm: ${WEZTERM_PANE:-}" \\
          -H "X-Perch-Kitty: ${KITTY_WINDOW_ID:-}" \\
          -H "X-Perch-Pid: $PPID" \\
          --data-binary @- \\
          "http://127.0.0.1:$PORT/hook/$EVENT" 2>/dev/null || exit 0
        exit 0
        """
        try? script.write(to: PerchPaths.hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: PerchPaths.hookScript.path)
        _ = port
    }
}
