import Foundation

// DevReply Markdown (spec 05, "Markdown in team messages"): the small subset team and agent replies are
// written in, parsed to the same tree on every platform. A port of sdk/conformance/markdown/reference.py;
// sdk/conformance/markdown/cases.json is the contract (MarkdownTests runs every case).
// Works on Unicode scalars, like the reference's Python strings, so positions and rules match exactly.

/// A run of text with its marks.
struct MarkdownSpan: Equatable, Sendable {
    var text: String
    var bold = false
    var italic = false
    var strike = false
    var code = false
    /// `http`, `https` or `mailto` only.
    var link: String?

    /// Same marks (the text aside): adjacent spans like this are merged.
    func sameMarks(_ other: MarkdownSpan) -> Bool {
        bold == other.bold && italic == other.italic && strike == other.strike && code == other.code && link == other.link
    }
}

enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownSpan])
    /// `#` to `######`: all shown in one heading style.
    case heading([MarkdownSpan])
    case quote([MarkdownSpan])
    /// Numbered lists count from `start`.
    case list(ordered: Bool, start: Int, items: [[MarkdownSpan]])
    case code(String)
}

enum Markdown {
    // MARK: Blocks

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { Array(String($0).unicodeScalars) }
        var blocks: [MarkdownBlock] = []

        enum Current {
            case paragraph([String]), quote([String])
            case list(ordered: Bool, start: Int, items: [[String]])
        }
        var current: Current?

        func close() {
            switch current {
            case .paragraph(let lines): blocks.append(.paragraph(inline(lines.joined(separator: "\n"))))
            case .quote(let lines): blocks.append(.quote(inline(lines.joined(separator: "\n"))))
            case .list(let ordered, let start, let items):
                blocks.append(.list(ordered: ordered, start: start, items: items.map { inline($0.joined(separator: "\n")) }))
            case nil: break
            }
            current = nil
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let stripped = strip(line)
            if stripped.isEmpty {
                close(); i += 1; continue
            }
            if hasPrefix(stripped, "```") {
                close()
                var body: [String] = []
                i += 1
                while i < lines.count, !hasPrefix(strip(lines[i]), "```") {
                    body.append(string(lines[i])); i += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                i += 1; continue
            }
            if let text = heading(line) {
                close()
                blocks.append(.heading(inline(text)))
                i += 1; continue
            }
            if let text = quote(line) {
                if case .quote(var lines) = current {
                    lines.append(text)
                    current = .quote(lines)
                } else {
                    close()
                    current = .quote([text])
                }
                i += 1; continue
            }
            if let item = listItem(line) {
                if case .list(let ordered, let start, var items) = current, ordered == item.ordered {
                    items.append([item.text])
                    current = .list(ordered: ordered, start: start, items: items)
                } else {
                    close()
                    current = .list(ordered: item.ordered, start: item.number ?? 1, items: [[item.text]])
                }
                i += 1; continue
            }
            if case .list(let ordered, let start, var items) = current,
               hasPrefix(line, "  ") || hasPrefix(line, "\t"), !items.isEmpty {
                items[items.count - 1].append(string(stripped))
                current = .list(ordered: ordered, start: start, items: items)
                i += 1; continue
            }
            if case .paragraph(var lines) = current {
                lines.append(string(stripped))
                current = .paragraph(lines)
            } else {
                close()
                current = .paragraph([string(stripped)])
            }
            i += 1
        }
        close()
        return blocks
    }

    /// `^\s*(#{1,6})\s+(.*?)\s*$`: the heading's text.
    private static func heading(_ line: [Unicode.Scalar]) -> String? {
        var i = 0
        while i < line.count, isSpace(line[i]) { i += 1 }
        var hashes = 0
        while i < line.count, line[i] == "#" { hashes += 1; i += 1 }
        guard (1...6).contains(hashes), i < line.count, isSpace(line[i]) else { return nil }
        return string(strip(Array(line[i...])))
    }

    /// `^\s*>\s?(.*)$`, stripped.
    private static func quote(_ line: [Unicode.Scalar]) -> String? {
        var i = 0
        while i < line.count, isSpace(line[i]) { i += 1 }
        guard i < line.count, line[i] == ">" else { return nil }
        return string(strip(Array(line[(i + 1)...])))
    }

