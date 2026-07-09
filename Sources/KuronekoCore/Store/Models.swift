import Foundation
import GRDB

public enum MeetingKind: String, Codable, CaseIterable, Sendable {
    case daily
    case refinamento
    case planning
    case oneOnOne = "1on1"
    case outro

    public var label: String {
        switch self {
        case .daily: "Daily"
        case .refinamento: "Refinamento"
        case .planning: "Planning"
        case .oneOnOne: "1:1"
        case .outro: "Outra"
        }
    }
}

public enum SegmentChannel: String, Codable, Sendable {
    case mic
    case system
}

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case duvida
    case acao
    case nota

    public var label: String {
        switch self {
        case .duvida: "Dúvida"
        case .acao: "Ação"
        case .nota: "Nota"
        }
    }
}

public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var kind: MeetingKind
    public var audioMicPath: String?
    public var audioSystemPath: String?

    public init(
        id: Int64? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String,
        kind: MeetingKind,
        audioMicPath: String? = nil,
        audioSystemPath: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.kind = kind
        self.audioMicPath = audioMicPath
        self.audioSystemPath = audioSystemPath
    }
}

extension Meeting: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "meeting"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Person: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var voiceEmbedding: Data?
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, voiceEmbedding: Data? = nil, createdAt: Date) {
        self.id = id
        self.name = name
        self.voiceEmbedding = voiceEmbedding
        self.createdAt = createdAt
    }
}

extension Person: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "person"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct MeetingSpeaker: Codable, Equatable, Sendable {
    public var meetingId: Int64
    public var personId: Int64?
    public var diarCluster: Int

    public init(meetingId: Int64, personId: Int64? = nil, diarCluster: Int) {
        self.meetingId = meetingId
        self.personId = personId
        self.diarCluster = diarCluster
    }
}

extension MeetingSpeaker: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingSpeaker"
}

public struct Segment: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var meetingId: Int64
    public var tStartMs: Int
    public var tEndMs: Int
    public var channel: SegmentChannel
    public var diarCluster: Int?
    public var personId: Int64?
    public var lang: String?
    public var text: String

    public init(
        id: Int64? = nil,
        meetingId: Int64,
        tStartMs: Int,
        tEndMs: Int,
        channel: SegmentChannel,
        diarCluster: Int? = nil,
        personId: Int64? = nil,
        lang: String? = nil,
        text: String
    ) {
        self.id = id
        self.meetingId = meetingId
        self.tStartMs = tStartMs
        self.tEndMs = tEndMs
        self.channel = channel
        self.diarCluster = diarCluster
        self.personId = personId
        self.lang = lang
        self.text = text
    }
}

extension Segment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "segment"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var meetingId: Int64
    public var tMs: Int
    public var kind: NoteKind
    public var text: String
    public var resolvedAt: Date?

    public init(
        id: Int64? = nil,
        meetingId: Int64,
        tMs: Int,
        kind: NoteKind,
        text: String,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.tMs = tMs
        self.kind = kind
        self.text = text
        self.resolvedAt = resolvedAt
    }
}

extension Note: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Screenshot: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var meetingId: Int64
    public var tMs: Int
    public var imagePath: String
    public var caption: String?

    public init(
        id: Int64? = nil,
        meetingId: Int64,
        tMs: Int,
        imagePath: String,
        caption: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.tMs = tMs
        self.imagePath = imagePath
        self.caption = caption
    }
}

extension Screenshot: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "screenshot"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
