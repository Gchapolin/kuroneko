import Foundation

/// What the top of a meeting shows from its summary besides the pendências
/// and decisões (`SummaryItems`) and the user's notes (the real ones, not
/// Claude's retelling): the opening text and any other section, such as
/// "Pontos em aberto".
public struct SummaryOverview: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        /// As written, accents and all.
        public var title: String
        /// Kind "other": text, owner and time read like a pendência's.
        public var items: [SummaryItem]

        public init(title: String, items: [SummaryItem]) {
            self.title = title
            self.items = items
        }
    }

    /// Paragraphs of the "Resumo" section (or of the text before the first
    /// heading), times like [12:31] taken out; inline Markdown kept.
    public var intro: [String]
    public var sections: [Section]

    public init(intro: [String] = [], sections: [Section] = []) {
        self.intro = intro
        self.sections = sections
    }

    public var isEmpty: Bool {
        intro.isEmpty && sections.isEmpty
    }

    /// Sections the meeting screen shows its own way.
    static let shownElsewhere = ["minhas notas", "notas"]

    nonisolated(unsafe) private static let timesPattern = /[ \t]*\[[0-9:,;– \-]*[0-9]:[0-9]{2}[0-9:,;– \-]*\]/

    public static func parse(_ markdown: String) -> SummaryOverview {
        enum Target {
            case intro, skip
            case section(Int)
        }
        var intro: [String] = []
        var paragraph: [String] = []
        var sections: [Section] = []
        var bullets: [(indent: Int, item: SummaryItem)] = []
        var target = Target.intro
        var seenText = false

        func endParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { intro.append(text) }
            paragraph = []
        }
        func endSection() {
            guard case .section(let index) = target else { return }
            // Nested bullets are details of the one above, as in `SummaryItems`.
            let top = bullets.map(\.indent).min()
            sections[index].items = bullets.filter { $0.indent == top }.map(\.item)
            bullets = []
        }

        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let title = SummaryItems.heading(line) {
                endParagraph()
                endSection()
                let isDocumentTitle = !seenText && trimmed.hasPrefix("# ")
                seenText = true
                if title.hasPrefix("resumo") {
                    target = .intro
                } else if SummaryItems.kinds.contains(where: { title.hasPrefix($0.prefix) }) || shownElsewhere.contains(title) {
                    target = .skip
                } else if isDocumentTitle {
                    target = .intro
                } else {
                    sections.append(Section(title: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*_: \t")), items: []))
                    target = .section(sections.count - 1)
                }
                continue
            }
            if !trimmed.isEmpty { seenText = true }
            switch target {
            case .skip:
                continue
            case .intro:
                if trimmed.isEmpty {
                    endParagraph()
                    continue
                }
                var text = trimmed.replacing(timesPattern, with: "")
                if let bullet = SummaryItems.bullet(line) {
                    endParagraph()
                    text = "• " + bullet.content.replacing(timesPattern, with: "")
                }
                paragraph.append(text)
                if text.hasPrefix("• ") { endParagraph() }
            case .section:
                guard !trimmed.isEmpty else { continue }
                let bullet = SummaryItems.bullet(line) ?? (indent: 0, done: false, content: trimmed)
                if let item = SummaryItems.item(bullet.content, kind: "other", done: bullet.done, line: index) {
                    bullets.append((bullet.indent, item))
                }
            }
        }
        endParagraph()
        endSection()
        return SummaryOverview(intro: intro, sections: sections.filter { !$0.items.isEmpty })
    }
}

extension AppDatabase {
    /// Pendências of one meeting, its summary's and its #acao notes, in the
    /// order of the recording.
    public func tasks(meetingId: Int64) throws -> [TaskItem] {
        guard let meeting = try meeting(id: meetingId) else { return [] }
        var tasks: [TaskItem] = []
        if let summary = try documents(meetingId: meetingId).first(where: { $0.kind == "summary" }) {
            tasks += SummaryItems.parse(summary.body)
                .filter { $0.kind == "task" }
                .map { TaskItem(summaryItem: $0, meeting: meeting, updatedAt: summary.updatedAt) }
        }
        tasks += try notes(meetingId: meetingId)
            .filter { $0.tags.contains(TaskItem.noteTag) }
            .map { TaskItem(note: $0, meeting: meeting) }
        return tasks.sorted(by: TaskItem.order)
    }
}
