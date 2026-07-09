import Foundation
import GRDB

public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(DatabaseQueue(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("title", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("audioMicPath", .text)
                t.column("audioSystemPath", .text)
            }

            try db.create(table: "person") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("voiceEmbedding", .blob)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "meetingSpeaker") { t in
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.belongsTo("person", onDelete: .setNull)
                t.column("diarCluster", .integer).notNull()
                t.primaryKey(["meetingId", "diarCluster"])
            }

            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("tStartMs", .integer).notNull()
                t.column("tEndMs", .integer).notNull()
                t.column("channel", .text).notNull()
                t.column("diarCluster", .integer)
                t.belongsTo("person", onDelete: .setNull)
                t.column("lang", .text)
                t.column("text", .text).notNull()
            }

            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("tMs", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("resolvedAt", .datetime)
            }

            try db.create(table: "screenshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("tMs", .integer).notNull()
                t.column("imagePath", .text).notNull()
                t.column("caption", .text)
            }

            try db.create(virtualTable: "segmentFts", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .unicode61()
                t.column("text")
            }

            try db.create(virtualTable: "noteFts", using: FTS5()) { t in
                t.synchronize(withTable: "note")
                t.tokenizer = .unicode61()
                t.column("text")
            }
        }

        return migrator
    }

    // MARK: - Meetings

    @discardableResult
    public func startMeeting(title: String, kind: MeetingKind, at date: Date = Date()) throws -> Meeting {
        try writer.write { db in
            var meeting = Meeting(startedAt: date, title: title, kind: kind)
            try meeting.insert(db)
            return meeting
        }
    }

    public func endMeeting(_ id: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            meeting.endedAt = date
            try meeting.update(db)
        }
    }

    public func activeMeeting() throws -> Meeting? {
        try writer.read { db in
            try Meeting
                .filter(Column("endedAt") == nil)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }

    public func meetings() throws -> [Meeting] {
        try writer.read { db in
            try Meeting.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    public func deleteMeeting(_ id: Int64) throws {
        try writer.write { db in
            // Children are deleted explicitly instead of relying on the FK
            // cascade: SQLite only fires the FTS synchronization triggers on
            // direct deletes unless recursive_triggers is enabled, and the
            // cascade would leave stale rows behind in segmentFts/noteFts.
            try Segment.filter(Column("meetingId") == id).deleteAll(db)
            try Note.filter(Column("meetingId") == id).deleteAll(db)
            try Screenshot.filter(Column("meetingId") == id).deleteAll(db)
            try MeetingSpeaker.filter(Column("meetingId") == id).deleteAll(db)
            _ = try Meeting.deleteOne(db, key: id)
        }
    }

    // MARK: - Segments, notes, screenshots

    @discardableResult
    public func addSegment(
        meetingId: Int64,
        tStartMs: Int,
        tEndMs: Int,
        channel: SegmentChannel,
        lang: String? = nil,
        text: String
    ) throws -> Segment {
        try writer.write { db in
            var segment = Segment(
                meetingId: meetingId,
                tStartMs: tStartMs,
                tEndMs: tEndMs,
                channel: channel,
                lang: lang,
                text: text
            )
            try segment.insert(db)
            return segment
        }
    }

    @discardableResult
    public func addNote(meetingId: Int64, tMs: Int, kind: NoteKind, text: String) throws -> Note {
        try writer.write { db in
            var note = Note(meetingId: meetingId, tMs: tMs, kind: kind, text: text)
            try note.insert(db)
            return note
        }
    }

    @discardableResult
    public func addScreenshot(
        meetingId: Int64,
        tMs: Int,
        imagePath: String,
        caption: String? = nil
    ) throws -> Screenshot {
        try writer.write { db in
            var screenshot = Screenshot(meetingId: meetingId, tMs: tMs, imagePath: imagePath, caption: caption)
            try screenshot.insert(db)
            return screenshot
        }
    }

    public func segments(meetingId: Int64) throws -> [Segment] {
        try writer.read { db in
            try Segment
                .filter(Column("meetingId") == meetingId)
                .order(Column("tStartMs"))
                .fetchAll(db)
        }
    }

    public func notes(meetingId: Int64) throws -> [Note] {
        try writer.read { db in
            try Note
                .filter(Column("meetingId") == meetingId)
                .order(Column("tMs"))
                .fetchAll(db)
        }
    }

    public func screenshots(meetingId: Int64) throws -> [Screenshot] {
        try writer.read { db in
            try Screenshot
                .filter(Column("meetingId") == meetingId)
                .order(Column("tMs"))
                .fetchAll(db)
        }
    }

    // MARK: - Search

    public func searchSegments(_ query: String) throws -> [Segment] {
        try writer.read { db in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
            return try Segment.fetchAll(
                db,
                sql: """
                    SELECT segment.*
                    FROM segment
                    JOIN segmentFts ON segmentFts.rowid = segment.id
                    WHERE segmentFts MATCH ?
                    ORDER BY segment.meetingId, segment.tStartMs
                    """,
                arguments: [pattern]
            )
        }
    }

    public func searchNotes(_ query: String) throws -> [Note] {
        try writer.read { db in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
            return try Note.fetchAll(
                db,
                sql: """
                    SELECT note.*
                    FROM note
                    JOIN noteFts ON noteFts.rowid = note.id
                    WHERE noteFts MATCH ?
                    ORDER BY note.meetingId, note.tMs
                    """,
                arguments: [pattern]
            )
        }
    }
}
