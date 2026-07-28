import Foundation

/// Turns a raw `tool_input` dictionary into something a human can read in a
/// 600pt-wide notch panel: a headline, a preview body, and line deltas.
enum ToolSummary {

    struct Result {
        var headline: String
        var detail: String
        var added: Int = 0
        var removed: Int = 0
        /// True for tools that cannot mutate anything outside the process.
        var readOnly: Bool = false
    }

    private static let readOnlyTools: Set<String> = [
        "Read", "NotebookRead", "Glob", "Grep", "LS", "TodoWrite", "TodoRead",
        "WebSearch", "BashOutput", "ListMcpResourcesTool", "ReadMcpResourceTool",
    ]

    static func make(tool: String, input: [String: Any], cwd: String) -> Result {
        var r = Result(headline: tool, detail: "")
        r.readOnly = readOnlyTools.contains(tool)

        func rel(_ p: String) -> String {
            if !cwd.isEmpty, p.hasPrefix(cwd) {
                return String(p.dropFirst(cwd.count).drop(while: { $0 == "/" }))
            }
            let home = PerchPaths.home.path
            return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        }

        switch tool {
        case "Read", "NotebookRead":
            let p = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
            r.headline = rel(p)
            if let off = input["offset"] as? Int, let lim = input["limit"] as? Int {
                r.detail = "lines \(off)–\(off + lim)"
            }

        case "Write":
            let p = input["file_path"] as? String ?? ""
            let content = input["content"] as? String ?? ""
            r.headline = rel(p)
            r.added = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
            r.detail = preview(content, marker: "+", limit: 14)

        case "Edit":
            let p = input["file_path"] as? String ?? ""
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            r.headline = rel(p)
            let d = diff(old: old, new: new)
            r.added = d.added; r.removed = d.removed; r.detail = d.text

        case "MultiEdit":
            let p = input["file_path"] as? String ?? ""
            let edits = input["edits"] as? [[String: Any]] ?? []
            r.headline = "\(rel(p))  ·  \(edits.count) edit\(edits.count == 1 ? "" : "s")"
            var parts: [String] = []
            for e in edits.prefix(4) {
                let d = diff(old: e["old_string"] as? String ?? "", new: e["new_string"] as? String ?? "")
                r.added += d.added; r.removed += d.removed
                parts.append(d.text)
            }
            r.detail = parts.joined(separator: "\n⋯\n")

        case "Bash":
            let cmd = input["command"] as? String ?? ""
            r.headline = cmd.replacingOccurrences(of: "\n", with: " ⏎ ")
            r.detail = cmd
            if let desc = input["description"] as? String, !desc.isEmpty {
                r.detail = desc + "\n\n" + cmd
            }

        case "Glob":
            r.headline = input["pattern"] as? String ?? ""
            if let p = input["path"] as? String { r.detail = "in \(rel(p))" }

        case "Grep":
            r.headline = input["pattern"] as? String ?? ""
            var bits: [String] = []
            if let p = input["path"] as? String { bits.append("in \(rel(p))") }
            if let g = input["glob"] as? String { bits.append("glob \(g)") }
            r.detail = bits.joined(separator: "  ·  ")

        case "WebFetch", "WebSearch":
            r.headline = input["url"] as? String ?? input["query"] as? String ?? ""
            r.detail = input["prompt"] as? String ?? ""

        case "Task", "Agent":
            r.headline = input["description"] as? String ?? "subagent"
            r.detail = input["prompt"] as? String ?? ""

        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            let done = todos.filter { ($0["status"] as? String) == "completed" }.count
            r.headline = "\(done)/\(todos.count) done"
            r.detail = todos.compactMap { t -> String? in
                guard let c = t["content"] as? String else { return nil }
                let s = t["status"] as? String ?? ""
                let box = s == "completed" ? "[x]" : (s == "in_progress" ? "[~]" : "[ ]")
                return "\(box) \(c)"
            }.joined(separator: "\n")

        default:
            // MCP tools and anything else: show the most string-ish argument.
            let best = input
                .compactMapValues { $0 as? String }
                .max(by: { $0.value.count < $1.value.count })
            r.headline = best?.value ?? tool
            r.detail = compactJSON(input)
        }

        if r.headline.isEmpty { r.headline = tool }
        r.headline = truncate(r.headline.trimmingCharacters(in: .whitespacesAndNewlines), 140)
        r.detail = truncate(r.detail, 4000)
        return r
    }

    // MARK: helpers

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    private static func preview(_ s: String, marker: String, limit: Int) -> String {
        let lines = s.components(separatedBy: "\n")
        let head = lines.prefix(limit).map { "\(marker) \($0)" }.joined(separator: "\n")
        return lines.count > limit ? head + "\n⋯ \(lines.count - limit) more lines" : head
    }

    /// Cheap line-level diff: strip the common prefix/suffix of lines, then show
    /// the changed middle. Good enough for an at-a-glance notch preview.
    static func diff(old: String, new: String) -> (added: Int, removed: Int, text: String) {
        var o = old.components(separatedBy: "\n")
        var n = new.components(separatedBy: "\n")
        if old.isEmpty { o = [] }
        if new.isEmpty { n = [] }

        var head = 0
        while head < o.count, head < n.count, o[head] == n[head] { head += 1 }
        var tail = 0
        while tail < o.count - head, tail < n.count - head,
              o[o.count - 1 - tail] == n[n.count - 1 - tail] { tail += 1 }

        let removedLines = Array(o[head..<(o.count - tail)])
        let addedLines = Array(n[head..<(n.count - tail)])

        var body: [String] = []
        if head > 0, let ctx = o[safe: head - 1] { body.append("  \(ctx)") }
        body += removedLines.prefix(10).map { "- \($0)" }
        if removedLines.count > 10 { body.append("- ⋯ \(removedLines.count - 10) more") }
        body += addedLines.prefix(10).map { "+ \($0)" }
        if addedLines.count > 10 { body.append("+ ⋯ \(addedLines.count - 10) more") }
        if tail > 0, let ctx = o[safe: o.count - tail] { body.append("  \(ctx)") }

        return (addedLines.count, removedLines.count, body.joined(separator: "\n"))
    }

    static func compactJSON(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
        return s
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
