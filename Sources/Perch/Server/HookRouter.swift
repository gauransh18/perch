import Foundation

/// Translates one agent hook event into session-state changes, and decides what
/// (if anything) to write back on stdout of the hook.
@MainActor
struct HookRouter {
    let state: AppState

    func route(event: String,
               payload: [String: Any],
               terminal: TerminalContext,
               reply: @escaping (String?) -> Void) {

        let sessionID = payload["session_id"] as? String
            ?? payload["sessionId"] as? String
            ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let kind = AgentKind(rawValue: payload["agent"] as? String ?? "") ?? .claudeCode

        state.upsert(id: sessionID, kind: kind, cwd: cwd, terminal: terminal)
        if let t = payload["transcript_path"] as? String {
            state.mutate(sessionID) { $0.transcriptPath = t }
        }

        switch event {
        case "SessionStart":
            state.mutate(sessionID) { $0.state = .idle; $0.notice = nil }
            reply(nil)

        case "UserPromptSubmit":
            let prompt = payload["prompt"] as? String ?? ""
            state.mutate(sessionID) {
                $0.lastPrompt = ToolSummary.truncate(prompt, 400)
                $0.state = .thinking
                $0.notice = nil
            }
            SoundEngine.shared.play(.start)
            reply(nil)

        case "PreToolUse":
            handlePreToolUse(sessionID: sessionID, cwd: cwd, payload: payload, reply: reply)

        case "PostToolUse":
            let tool = payload["tool_name"] as? String ?? "tool"
            let failed = isFailure(payload["tool_response"])
            state.mutate(sessionID) { s in
                if let i = s.activities.lastIndex(where: { $0.tool == tool && $0.status == .running }) {
                    s.activities[i].status = failed ? .failed : .ok
                    s.activities[i].endedAt = Date()
                }
                s.state = .working
            }
            refreshUsage(sessionID)
            reply(nil)

        case "Notification":
            let message = payload["message"] as? String ?? "Waiting for you"
            state.mutate(sessionID) { $0.notice = message; $0.state = .waiting }
            SoundEngine.shared.play(.attention)
            reply(nil)

        case "Stop", "SubagentStop":
            state.mutate(sessionID) { s in
                s.state = .done
                s.notice = nil
                for i in s.activities.indices where s.activities[i].status == .running {
                    s.activities[i].status = .ok
                    s.activities[i].endedAt = Date()
                }
            }
            refreshUsage(sessionID)
            if event == "Stop" { SoundEngine.shared.play(.done) }
            reply(nil)

        case "SessionEnd":
            refreshUsage(sessionID)
            state.mutate(sessionID) { $0.state = .done }
            reply(nil)

        case "PreCompact":
            state.mutate(sessionID) { $0.notice = "Compacting context…" }
            reply(nil)

        default:
            reply(nil)
        }
    }

    // MARK: PreToolUse

