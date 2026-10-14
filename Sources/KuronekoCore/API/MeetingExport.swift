import Foundation

/// How a voice is called everywhere: "Você" for the mic, the person's name
/// once identified, "Pessoa N" until then.
public enum SpeakerLabel {
    public static func label(cluster: Int) -> String {
        "Pessoa \(cluster + 1)"
    }

    public static func name(key: String, personId: Int64?, persons: [Int64: String]) -> String {
        if key == "me" { return "Você" }
        if let personId, let name = persons[personId] { return name }
        return label(cluster: Int(key.dropFirst()) ?? 0)
    }
}

/// A meeting in a list, for pickers in any client.
public struct MeetingListItem: Codable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    /// "Esta semana", "Semana passada", "27 de set. – 3 de out.".
    public var week: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int?
    public var status: String
    public var tags: [String]
    public var people: [String]
    public var noteCount: Int
    /// Kinds of the texts attached to it, such as "summary".
    public var documents: [String]
    public var links: [MeetingExport.Link]
    /// Files attached to its notes (prints).
    public var attachmentCount: Int
}

/// Everything about one meeting, in the shape every client reads: the
/// `kuroneko` command prints it as JSON.
public struct MeetingExport: Codable, Equatable, Sendable {
    public struct Audio: Codable, Equatable, Sendable {
        public var system: String?
        public var mic: String?
    }

    public struct Voice: Codable, Equatable, Sendable {
        /// "me" or "c<cluster>", the same key used by timeline entries.
        public var key: String
        public var label: String
        public var name: String
        public var personId: Int64?
        public var speechMs: Int
        public var lang: String?
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var text: String
        public var confidence: Double?
    }

    /// What was being said when a note was taken.
    public struct Context: Codable, Equatable, Sendable {
        public var speaker: String
        public var name: String
        public var startMs: Int
        public var excerpt: String
    }

    /// A file attached to a note; `kind` is free-form ("image").
    public struct Attachment: Codable, Equatable, Sendable {
        public var id: Int64
        public var kind: String
        /// Absolute path.
        public var path: String
    }

    /// A block of speech ("speech") or a note ("note"), in time order;
    /// fields of the other type are absent.
    public struct Entry: Codable, Equatable, Sendable {
        public var type: String
        public var startMs: Int
        public var endMs: Int?
        public var text: String
        public var speaker: String?
        public var name: String?
        public var segments: [Segment]?
        public var noteId: Int64?
        /// Wall-clock moment of the note.
        public var at: Date?
        public var tags: [String]?
        public var context: Context?
        public var attachments: [Attachment]?
        /// When a note was marked done (a #acao note is a pendência).
        public var resolvedAt: Date?
    }

    public struct Link: Codable, Equatable, Sendable {
        public var id: Int64
        public var url: String
        public var title: String?
        /// The title, or a short name made from the URL ("PR #482").
        public var label: String
        public var createdAt: Date

        public init(_ link: MeetingLink) {
            id = link.id ?? 0
            url = link.url
            title = link.title
            label = link.label
            createdAt = link.createdAt
        }
    }

    public struct Document: Codable, Equatable, Sendable {
        public var kind: String
        public var body: String
        public var source: String?
        public var updatedAt: Date

        public init(_ document: MeetingDocument) {
            kind = document.kind
            body = document.body
            source = document.source
            updatedAt = document.updatedAt
        }
    }

    public var id: Int64
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int?
    public var status: String
    public var statusDetail: String?
    public var tags: [String]
    public var source: String?
    public var audio: Audio
    public var voices: [Voice]
    public var timeline: [Entry]
    public var documents: [Document]
    public var links: [Link]
}

