import Foundation

/// Reads Claude Code JSONL transcripts **incrementally**: each refresh seeks to
/// where the last one stopped and parses only the bytes that arrived since.
/// A three-hour session is a multi-megabyte file; re-parsing it on every tool
/// call was the single most expensive thing the app did.
final class TranscriptStore {
    static let shared = TranscriptStore()

    private final class Entry {
        var offset: UInt64 = 0
        var partial = Data()                       // trailing bytes of a split line
        var usage = Usage()
        var messages: [ChatMessage] = []
        var chipIndex: [String: (Int, Int)] = [:]  // tool_use id -> (message, chip)
        var lastRefresh = Date.distantPast
        var keepMessages = false
    }

    /// Beyond this the viewer drops the oldest messages; usage totals are unaffected.
    private static let messageCap = 600

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.perch.transcript", qos: .utility)

    // MARK: API

    /// Cheap path used by the hook router: totals only, throttled.
    func usage(path: String, minInterval: TimeInterval = 4, completion: @escaping (Usage) -> Void) {
        queue.async { [self] in
            let entry = entry(for: path)
            guard Date().timeIntervalSince(entry.lastRefresh) >= minInterval else { return }
            guard ingest(path: path, into: entry) else { return }
            let usage = entry.usage
            guard usage.totalTokens > 0 else { return }
            completion(usage)
        }
    }

    /// Full path used by the chat window: keeps parsed messages around.
    func conversation(path: String, completion: @escaping (Usage, [ChatMessage]) -> Void) {
        queue.async { [self] in
            let entry = entry(for: path)
            if !entry.keepMessages {
                // Was only tracking totals until now; re-read from the top once.
                entry.keepMessages = true
                entry.offset = 0
                entry.partial = Data()
                entry.usage = Usage()
                entry.messages = []
                entry.chipIndex = [:]
            }
            _ = ingest(path: path, into: entry)
            completion(entry.usage, entry.messages)
        }
    }

    func forget(path: String) {
        lock.lock(); cache[path] = nil; lock.unlock()
    }

    // MARK: parsing

    private func entry(for path: String) -> Entry {
        lock.lock(); defer { lock.unlock() }
        if let e = cache[path] { return e }
        let e = Entry()
        cache[path] = e
        return e
    }

    /// Returns true when new bytes were consumed.
    private func ingest(path: String, into entry: Entry) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset {           // file rotated or truncated: start over
            entry.offset = 0
            entry.partial = Data()
            entry.usage = Usage()
            entry.messages = []
            entry.chipIndex = [:]
        }
        guard size > entry.offset else {
            entry.lastRefresh = Date()
            return false
        }

        try? handle.seek(toOffset: entry.offset)
        guard let fresh = try? handle.readToEnd(), !fresh.isEmpty else { return false }
        entry.offset = size
        entry.lastRefresh = Date()

        var buffer = entry.partial + fresh
        entry.partial = Data()
        if buffer.last != UInt8(ascii: "\n"), let cut = buffer.lastIndex(of: UInt8(ascii: "\n")) {
            entry.partial = Data(buffer[buffer.index(after: cut)...])
            buffer = Data(buffer[..<cut])
        }

        for line in buffer.split(separator: UInt8(ascii: "\n")) where line.count > 8 {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            consume(obj, into: entry)
        }

        if entry.keepMessages && entry.messages.count > Self.messageCap {
            let drop = entry.messages.count - Self.messageCap
            entry.messages.removeFirst(drop)
            entry.chipIndex = entry.chipIndex.compactMapValues { m, c in
                m >= drop ? (m - drop, c) : nil
            }
        }
        return true
    }

    private func consume(_ obj: [String: Any], into entry: Entry) {
        let type = obj["type"] as? String ?? ""

        if type == "summary", entry.keepMessages {
            let text = obj["summary"] as? String ?? ""
            guard !text.isEmpty else { return }
            entry.messages.append(ChatMessage(id: uuid(obj), role: .summary, text: text))
            return
        }

        guard let message = obj["message"] as? [String: Any] else { return }

        // Totals are always accumulated, even when the viewer is closed.
        if let u = message["usage"] as? [String: Any] {
            entry.usage.input += u["input_tokens"] as? Int ?? 0
            entry.usage.output += u["output_tokens"] as? Int ?? 0
            entry.usage.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
            entry.usage.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
        }
        if let m = message["model"] as? String { entry.usage.model = m }

        guard entry.keepMessages, type == "user" || type == "assistant" else { return }

        var chat = ChatMessage(id: uuid(obj), role: type == "assistant" ? .assistant : .user)
        chat.timestamp = date(obj["timestamp"] as? String)
        chat.model = message["model"] as? String
        chat.isMeta = obj["isMeta"] as? Bool ?? false

        switch message["content"] {
        case let s as String:
            chat.text = s
        case let blocks as [[String: Any]]:
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    append(&chat.text, block["text"] as? String)
                case "thinking":
                    append(&chat.thinking, block["thinking"] as? String)
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let summary = ToolSummary.make(tool: name, input: input, cwd: "")
                    chat.chips.append(ToolChip(id: block["id"] as? String ?? UUID().uuidString,
                                               name: name,
                                               summary: summary.headline,
                                               input: summary.detail.isEmpty
                                                   ? ToolSummary.compactJSON(input) : summary.detail))
                case "tool_result":
                    attachResult(block, in: entry)
                default:
                    break
                }
            }
        default:
            break
        }

        // A user entry that only carried tool results has nothing to show.
        guard !chat.isEmpty else { return }

        // Claude Code writes one entry per content block, so a single turn
        // arrives as a run of assistant entries. Fold them into one block or
        // the viewer is a wall of repeated "CLAUDE" headers.
        if chat.role == .assistant, !chat.isMeta,
           let last = entry.messages.indices.last,
           entry.messages[last].role == .assistant,
           entry.messages[last].isMeta == false {
            append(&entry.messages[last].text, chat.text.isEmpty ? nil : chat.text)
            append(&entry.messages[last].thinking, chat.thinking.isEmpty ? nil : chat.thinking)
            for chip in chat.chips {
                entry.chipIndex[chip.id] = (last, entry.messages[last].chips.count)
                entry.messages[last].chips.append(chip)
            }
            if entry.messages[last].model == nil { entry.messages[last].model = chat.model }
            return
        }

        for (i, chip) in chat.chips.enumerated() {
            entry.chipIndex[chip.id] = (entry.messages.count, i)
        }
        entry.messages.append(chat)
    }

    private func attachResult(_ block: [String: Any], in entry: Entry) {
        guard let id = block["tool_use_id"] as? String,
              let (m, c) = entry.chipIndex[id],
              entry.messages.indices.contains(m),
              entry.messages[m].chips.indices.contains(c) else { return }

        var text = ""
        switch block["content"] {
        case let s as String: text = s
        case let blocks as [[String: Any]]:
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default: break
        }
        entry.messages[m].chips[c].result = ToolSummary.truncate(text, 4000)
        entry.messages[m].chips[c].isError = block["is_error"] as? Bool ?? false
    }

    // MARK: small helpers

    private func append(_ target: inout String, _ text: String?) {
        guard let text, !text.isEmpty else { return }
        if !target.isEmpty { target += "\n\n" }
        target += text
    }

    private func uuid(_ obj: [String: Any]) -> String {
        obj["uuid"] as? String ?? UUID().uuidString
    }

    private static let formatter = ISO8601DateFormatter()

    private func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return Self.formatter.date(from: raw)
    }
}
