import Foundation

/// What the review screen shows for a meeting: speech grouped into blocks
/// per speaker, with the user's notes placed where they were taken.
public enum TimelineEntry: Equatable, Sendable, Identifiable {
    case speech(SpeechBlock)
    case note(Note)

    public var id: String {
        switch self {
        case .speech(let block): "s\(block.segments.first?.id ?? 0)-\(block.startMs)"
        case .note(let note): "n\(note.id ?? 0)-\(note.tMs)"
        }
    }

    public var startMs: Int {
        switch self {
        case .speech(let block): block.startMs
        case .note(let note): note.tMs
        }
    }
}

public struct SpeechBlock: Equatable, Sendable {
    /// "me" for the mic channel, "c<cluster>" for a voice of the call.
    public var speakerKey: String
    public var segments: [Segment]

    public var startMs: Int { segments.first?.tStartMs ?? 0 }
    public var endMs: Int { segments.last?.tEndMs ?? 0 }

    public static func key(for segment: Segment) -> String {
        segment.channel == .mic ? "me" : "c\(segment.diarCluster ?? -1)"
    }
}

public enum Timeline {
    /// Consecutive segments of one speaker form a block until someone else
    /// speaks or the speaker pauses for longer than `maxPauseMs`.
    public static func entries(segments: [Segment], notes: [Note], maxPauseMs: Int = 4000) -> [TimelineEntry] {
        var blocks: [SpeechBlock] = []
        for segment in segments.sorted(by: { $0.tStartMs < $1.tStartMs }) {
            let key = SpeechBlock.key(for: segment)
            if var last = blocks.last, last.speakerKey == key, segment.tStartMs - last.endMs <= maxPauseMs {
                last.segments.append(segment)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(SpeechBlock(speakerKey: key, segments: [segment]))
            }
        }
        let speech = blocks.map(TimelineEntry.speech)
        let placed = notes.map(TimelineEntry.note)
        // A note taken mid-block goes after that block, not inside it.
        return (speech + placed).sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if case .speech = lhs { return true }
            return false
        }
    }
}

/// What was being said when a note was taken, so the subject can be found
/// and heard again from the note.
public struct NoteContext: Equatable, Sendable {
    /// The voice that spoke the most right before the note, and what it said.
    public var block: SpeechBlock

    /// Where to start listening to the subject.
    public var playFromMs: Int { block.startMs }

    /// The end of what was said, the part closest to the note, cut at a
    /// word: "…migrar o banco até sexta".
    public func excerpt(maxLength: Int = 160) -> String {
        let said = block.segments.map(\.text).joined(separator: " ")
        guard said.count > maxLength else { return said }
        // One extra character tells whether the cut fell on a word start.
        let tail = said.suffix(maxLength + 1)
        let fromWord = tail.firstIndex(of: " ").map { tail[tail.index(after: $0)...] } ?? tail.dropFirst()
        return "…" + fromWord
    }
}

extension Timeline {
    /// A note comes right after hearing something; half a minute back
    /// covers the sentence that prompted it.
    public static let noteLookbackMs = 30_000
    /// The note is stamped when the user starts writing it, and the person
    /// usually keeps talking about the subject meanwhile.
    static let noteGraceMs = 10_000

    public static func context(forNoteAtMs tMs: Int, segments: [Segment]) -> NoteContext? {
        let from = tMs - noteLookbackMs, to = tMs + noteGraceMs
        let recent = segments
            .filter { $0.tEndMs > from && $0.tStartMs < to }
            .sorted { $0.tStartMs < $1.tStartMs }
        var speechMs: [String: Int] = [:]
        var lastStart: [String: Int] = [:]
        for segment in recent {
            let key = SpeechBlock.key(for: segment)
            speechMs[key, default: 0] += min(segment.tEndMs, to) - max(segment.tStartMs, from)
            lastStart[key] = segment.tStartMs
        }
        // Who held the floor; on a tie, who spoke last.
        guard let key = speechMs.keys.max(by: { (speechMs[$0]!, lastStart[$0]!) < (speechMs[$1]!, lastStart[$1]!) }) else {
            return nil
        }
        return NoteContext(block: SpeechBlock(speakerKey: key, segments: recent.filter { SpeechBlock.key(for: $0) == key }))
    }
}

public enum WeekGrouping {
    public struct Group: Equatable, Sendable {
        public var title: String
        public var meetings: [Meeting]
    }

    /// Meetings newest first, grouped by calendar week.
    public static func group(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let sorted = meetings.sorted { $0.startedAt > $1.startedAt }
        var groups: [Group] = []
        var currentWeek: Date?
        for meeting in sorted {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: meeting.startedAt)?.start else { continue }
            if week != currentWeek {
                groups.append(Group(title: title(forWeekStarting: week, now: now, calendar: calendar), meetings: []))
                currentWeek = week
            }
            groups[groups.count - 1].meetings.append(meeting)
        }
        return groups
    }

    static func title(forWeekStarting week: Date, now: Date, calendar: Calendar) -> String {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return "" }
        if week == thisWeek { return "Esta semana" }
        if let last = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), week == last {
            return "Semana passada"
        }
        let end = calendar.date(byAdding: .day, value: 6, to: week) ?? week
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return "\(formatter.string(from: week)) – \(formatter.string(from: end))"
    }
}

public struct SearchHit: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case speech(SegmentChannel, diarCluster: Int?, personId: Int64?)
        case note
    }

    public var meetingId: Int64
    public var tMs: Int
    public var text: String
    public var kind: Kind

    public var id: String { "\(meetingId)-\(tMs)-\(text.hashValue)" }
}
