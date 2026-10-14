import Foundation

/// Which pendência to check off: a line of a meeting's summary
/// ("summary:12:7:9f86d081" — meeting, line, fingerprint of the text, so an
/// edit that moved the line still finds it) or a #acao note ("note:45").
public enum TaskRef: Hashable, Sendable, LosslessStringConvertible {
    case summary(meetingId: Int64, line: Int, fingerprint: String)
    case note(id: Int64)

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        switch parts.first {
        case "summary" where parts.count == 4:
            guard let meetingId = Int64(parts[1]), let line = Int(parts[2]), line >= 0, !parts[3].isEmpty else { return nil }
            self = .summary(meetingId: meetingId, line: line, fingerprint: String(parts[3]))
        case "note" where parts.count == 2:
            guard let id = Int64(parts[1]) else { return nil }
            self = .note(id: id)
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .summary(let meetingId, let line, let fingerprint): "summary:\(meetingId):\(line):\(fingerprint)"
        case .note(let id): "note:\(id)"
        }
    }
}

/// A pendência of any meeting: a line of the "Pendências" of its summary or
/// a note tagged #acao.
public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
    /// Notes with this tag are pendências of the user.
    public static let noteTag = "acao"

    /// `TaskRef` as text, for `setTaskDone` and `kuroneko task done`.
    public var ref: String
    /// "summary" or "note".
    public var source: String
    public var meetingId: Int64
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var text: String
    /// As written in the summary; "você" for the user's own notes.
    public var owner: String?
    /// Moment of the recording it came from.
    public var startMs: Int?
    public var done: Bool
    /// When a note was resolved; for a summary line, the last change to the
    /// summary (the line has no time of its own).
    public var doneAt: Date?

    public var id: String { ref }

    init(summaryItem item: SummaryItem, meeting: Meeting, updatedAt: Date) {
        ref = TaskRef.summary(meetingId: meeting.id ?? 0, line: item.line, fingerprint: item.fingerprint).description
        source = "summary"
        meetingId = meeting.id ?? 0
        meetingTitle = meeting.title
        meetingStartedAt = meeting.startedAt
        text = item.text
        owner = item.owner
        startMs = item.startMs
        done = item.done
        doneAt = item.done ? updatedAt : nil
    }

    init(note: Note, meeting: Meeting) {
        ref = TaskRef.note(id: note.id ?? 0).description
        source = "note"
        meetingId = meeting.id ?? 0
        meetingTitle = meeting.title
        meetingStartedAt = meeting.startedAt
        text = note.text
            .replacing(/(?i)#acao(?![\p{L}\p{N}_-])/, with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        owner = "você"
        startMs = note.tMs
        done = note.resolvedAt != nil
        doneAt = note.resolvedAt
    }

    /// Newest meeting first; inside a meeting, in the order of the recording.
    static func order(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.meetingStartedAt != rhs.meetingStartedAt { return lhs.meetingStartedAt > rhs.meetingStartedAt }
        if lhs.meetingId != rhs.meetingId { return lhs.meetingId > rhs.meetingId }
        let left = lhs.startMs ?? .max, right = rhs.startMs ?? .max
        if left != right { return left < right }
        return lhs.ref < rhs.ref
    }
}

public enum TaskError: Error, Equatable, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let ref): "pendência não encontrada: \(ref) (o resumo mudou?)"
        }
    }
}

extension AppDatabase {
    /// Pendências and decisões of the meeting's summary.
    public func summaryItems(meetingId: Int64) throws -> [SummaryItem] {
        try documents(meetingId: meetingId).first { $0.kind == "summary" }.map { SummaryItems.parse($0.body) } ?? []
    }

    /// Pendências of every meeting, done or not.
    public func tasks() throws -> [TaskItem] {
        let meetings = Dictionary(uniqueKeysWithValues: try meetings().compactMap { meeting in meeting.id.map { ($0, meeting) } })
        var tasks: [TaskItem] = []
        for document in try documents(kind: "summary") {
            guard let meeting = meetings[document.meetingId] else { continue }
            for item in SummaryItems.parse(document.body) where item.kind == "task" {
                tasks.append(TaskItem(summaryItem: item, meeting: meeting, updatedAt: document.updatedAt))
            }
        }
        for note in try notes(tagged: TaskItem.noteTag) {
            guard let meeting = meetings[note.meetingId] else { continue }
            tasks.append(TaskItem(note: note, meeting: meeting))
        }
        return tasks.sorted(by: TaskItem.order)
    }

    public func openTasks() throws -> [TaskItem] {
        try tasks().filter { !$0.done }
    }

    /// Checked off since `date`, most recent first.
    public func doneTasks(since date: Date) throws -> [TaskItem] {
        try tasks()
            .filter { $0.done && ($0.doneAt ?? .distantPast) >= date }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// Checks a pendência off (or back on): a summary line has its checkbox
    /// rewritten and the summary saved; a note gets `resolvedAt`.
    @discardableResult
    public func setTaskDone(_ ref: TaskRef, _ done: Bool, at date: Date = Date()) throws -> TaskItem {
        switch ref {
        case .note(let id):
            try setNoteResolved(id, done, at: date)
            guard let note = try note(id: id), let meeting = try meeting(id: note.meetingId) else {
                throw TaskError.notFound(ref.description)
            }
            return TaskItem(note: note, meeting: meeting)
        case .summary(let meetingId, let line, let fingerprint):
            var found: SummaryItem?
            let document = try updateDocument(meetingId: meetingId, kind: "summary", at: date) { body in
                let candidates = SummaryItems.parse(body).filter { $0.kind == "task" && $0.fingerprint == fingerprint }
                guard let item = candidates.first(where: { $0.line == line }) ?? candidates.first else { return nil }
                found = item
                return SummaryItems.setDone(done, line: item.line, in: body)
            }
            guard var item = found, let document, let meeting = try meeting(id: meetingId) else {
                throw TaskError.notFound(ref.description)
            }
            item.done = done
            return TaskItem(summaryItem: item, meeting: meeting, updatedAt: document.updatedAt)
        }
    }
}