    private func handlePreToolUse(sessionID: String,
                                  cwd: String,
                                  payload: [String: Any],
                                  reply: @escaping (String?) -> Void) {
        let tool = payload["tool_name"] as? String ?? "tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]

        // Plan review is its own opt-in, independent of approval mode. Exiting
        // plan mode is a decision the agent stops and asks about anyway, so
        // answering it from the notch replaces a prompt rather than bypassing
        // a permission rule the user configured.
        if Self.isPlanExit(tool), Prefs.planReview,
           let plan = (input["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            handlePlan(sessionID: sessionID, cwd: cwd, tool: tool, plan: plan, reply: reply)
            return
        }

        let needsCard = state.approvalMode
        let summary = ToolSummary.make(tool: tool, input: input, cwd: cwd, detail: needsCard)

        var activity = ToolActivity(tool: tool, headline: summary.headline)
        activity.added = summary.added
        activity.removed = summary.removed

        state.mutate(sessionID) { s in
            s.state = .working
            s.notice = nil
            s.activities.append(activity)
            if s.activities.count > 120 { s.activities.removeFirst(s.activities.count - 120) }
        }

        // Observe-only unless the user explicitly turned on approval mode.
        guard needsCard else { reply(nil); return }

        if summary.readOnly && Prefs.autoAllowReadOnly {
            reply(Self.decisionJSON(.allow, reason: "Read-only tool auto-allowed by Perch"))
            return
        }

        let session = state.session(sessionID)
        let req = ApprovalRequest(
            sessionID: sessionID,
            agent: session?.kind ?? .claudeCode,
            project: session?.project ?? "",
            cwd: cwd,
            tool: tool,
            headline: summary.headline,
            detail: summary.detail,
            added: summary.added,
            removed: summary.removed,
            resolve: { decision in
                Task { @MainActor in
                    state.mutate(sessionID) { s in
                        if let i = s.activities.lastIndex(where: { $0.id == activity.id }) {
                            if decision == .deny {
                                s.activities[i].status = .denied
                                s.activities[i].endedAt = Date()
                            }
                        }
                    }
                }
                switch decision {
                case .allow:            reply(Self.decisionJSON(.allow, reason: "Allowed in Perch"))
                case .deny:             reply(Self.decisionJSON(.deny, reason: "Denied in Perch"))
                case .feedback(let note): reply(Self.decisionJSON(.deny, reason: note))
                case .passthrough:      reply(nil)
                }
            })

        state.enqueue(req)
        SoundEngine.shared.play(.attention)
        NotchWindowController.shared?.focusForApproval()
    }

    // MARK: Plan review

    static func isPlanExit(_ tool: String) -> Bool {
        let name = tool.lowercased().replacingOccurrences(of: "_", with: "")
        return name == "exitplanmode" || name == "exitplan"
    }

    private func handlePlan(sessionID: String,
                            cwd: String,
                            tool: String,
                            plan: String,
                            reply: @escaping (String?) -> Void) {
        let title = Markdown.title(of: plan)
        let activity = ToolActivity(tool: tool, headline: ToolSummary.truncate(title, 140))

        state.mutate(sessionID) { s in
            s.state = .waiting
            s.notice = "Plan ready for review"
            s.activities.append(activity)
        }

        let session = state.session(sessionID)
        let request = ApprovalRequest(
            kind: .plan,
            sessionID: sessionID,
            agent: session?.kind ?? .claudeCode,
            project: session?.project ?? "",
            cwd: cwd,
            tool: tool,
            headline: title,
            detail: "",
            plan: plan,
            resolve: { decision in
                Task { @MainActor in
                    state.mutate(sessionID) { s in
                        guard let i = s.activities.lastIndex(where: { $0.id == activity.id }) else { return }
                        s.activities[i].endedAt = Date()
                        switch decision {
                        case .allow: s.activities[i].status = .ok
                        case .deny, .feedback: s.activities[i].status = .denied
                        case .passthrough: s.activities[i].status = .ok
                        }
                    }
                    state.mutate(sessionID) { $0.notice = nil; $0.state = .working }
                }
                switch decision {
                case .allow:
                    reply(Self.decisionJSON(.allow, reason: "Plan approved in Perch"))
                case .deny:
                    reply(Self.decisionJSON(.deny, reason: "Plan rejected in Perch"))
                case .feedback(let note):
                    reply(Self.decisionJSON(.deny, reason: note))
                case .passthrough:
                    reply(nil)
                }
            })

        state.enqueue(request)
        SoundEngine.shared.play(.attention)
        NotchWindowController.shared?.focusForApproval()
    }

    private static func decisionJSON(_ d: ApprovalRequest.Decision, reason: String) -> String {
        let value: String
        switch d {
        case .allow: value = "allow"
        case .deny, .feedback: value = "deny"
        case .passthrough: value = "ask"
        }
        let obj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": value,
                "permissionDecisionReason": reason,
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: helpers

    private func isFailure(_ response: Any?) -> Bool {
        if let d = response as? [String: Any] {
            if let ok = d["success"] as? Bool { return !ok }
            if let e = d["error"] as? String, !e.isEmpty { return true }
            if d["is_error"] as? Bool == true { return true }
        }
        if let s = response as? String {
            return s.hasPrefix("Error:") || s.contains("<tool_use_error>")
        }
        return false
    }

    private func refreshUsage(_ sessionID: String) {
        guard Prefs.trackCost,
              let path = state.session(sessionID)?.transcriptPath else { return }
        TranscriptStore.shared.usage(path: path) { usage in
            Task { @MainActor in
                state.mutate(sessionID) { $0.usage = usage }
            }
        }
    }
}
