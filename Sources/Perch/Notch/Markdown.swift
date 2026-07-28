import SwiftUI

/// A block-level Markdown renderer scoped to what agent plans actually contain:
/// headings, bullets, numbered steps, task lists, fenced code, quotes, rules.
///
/// SwiftUI's built-in `AttributedString(markdown:)` is inline-only — it renders
/// `**bold**` but turns a heading into a literal "## Heading" and flattens every
/// list into one paragraph. Rather than take a general Markdown dependency for
/// a narrow, well-understood subset, the block grammar is parsed here and the
/// inline pass is handed back to `AttributedString`.
enum Markdown {

    enum Block: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(depth: Int, marker: String?, text: String)
        case task(depth: Int, done: Bool, text: String)
        case code(language: String, body: String)
        case quote(String)
        case rule

        var id: String {
            switch self {
            case .heading(let l, let t): return "h\(l):\(t)"
            case .paragraph(let t): return "p:\(t)"
            case .bullet(let d, let m, let t): return "b\(d):\(m ?? "-"):\(t)"
            case .task(let d, let done, let t): return "t\(d):\(done):\(t)"
            case .code(let lang, let body): return "c:\(lang):\(body)"
            case .quote(let t): return "q:\(t)"
            case .rule: return "hr"
            }
        }
    }

    // MARK: - Block parsing

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        var lines = source.components(separatedBy: .newlines)[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code runs to the closing fence, or to the end of input.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(next)
                }
                blocks.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushParagraph(); continue }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let hashes = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 4), text: text))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                // A wrapped quote is one quote. Consume the whole run of `>`
                // lines instead of emitting a rule-and-text block per line.
                var quoted = [String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first {
                    let peek = next.trimmingCharacters(in: .whitespaces)
                    guard peek.hasPrefix("> ") || peek == ">" else { break }
                    lines = lines.dropFirst()
                    quoted.append(String(peek.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                }
                blocks.append(.quote(quoted.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
                continue
            }

            let depth = indentDepth(line)

            if let task = taskItem(trimmed) {
                flushParagraph()
                blocks.append(.task(depth: depth, done: task.done, text: task.text))
                continue
            }

            if let bullet = bulletItem(trimmed) {
                flushParagraph()
                blocks.append(.bullet(depth: depth, marker: bullet.marker, text: bullet.text))
                continue
            }

            paragraph.append(trimmed)
        }
        flushParagraph()
        return blocks
    }

    private static func isRule(_ s: String) -> Bool {
        guard s.count >= 3 else { return false }
        return ["-", "*", "_"].contains { c in s.allSatisfy { String($0) == c } }
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes > 0, hashes <= 6 else { return nil }
        guard s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func indentDepth(_ line: String) -> Int {
        let spaces = line.prefix(while: { $0 == " " }).count
        return min(spaces / 2, 3)
    }

    private static func taskItem(_ s: String) -> (done: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            let rest = s.dropFirst(marker.count)
            guard rest.hasPrefix("[") , rest.dropFirst().first != nil else { return nil }
            let box = rest.prefix(3)                     // "[ ]" or "[x]"
            guard box.hasPrefix("["), box.hasSuffix("]") else { return nil }
            let done = box.lowercased().contains("x")
            return (done, String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func bulletItem(_ s: String) -> (marker: String?, text: String)? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return (nil, String(s.dropFirst(marker.count)))
        }
        // Ordered: "1. ", "12) "
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (String(digits) + ".", String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    // MARK: - Inline

    /// Inline emphasis, code spans and links, styled for a dark panel.
    static func inline(_ source: String, size: CGFloat = 12, weight: Font.Weight = .regular) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)

        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        attributed.font = .system(size: size, weight: weight)
        attributed.foregroundColor = .white.opacity(0.82)

        // Collect first: mutating the string invalidates the run iterator.
        let runs = attributed.runs.map { ($0.range, $0.inlinePresentationIntent, $0.link) }
        for (range, intent, link) in runs {
            if intent?.contains(.code) == true {
                attributed[range].font = .system(size: size - 0.5, design: .monospaced)
                attributed[range].foregroundColor = Color(red: 0.98, green: 0.78, blue: 0.52)
            }
            if intent?.contains(.stronglyEmphasized) == true {
                attributed[range].font = .system(size: size, weight: .semibold)
                attributed[range].foregroundColor = .white.opacity(0.95)
            }
            if intent?.contains(.emphasized) == true {
                attributed[range].font = .system(size: size, weight: weight).italic()
            }
            if intent?.contains(.strikethrough) == true {
                attributed[range].strikethroughStyle = .single
                attributed[range].foregroundColor = .white.opacity(0.4)
            }
            if link != nil {
                attributed[range].foregroundColor = Color(red: 0.45, green: 0.72, blue: 1)
                attributed[range].underlineStyle = .single
            }
        }
        return attributed
    }

    /// First heading, or first non-empty line — used as a one-line summary.
    static func title(of source: String) -> String {
        for block in parse(source) {
            switch block {
            case .heading(_, let text): return text
            case .paragraph(let text): return text
            case .bullet(_, _, let text), .task(_, _, let text): return text
            default: continue
            }
        }
        return "Plan"
    }
}

// MARK: - View

struct MarkdownView: View {
    let source: String
    var baseSize: CGFloat = 12

    private var blocks: [Markdown.Block] { Markdown.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                row(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text, size: headingSize(level), weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            Text(Markdown.inline(text, size: baseSize))
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker ?? "•")
                    .font(.system(size: baseSize - (marker == nil ? 0 : 1),
                                  weight: .semibold, design: marker == nil ? .default : .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(minWidth: marker == nil ? 6 : 16, alignment: .trailing)
                Text(Markdown.inline(text, size: baseSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .task(let depth, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: baseSize - 1))
                    .foregroundStyle(done ? Color(red: 0.4, green: 0.85, blue: 0.55) : .white.opacity(0.35))
                Text(Markdown.inline(text, size: baseSize))
                    .strikethrough(done, color: .white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 3) {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.3))
                }
                Text(body)
                    .font(.system(size: baseSize - 1, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05)))

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(Color.white.opacity(0.2)).frame(width: 2)
                Text(Markdown.inline(text, size: baseSize))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 3
        case 2: return baseSize + 1.5
        case 3: return baseSize + 0.5
        default: return baseSize
        }
    }
}