extension AppDatabase {
    public func meetingList(now: Date = Date(), calendar: Calendar = .current) throws -> [MeetingListItem] {
        let people = try peopleByMeeting()
        let notes = try noteCounts()
        let documents = try documentKinds()
        let links = try linksByMeeting()
        let attachments = try attachmentCounts()
        return WeekGrouping.group(try meetings(), now: now, calendar: calendar).flatMap { group in
            group.meetings.compactMap { meeting -> MeetingListItem? in
                guard let id = meeting.id else { return nil }
                return MeetingListItem(
                    id: id,
                    title: meeting.title,
                    week: group.title,
                    startedAt: meeting.startedAt,
                    endedAt: meeting.endedAt,
                    durationMs: meeting.durationMs,
                    status: meeting.status.rawValue,
                    tags: meeting.tags,
                    people: people[id] ?? [],
                    noteCount: notes[id] ?? 0,
                    documents: documents[id] ?? [],
                    links: (links[id] ?? []).map(MeetingExport.Link.init),
                    attachmentCount: attachments[id] ?? 0
                )
            }
        }
    }

    public func export(meetingId: Int64) throws -> MeetingExport? {
        guard let meeting = try meeting(id: meetingId) else { return nil }
        let segments = try segments(meetingId: meetingId)
        let notes = try notes(meetingId: meetingId)
        let persons = Dictionary(uniqueKeysWithValues: try persons().compactMap { person in
            person.id.map { ($0, person.name) }
        })
        func name(_ key: String, _ personId: Int64?) -> String {
            SpeakerLabel.name(key: key, personId: personId, persons: persons)
        }

        var voices: [MeetingExport.Voice] = []
        let micSpeechMs = segments.filter { $0.channel == .mic }.reduce(0) { $0 + $1.tEndMs - $1.tStartMs }
        if micSpeechMs > 0 {
            voices.append(.init(key: "me", label: "Você", name: "Você", personId: nil, speechMs: micSpeechMs, lang: nil))
        }
        for speaker in try speakers(meetingId: meetingId) {
            let key = "c\(speaker.diarCluster)"
            voices.append(.init(
                key: key,
                label: SpeakerLabel.label(cluster: speaker.diarCluster),
                name: name(key, speaker.personId),
                personId: speaker.personId,
                speechMs: speaker.speechMs,
                lang: speaker.lang
            ))
        }

        let attachments = try attachments(meetingId: meetingId)
        let timeline = Timeline.entries(segments: segments, notes: notes, attachments: attachments).map { entry -> MeetingExport.Entry in
            switch entry {
            case .speech(let block):
                return .init(
                    type: "speech",
                    startMs: block.startMs,
                    endMs: block.endMs,
                    text: block.segments.map(\.text).joined(separator: " "),
                    speaker: block.speakerKey,
                    name: name(block.speakerKey, block.segments.first?.personId),
                    segments: block.segments.map { .init(startMs: $0.tStartMs, endMs: $0.tEndMs, text: $0.text, confidence: $0.confidence) }
                )
            case .note(let note, let files):
                let context = Timeline.context(forNoteAtMs: note.tMs, segments: segments).map { context in
                    MeetingExport.Context(
                        speaker: context.block.speakerKey,
                        name: name(context.block.speakerKey, context.block.segments.first?.personId),
                        startMs: context.playFromMs,
                        excerpt: context.excerpt()
                    )
                }
                return .init(
                    type: "note",
                    startMs: note.tMs,
                    text: note.text,
                    noteId: note.id,
                    at: meeting.date(atOffsetMs: note.tMs),
                    tags: note.tags,
                    context: context,
                    attachments: files.map { .init(id: $0.id, kind: $0.kind, path: $0.url.path) },
                    resolvedAt: note.resolvedAt
                )
            }
        }

        return MeetingExport(
            id: meetingId,
            title: meeting.title,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            durationMs: meeting.durationMs,
            status: meeting.status.rawValue,
            statusDetail: meeting.statusDetail,
            tags: meeting.tags,
            source: meeting.source,
            audio: .init(system: meeting.audioSystemPath, mic: meeting.audioMicPath),
            voices: voices,
            timeline: timeline,
            documents: try documents(meetingId: meetingId).map(MeetingExport.Document.init),
            links: try links(meetingId: meetingId).map(MeetingExport.Link.init)
        )
    }
}

extension Meeting {
    public var durationMs: Int? {
        endedAt.map { Int($0.timeIntervalSince(startedAt) * 1000) }
    }
}