    /// `^\s{0,1}[-*+]\s+(.*)$` or `^\s{0,1}(\d{1,9})[.)]\s+(.*)$`, the text stripped.
    private static func listItem(_ line: [Unicode.Scalar]) -> (ordered: Bool, number: Int?, text: String)? {
        var i = 0
        if i < line.count, isSpace(line[i]) { i += 1 }
        guard i < line.count else { return nil }
        if "-*+".unicodeScalars.contains(line[i]) {
            guard i + 1 < line.count, isSpace(line[i + 1]) else { return nil }
            return (false, nil, string(strip(Array(line[(i + 1)...]))))
        }
        var number = 0, digits = 0
        while i < line.count, let digit = decimalDigit(line[i]) {
            number = number * 10 + digit; digits += 1; i += 1
        }
        guard (1...9).contains(digits), i < line.count, line[i] == "." || line[i] == ")",
              i + 1 < line.count, isSpace(line[i + 1]) else { return nil }
        return (true, number, string(strip(Array(line[(i + 1)...]))))
    }

    // MARK: Inline

    private static let escapable = Set("\\`*_~[]()#>!+-.".unicodeScalars)
    private static let schemes = ["http://", "https://", "mailto:"]
    private static let emphasis: [(token: String, bold: Bool, italic: Bool, strike: Bool)] = [
        ("***", true, true, false), ("**", true, false, false), ("__", true, false, false),
        ("~~", false, false, true), ("*", false, true, false), ("_", false, true, false),
    ]

    static func inline(_ text: String) -> [MarkdownSpan] {
        inline(Array(text.unicodeScalars), MarkdownSpan(text: ""))
    }

