import Foundation

/// Reads a Claude Code JSONL transcript and sums token usage. Throttled per
/// session so a long conversation doesn't get re-parsed on every tool call.
final class TranscriptReader {
    static let shared = TranscriptReader()

    private let queue = DispatchQueue(label: "app.perch.transcript", qos: .utility)
    private var lastRun: [String: Date] = [:]
    private let lock = NSLock()

    func usage(forTranscript path: String, session: String, minInterval: TimeInterval = 4,
               completion: @escaping (Usage) -> Void) {
        lock.lock()
        let recent = lastRun[session].map { Date().timeIntervalSince($0) < minInterval } ?? false
        if !recent { lastRun[session] = Date() }
        lock.unlock()
        guard !recent else { return }

        queue.async {
            guard let usage = Self.parse(path) else { return }
            completion(usage)
        }
    }

    private static func parse(_ path: String) -> Usage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var usage = Usage()
        // Split on newline without materialising huge Strings per line where possible.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 40 else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let u = message["usage"] as? [String: Any] else { continue }
            usage.input += u["input_tokens"] as? Int ?? 0
            usage.output += u["output_tokens"] as? Int ?? 0
            usage.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
            usage.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
            if let m = message["model"] as? String { usage.model = m }
        }
        return usage.totalTokens > 0 ? usage : nil
    }
}
