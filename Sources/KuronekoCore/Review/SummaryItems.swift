import Foundation

/// An item of a summary's "Pendências" or "Decisões" section. The summary
/// Markdown (written by Claude, edited by the user anywhere) is the source
/// of truth: items are read from it, and a pendência is checked off by
/// rewriting its checkbox.
public struct SummaryItem: Codable, Equatable, Sendable {
    /// From the section: "task" (Pendências) or "decision" (Decisões).
    public var kind: String
    public var text: String
    /// Who, written after " — ".
    public var owner: String?
    /// The first [mm:ss] or [h:mm:ss] of the line.
    public var startMs: Int?
    public var done: Bool
    /// Index of the line in the Markdown, from 0.
    public var line: Int

    public init(kind: String, text: String, owner: String? = nil, startMs: Int? = nil, done: Bool = false, line: Int) {
        self.kind = kind
        self.text = text
        self.owner = owner
        self.startMs = startMs
        self.done = done
        self.line = line
    }

    /// Identifies the item across edits that move it to another line.
    public var fingerprint: String {
        // FNV-1a: stable across runs, unlike hashValue.
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }
}

/// Reads the items leniently: headings with or without `#` (or in bold),
/// bullets `- [ ]`, `- [x]`, `- `, `* `, `1.`; nested bullets are details of
/// the item above, not items.
public enum SummaryItems {
    /// Heading prefixes (accents and case ignored) and the kind of their items.
    static let kinds: [(prefix: String, kind: String)] = [
        ("pendencia", "task"), ("tarefa", "task"), ("acoes", "task"), ("proximos passos", "task"),
        ("action item", "task"), ("to-do", "task"), ("todo", "task"),
        ("decis", "decision"),
    ]
    /// Section names that make a heading even without `#`, as a bare or
    /// bold line ("Pendências:"); the other sections close the one above.
    static let bareHeadings: Set = [
        "pendencias", "pendencia", "tarefas", "acoes", "proximos passos", "decisoes", "decisao",
        "resumo", "minhas notas", "notas", "pontos em aberto",
    ]

    public static func parse(_ markdown: String) -> [SummaryItem] {
        var items: [SummaryItem] = []
        var kind: String?
        var section: [(indent: Int, item: SummaryItem)] = []
        func flush() {
            let top = section.map(\.indent).min()
            items += section.filter { $0.indent == top }.map(\.item)
            section = []
        }
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let title = heading(line) {
                flush()
                kind = kinds.first { title.hasPrefix($0.prefix) }?.kind
                continue
            }
            guard let kind, let bullet = bullet(line), let item = item(bullet.content, kind: kind, done: bullet.done, line: index) else {
                continue
            }
            section.append((bullet.indent, item))
        }
        flush()
        return items
    }

    /// The Markdown with the checkbox of that line checked or unchecked
    /// (added when the bullet has none), every other byte untouched; nil
    /// when the line is not a bullet.
    public static func setDone(_ done: Bool, line: Int, in markdown: String) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(line), let match = lines[line].firstMatch(of: boxPattern) else { return nil }
        let box = done ? "[x]" : "[ ]"
        let rest = lines[line][match.range.upperBound...]
        lines[line] = String(match.output.1) + (match.output.2 == nil ? "\(box) " : box) + String(rest)
        return lines.joined(separator: "\n")
    }

    // MARK: - Lines

    nonisolated(unsafe) private static let bulletPattern = /^([ \t]*)(?:[-*+]|[0-9]+[.)])[ \t]+(?:\[([ xX]?)\][ \t]*)?(.*)$/
    nonisolated(unsafe) private static let boxPattern = /^([ \t]*(?:[-*+]|[0-9]+[.)])[ \t]+)(\[[ xX]?\])?/
    /// A bracket holding only times: [12:31], [1:02:03], [12:31–13:02].
    nonisolated(unsafe) private static let timesPattern = /[ \t]*\[([0-9:,;– \-]*[0-9]:[0-9]{2}[0-9:,;– \-]*)\]/
    nonisolated(unsafe) private static let timePattern = /(?:[0-9]+:)?[0-9]+:[0-9]{2}/

    /// The title of a heading line, folded ("pendencias"), or nil.
    static func heading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let title = fold(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*_: \t")))
        if trimmed.firstMatch(of: /^#{1,6}(?:[ \t]|$)/) != nil {
            return title
        }
        return bullet(line) == nil && bareHeadings.contains(title) ? title : nil
    }

    static func bullet(_ line: String) -> (indent: Int, done: Bool, content: String)? {
        guard let match = line.firstMatch(of: bulletPattern) else { return nil }
        let indent = match.output.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let done = match.output.2.map { $0.lowercased() == "x" } ?? false
        return (indent, done, String(match.output.3))
    }

    static func item(_ content: String, kind: String, done: Bool, line: Int) -> SummaryItem? {
        let startMs = content.firstMatch(of: timesPattern)
            .flatMap { $0.output.1.firstMatch(of: timePattern) }
            .flatMap { ClockTime.parse(String($0.output)) }
        var text = content.replacing(timesPattern, with: "")
        var owner: String?
        if let separator = text.ranges(of: " — ").last ?? text.ranges(of: " – ").last {
            owner = clean(String(text[separator.upperBound...]))
            text = String(text[..<separator.lowerBound])
        }
        text = clean(text).trimmingCharacters(in: CharacterSet(charactersIn: " —–"))
        // "- Nenhuma pendência." is not an item.
        guard !text.isEmpty, startMs != nil || !fold(text).hasPrefix("nenhum") else { return nil }
        return SummaryItem(kind: kind, text: text, owner: owner?.isEmpty == false ? owner : nil, startMs: startMs, done: done, line: line)
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}
