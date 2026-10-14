import Foundation
import GRDB
import UniformTypeIdentifiers

public enum SegmentChannel: String, Codable, Sendable {
    case mic
    case system
}

/// Where a meeting is in the capture → transcription pipeline.
public enum ProcessingStatus: String, Codable, Sendable {
    case recording
    /// Audio on disk, waiting for transcription.
    case recorded
    case processing
    case done
    case failed
}

/// Free-form labels ("daily", "1on1", "acao") instead of fixed categories, so
/// new kinds of meetings and notes never need a schema change. In text they
/// are written as hashtags.
public enum Tags {
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.matches(of: /#([\p{L}\p{N}_-]+)/).compactMap { match in
            let tag = String(match.output.1).lowercased()
            return seen.insert(tag).inserted ? tag : nil
        }
    }
}

public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var tags: [String]
    /// What recorded it ("meet", "manual"); free-form for future sources.
    public var source: String?
    /// When the audio files actually start: the zero of every segment and
    /// note timestamp, which can lag `startedAt` by a few seconds.
    public var audioStartedAt: Date?
    public var audioMicPath: String?
    public var audioSystemPath: String?
    public var status: ProcessingStatus
    public var statusDetail: String?

    public init(
        id: Int64? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String,
        tags: [String] = [],
        source: String? = nil,
        audioStartedAt: Date? = nil,
        audioMicPath: String? = nil,
        audioSystemPath: String? = nil,
        status: ProcessingStatus = .recording,
        statusDetail: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.tags = tags
        self.source = source
        self.audioStartedAt = audioStartedAt
        self.audioMicPath = audioMicPath
        self.audioSystemPath = audioSystemPath
        self.status = status
        self.statusDetail = statusDetail
    }

    /// Milliseconds from the start of the audio to `date`.
    public func audioOffsetMs(at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(audioStartedAt ?? startedAt) * 1000))
    }

    /// The wall-clock moment of an offset in the audio.
    public func date(atOffsetMs ms: Int) -> Date {
        (audioStartedAt ?? startedAt).addingTimeInterval(Double(ms) / 1000)
    }
}

extension Meeting: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "meeting"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Person: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

extension Person: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "person"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One sample of a person's voice. A person accumulates several (different
/// days, mics, rooms); matching against all of them is far more robust than
/// against a single stored embedding.
public struct Voiceprint: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var personId: Int64
    public var meetingId: Int64?
    public var embedding: Data
    public var createdAt: Date

    public init(id: Int64? = nil, personId: Int64, meetingId: Int64?, embedding: Data, createdAt: Date) {
        self.id = id
        self.personId = personId
        self.meetingId = meetingId
        self.embedding = embedding
        self.createdAt = createdAt
    }
}

extension Voiceprint: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "voiceprint"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A voice heard in one meeting (a diarization cluster), possibly already
/// identified as a known person.
public struct MeetingSpeaker: Codable, Equatable, Sendable {
    public var meetingId: Int64
    public var personId: Int64?
    public var diarCluster: Int
    public var embedding: Data?
    public var speechMs: Int
    public var lang: String?

    public init(
        meetingId: Int64,
        personId: Int64? = nil,
        diarCluster: Int,
        embedding: Data? = nil,
        speechMs: Int = 0,
        lang: String? = nil
    ) {
        self.meetingId = meetingId
        self.personId = personId
        self.diarCluster = diarCluster
        self.embedding = embedding
        self.speechMs = speechMs
        self.lang = lang
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
    /// Mean token probability from the recognizer (0...1); low values are
    /// highlighted for review.
    public var confidence: Double?

    public init(
        id: Int64? = nil,
        meetingId: Int64,
        tStartMs: Int,
        tEndMs: Int,
        channel: SegmentChannel,
        diarCluster: Int? = nil,
        personId: Int64? = nil,
        lang: String? = nil,
        text: String,
        confidence: Double? = nil
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
        self.confidence = confidence
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
    public var text: String
    public var tags: [String]
    public var resolvedAt: Date?

    public init(
        id: Int64? = nil,
        meetingId: Int64,
        tMs: Int,
        text: String,
        tags: [String]? = nil,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.tMs = tMs
        self.text = text
        self.tags = tags ?? Tags.parse(text)
        self.resolvedAt = resolvedAt
    }
}

extension Note: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A text about a whole meeting, such as its summary. `kind` is free-form
/// ("summary", "minutes"), at most one per meeting.
public struct MeetingDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var meetingId: Int64
    public var kind: String
    public var body: String
    /// What wrote it ("claude", "manual").
    public var source: String?
    public var updatedAt: Date

    public init(id: Int64? = nil, meetingId: Int64, kind: String, body: String, source: String?, updatedAt: Date) {
        self.id = id
        self.meetingId = meetingId
        self.kind = kind
        self.body = body
        self.source = source
        self.updatedAt = updatedAt
    }
}

extension MeetingDocument: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "meetingDocument"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A file attached to a note, such as a print of the screen. `kind` is
/// free-form ("image", "file"); `path` is relative to the meeting directory.
public struct Attachment: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var noteId: Int64
    public var kind: String
    public var path: String
    public var createdAt: Date

    public init(id: Int64? = nil, noteId: Int64, kind: String, path: String, createdAt: Date) {
        self.id = id
        self.noteId = noteId
        self.kind = kind
        self.path = path
        self.createdAt = createdAt
    }

    /// "image" for pictures, "file" for anything else.
    public static func kind(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true ? "image" : "file"
    }
}

extension Attachment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "attachment"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An attachment where the app and clients find it on disk.
public struct NoteAttachment: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var noteId: Int64
    public var kind: String
    public var url: URL

    public init(id: Int64, noteId: Int64, kind: String, url: URL) {
        self.id = id
        self.noteId = noteId
        self.kind = kind
        self.url = url
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

/// Speaker embeddings travel as raw little-endian Float32 blobs.
public enum EmbeddingCodec {
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