    /// `marks`: the marks around this text (its `text` unused).
    private static func inline(_ s: [Unicode.Scalar], _ marks: MarkdownSpan) -> [MarkdownSpan] {
        var out: [MarkdownSpan] = []
        var buffer = String.UnicodeScalarView()

        func flush() {
            guard !buffer.isEmpty else { return }
            var span = marks
            span.text = String(buffer)
            out.append(span)
            buffer = String.UnicodeScalarView()
        }

        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count, escapable.contains(s[i + 1]) {
                buffer.append(s[i + 1]); i += 2; continue
            }
            if c == "`", let k = find(s, "`", from: i + 1) {
                flush()
                var span = marks
                span.text = string(s[(i + 1)..<k])
                span.code = true
                out.append(span)
                i = k + 1; continue
            }
            if c == "[", let close = find(s, "](", from: i + 1), let end = find(s, ")", from: close + 2),
               !s[(close + 2)..<end].contains(" "), close > i + 1 {
                let url = string(s[(close + 2)..<end])
                flush()
                var inner = marks
                if schemes.contains(where: url.hasPrefix) { inner.link = url }
                out += inline(Array(s[(i + 1)..<close]), inner)
                i = end + 1; continue
            }
            if c == "h", hasPrefix(s, "http://", at: i) || hasPrefix(s, "https://", at: i),
               i == 0 || isSpace(s[i - 1]) || s[i - 1] == "(" {
                var j = i
                while j < s.count, !isSpace(s[j]) { j += 1 }
                var url = Array(s[i..<j])
                while let last = url.last, ".,;:!?)".unicodeScalars.contains(last) { url.removeLast() }
                if url.count > "https://".count {
                    flush()
                    var span = marks
                    span.text = string(url)
                    span.link = span.text
                    out.append(span)
                    i += url.count; continue
                }
            }
            var handled = false
            for (token, bold, italic, strike) in emphasis {
                let tok = Array(token.unicodeScalars)
                guard hasPrefix(s, token, at: i) else { continue }
                let n = tok.count
                if i + n >= s.count || isSpace(s[i + n]) { break }
                if tok[0] == "_", i > 0, isAlnum(s[i - 1]) { break }
                guard let k = findCloser(s, i, tok) else { break }
                flush()
                var inner = marks
                inner.bold = inner.bold || bold
                inner.italic = inner.italic || italic
                inner.strike = inner.strike || strike
                out += inline(Array(s[(i + n)..<k]), inner)
                i = k + n
                handled = true
                break
            }
            if handled { continue }
            // A run of marker characters that opened nothing stays literal as a whole.
            if "*_~".unicodeScalars.contains(c) {
                var j = i
                while j < s.count, s[j] == c { j += 1 }
                buffer.append(contentsOf: s[i..<j]); i = j; continue
            }
            buffer.append(c); i += 1
        }
        flush()
        return merge(out)
    }

    private static func findCloser(_ s: [Unicode.Scalar], _ i: Int, _ tok: [Unicode.Scalar]) -> Int? {
        let n = tok.count
        var k = find(s, tok, from: i + n)
        while let at = k {
            var ok = at > i + n && !isSpace(s[at - 1])
            if ok, n == 1 {
                ok = s[at - 1] != tok[0] && (at + 1 >= s.count || s[at + 1] != tok[0])
            }
            if ok, tok[0] == "_" {
                ok = at + n >= s.count || !isAlnum(s[at + n])
            }
            if ok { return at }
            k = find(s, tok, from: at + 1)
        }
        return nil
    }

    private static func merge(_ spans: [MarkdownSpan]) -> [MarkdownSpan] {
        var result: [MarkdownSpan] = []
        for span in spans where !span.text.isEmpty {
            if let last = result.last, last.sameMarks(span) {
                result[result.count - 1].text += span.text
            } else {
                result.append(span)
            }
        }
        return result
    }

    // MARK: Plain text (previews, the fallback)

    static func plain(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block in
            switch block {
            case .code(let text): text
            case .list(let ordered, let start, let items):
                items.enumerated().map { n, item in (ordered ? "\(start + n). " : "• ") + plain(item) }
                    .joined(separator: "\n")
            case .paragraph(let spans), .heading(let spans), .quote(let spans): plain(spans)
            }
        }
        .joined(separator: "\n\n")
    }

    /// Links as "text (url)" unless the text is the url (`mailto:` shows just the address).
    static func plain(_ spans: [MarkdownSpan]) -> String {
        var out = ""
        var k = 0
        while k < spans.count {
            guard let link = spans[k].link else {
                out += spans[k].text; k += 1; continue
            }
            var text = ""
            while k < spans.count, spans[k].link == link { text += spans[k].text; k += 1 }
            let shown = link.hasPrefix("mailto:") ? String(link.dropFirst("mailto:".count)) : link
            out += text == link || text == shown ? text : "\(text) (\(shown))"
        }
        return out
    }

    // MARK: Characters, as Python sees them

    /// `str.isspace()`.
    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c.properties.isWhitespace || (0x1C...0x1F).contains(c.value)
    }

    /// `str.isalnum()`: letters and numbers of any script.
    private static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: c.properties.numericType != nil
        }
    }

    /// `\d`: any script's decimal digit, and its value.
    private static func decimalDigit(_ c: Unicode.Scalar) -> Int? {
        guard c.properties.numericType == .decimal, let value = c.properties.numericValue else { return nil }
        return Int(value)
    }

    private static func strip(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = 0, end = s.count
        while start < end, isSpace(s[start]) { start += 1 }
        while end > start, isSpace(s[end - 1]) { end -= 1 }
        return Array(s[start..<end])
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func hasPrefix(_ s: [Unicode.Scalar], _ prefix: String, at i: Int = 0) -> Bool {
        let p = Array(prefix.unicodeScalars)
        guard i >= 0, i + p.count <= s.count else { return false }
        return Array(s[i..<(i + p.count)]) == p
    }

    private static func find(_ s: [Unicode.Scalar], _ needle: String, from start: Int) -> Int? {
        find(s, Array(needle.unicodeScalars), from: start)
    }

    /// Python's `str.find`: the first index at or after `start`, or nil.
    private static func find(_ s: [Unicode.Scalar], _ needle: [Unicode.Scalar], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0 else { return nil }
        var i = start
        while i + needle.count <= s.count {
            if s[i] == needle[0], Array(s[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}
