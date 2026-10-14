import Foundation
import GRDB

public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter
    /// Where the files some rows point to live (attachments, audio).
    public let storage: MeetingStorage

    public init(_ writer: any DatabaseWriter, storage: MeetingStorage) throws {
        self.writer = writer
        self.storage = storage
        try Self.migrator.migrate(writer)
    }

    public static func open(_ storage: MeetingStorage) throws -> AppDatabase {
        let url = storage.databaseURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The app and the `kuroneko` command write to the same file; a
        // writer waits for the other instead of failing with SQLITE_BUSY.
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        return try AppDatabase(DatabaseQueue(path: url.path, configuration: configuration), storage: storage)
    }

    public static func inMemory(storage: MeetingStorage = .temporary()) throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(), storage: storage)
    }

    static var migrator: DatabaseMigrator {
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

        migrator.registerMigration("v2") { db in
            // Fixed meeting/note kinds become free tags; the old kind is kept
            // as the first tag.
            try db.alter(table: "meeting") { t in
                t.add(column: "tags", .text).notNull().defaults(to: "[]")
                t.add(column: "source", .text)
                t.add(column: "audioStartedAt", .datetime)
                t.add(column: "status", .text).notNull().defaults(to: ProcessingStatus.recorded.rawValue)
                t.add(column: "statusDetail", .text)
            }
            try db.execute(sql: "UPDATE meeting SET tags = json_array(kind)")
            try db.execute(
                sql: "UPDATE meeting SET status = ? WHERE audioSystemPath IS NULL AND audioMicPath IS NULL",
                arguments: [ProcessingStatus.done.rawValue]
            )
            try db.alter(table: "meeting") { t in t.drop(column: "kind") }

            try db.alter(table: "note") { t in
                t.add(column: "tags", .text).notNull().defaults(to: "[]")
            }
            try db.execute(sql: "UPDATE note SET tags = json_array(kind)")
            try db.alter(table: "note") { t in t.drop(column: "kind") }

            // A single embedding per person is replaced by many voiceprints.
            try db.alter(table: "person") { t in t.drop(column: "voiceEmbedding") }
            try db.create(table: "voiceprint") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("person", onDelete: .cascade).notNull()
                t.belongsTo("meeting", onDelete: .setNull)
                t.column("embedding", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.alter(table: "meetingSpeaker") { t in
                t.add(column: "embedding", .blob)
                t.add(column: "speechMs", .integer).notNull().defaults(to: 0)
                t.add(column: "lang", .text)
            }
            try db.alter(table: "segment") { t in
                t.add(column: "confidence", .double)
            }
        }

        migrator.registerMigration("v3") { db in
            // Texts about a whole meeting (a summary, minutes); the kind is
            // free-form, one text per kind.
            try db.create(table: "meetingDocument") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("body", .text).notNull()
                t.column("source", .text)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["meetingId", "kind"])
            }
        }

        migrator.registerMigration("v4") { db in
            // Files attached to notes (prints of the screen); the kind is
            // free-form and the path relative to the meeting directory.
            try db.create(table: "attachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("note", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v5") { db in
            // Links about a meeting (a PR, a ticket, a doc).
            try db.create(table: "meetingLink") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "newsAt", .datetime)
            }
        }

        return migrator
    }

    // MARK: - Meetings

    @discardableResult
    public func startMeeting(
        title: String,
        tags: [String] = [],
        source: String? = nil,
        at date: Date = Date()
    ) throws -> Meeting {
        try writer.write { db in
            var meeting = Meeting(startedAt: date, title: title, tags: tags, source: source)
            try meeting.insert(db)
            return meeting
        }
    }

    /// Ends the meeting and queues it for transcription when it has audio.
    public func endMeeting(_ id: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            meeting.endedAt = date
            let hasAudio = meeting.audioSystemPath != nil || meeting.audioMicPath != nil
            meeting.status = hasAudio ? .recorded : .done
            try meeting.update(db)
        }
    }

    public func updateAudio(meetingId: Int64, startedAt: Date, micPath: String?, systemPath: String?) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
            meeting.audioStartedAt = startedAt
            meeting.audioMicPath = micPath
            meeting.audioSystemPath = systemPath
            try meeting.update(db)
        }
    }

    /// The mic can join a recording late (plugged in mid-call).
    public func updateMicPath(meetingId: Int64, micPath: String) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
            meeting.audioMicPath = micPath
            try meeting.update(db)
        }
    }

    public func setStatus(_ status: ProcessingStatus, detail: String? = nil, meetingId: Int64) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
            meeting.status = status
            meeting.statusDetail = detail
            try meeting.update(db)
        }
    }

    public func renameMeeting(_ id: Int64, title: String) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            meeting.title = title
            meeting.tags = Array(Set(meeting.tags + Tags.parse(title))).sorted()
            try meeting.update(db)
        }
    }

    public func meeting(id: Int64) throws -> Meeting? {
        try writer.read { db in try Meeting.fetchOne(db, key: id) }
    }

    /// Ended meetings whose audio still needs transcription, oldest first.
    /// `processing` is included: it means the app quit mid-run.
    public func meetingsToProcess() throws -> [Meeting] {
        try writer.read { db in
            try Meeting
                .filter([ProcessingStatus.recorded.rawValue, ProcessingStatus.processing.rawValue]
                    .contains(Column("status")))
                .filter(Column("endedAt") != nil)
                .order(Column("startedAt"))
                .fetchAll(db)
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

    /// Something new about the meeting is waiting for the user.
    public func markNews(meetingId: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            _ = try Meeting.filter(key: meetingId).updateAll(db, Column("newsAt").set(to: date))
        }
    }

    /// The user opened the meeting.
    public func markSeen(meetingId: Int64) throws {
        try writer.write { db in
            _ = try Meeting.filter(key: meetingId).updateAll(db, Column("newsAt").set(to: nil))
        }
    }

    /// Meetings with news, latest news first.
    public func meetingsWithNews() throws -> [Meeting] {
        try writer.read { db in
            try Meeting.filter(Column("newsAt") != nil).order(Column("newsAt").desc).fetchAll(db)
        }
    }

    public func meetings() throws -> [Meeting] {
        try writer.read { db in
            try Meeting.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    /// Deletes the meeting with everything about it, its directory (audio,
    /// attachments) included.
    public func deleteMeeting(_ id: Int64) throws {
        try writer.write { db in
            // Children are deleted explicitly instead of relying on the FK
            // cascade: SQLite only fires the FTS synchronization triggers on
            // direct deletes unless recursive_triggers is enabled, and the
            // cascade would leave stale rows behind in segmentFts/noteFts.
            try Segment.filter(Column("meetingId") == id).deleteAll(db)
            try db.execute(
                sql: "DELETE FROM attachment WHERE noteId IN (SELECT id FROM note WHERE meetingId = ?)",
                arguments: [id]
            )
            try Note.filter(Column("meetingId") == id).deleteAll(db)
            try Screenshot.filter(Column("meetingId") == id).deleteAll(db)
            try MeetingSpeaker.filter(Column("meetingId") == id).deleteAll(db)
            try MeetingDocument.filter(Column("meetingId") == id).deleteAll(db)
            try MeetingLink.filter(Column("meetingId") == id).deleteAll(db)
            _ = try Meeting.deleteOne(db, key: id)
        }
        removeFiles([storage.meetingDirectory(id: id)])
    }

    /// Files are removed only after their rows are gone; one already
    /// missing is fine, any other failure is logged.
    private func removeFiles(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                FileLog.shared.append("arquivos: falha ao apagar \(url.path): \(error)")
            }
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

    /// A note, optionally with files attached (prints of the screen): each
    /// file is moved into the meeting's attachments directory. The text may
    /// be empty when there is at least one file.
    @discardableResult
    public func addNote(meetingId: Int64, tMs: Int, text: String, attachments files: [URL] = [], at date: Date = Date()) throws -> Note {
        var moved: [(from: URL, to: URL)] = []
        do {
            if !files.isEmpty {
                try FileManager.default.createDirectory(
                    at: storage.attachmentsDirectory(meetingId: meetingId),
                    withIntermediateDirectories: true
                )
            }
            for file in files {
                let name = UUID().uuidString + (file.pathExtension.isEmpty ? "" : ".\(file.pathExtension.lowercased())")
                let destination = storage.attachmentsDirectory(meetingId: meetingId).appendingPathComponent(name)
                try FileManager.default.moveItem(at: file, to: destination)
                moved.append((file, destination))
            }
            return try writer.write { db in
                var note = Note(meetingId: meetingId, tMs: tMs, text: text)
                try note.insert(db)
                for file in moved {
                    var attachment = Attachment(
                        noteId: note.id!,
                        kind: Attachment.kind(of: file.to),
                        path: "attachments/\(file.to.lastPathComponent)",
                        createdAt: date
                    )
                    try attachment.insert(db)
                }
                return note
            }
        } catch {
            // The captures go back where they were rather than being lost.
            for file in moved {
                try? FileManager.default.moveItem(at: file.to, to: file.from)
            }
            throw error
        }
    }

    /// Deletes the note with its attachments, rows and files.
    public func deleteNote(_ id: Int64) throws {
        let files = try writer.write { db -> [URL] in
            guard let note = try Note.fetchOne(db, key: id) else { return [] }
            let attachments = try Attachment.filter(Column("noteId") == id).fetchAll(db)
            try Attachment.filter(Column("noteId") == id).deleteAll(db)
            _ = try Note.deleteOne(db, key: id)
            return attachments.map { storage.file(meetingId: note.meetingId, path: $0.path) }
        }
        removeFiles(files)
    }

    public func note(id: Int64) throws -> Note? {
        try writer.read { db in try Note.fetchOne(db, key: id) }
    }

    /// Notes of every meeting carrying the tag (without the #).
    public func notes(tagged tag: String) throws -> [Note] {
        try writer.read { db in
            try Note.fetchAll(db, sql: """
                SELECT note.* FROM note
                WHERE EXISTS (SELECT 1 FROM json_each(note.tags) WHERE value = ?)
                ORDER BY note.meetingId, note.tMs
                """, arguments: [tag])
        }
    }

    /// Done (a #acao note is a pendência) or not done.
    public func setNoteResolved(_ id: Int64, _ resolved: Bool, at date: Date = Date()) throws {
        try writer.write { db in
            guard var note = try Note.fetchOne(db, key: id) else { return }
            note.resolvedAt = resolved ? (note.resolvedAt ?? date) : nil
            try note.update(db)
        }
    }

    /// Attachments of every note of the meeting, in the order they were added.
    public func attachments(meetingId: Int64) throws -> [NoteAttachment] {
        try writer.read { db in
            try Attachment.fetchAll(db, sql: """
                SELECT attachment.*
                FROM attachment JOIN note ON note.id = attachment.noteId
                WHERE note.meetingId = ?
                ORDER BY attachment.createdAt, attachment.id
                """, arguments: [meetingId])
        }
        .map { resolve($0, meetingId: meetingId) }
    }

    public func attachments(noteId: Int64) throws -> [NoteAttachment] {
        guard let note = try note(id: noteId) else { return [] }
        return try attachments(meetingId: note.meetingId).filter { $0.noteId == noteId }
    }

    private func resolve(_ attachment: Attachment, meetingId: Int64) -> NoteAttachment {
        NoteAttachment(
            id: attachment.id ?? 0,
            noteId: attachment.noteId,
            kind: attachment.kind,
            url: storage.file(meetingId: meetingId, path: attachment.path)
        )
    }

    // MARK: - Documents

    public func documents(meetingId: Int64) throws -> [MeetingDocument] {
        try writer.read { db in
            try MeetingDocument.filter(Column("meetingId") == meetingId).order(Column("kind")).fetchAll(db)
        }
    }

    /// Creates or replaces the meeting's text of that kind.
    @discardableResult
    public func setDocument(meetingId: Int64, kind: String, body: String, source: String?, at date: Date = Date()) throws -> MeetingDocument {
        try writer.write { db in
            var document = try MeetingDocument
                .filter(Column("meetingId") == meetingId && Column("kind") == kind)
                .fetchOne(db)
                ?? MeetingDocument(meetingId: meetingId, kind: kind, body: body, source: source, updatedAt: date)
            document.body = body
            document.source = source
            document.updatedAt = date
            try document.save(db)
            return document
        }
    }

    /// Every meeting's text of that kind.
    public func documents(kind: String) throws -> [MeetingDocument] {
        try writer.read { db in
            try MeetingDocument.filter(Column("kind") == kind).order(Column("meetingId")).fetchAll(db)
        }
    }

    /// Changes a text in one transaction, so an edit made meanwhile from
    /// elsewhere is not lost: `change` gets the body and returns the new one,
    /// or nil to leave it as it is. Nil when there is no such text.
    @discardableResult
    public func updateDocument(
        meetingId: Int64,
        kind: String,
        at date: Date = Date(),
        _ change: (String) throws -> String?
    ) throws -> MeetingDocument? {
        try writer.write { db in
            guard var document = try MeetingDocument
                .filter(Column("meetingId") == meetingId && Column("kind") == kind)
                .fetchOne(db) else { return nil }
            guard let body = try change(document.body), body != document.body else { return document }
            document.body = body
            document.updatedAt = date
            try document.update(db)
            return document
        }
    }

    public func deleteDocument(meetingId: Int64, kind: String) throws {
        try writer.write { db in
            _ = try MeetingDocument.filter(Column("meetingId") == meetingId && Column("kind") == kind).deleteAll(db)
        }
    }

    // MARK: - Links

    /// `url` as given (see `LinkLabel.normalize`); an empty title is no title.
    @discardableResult
    public func addLink(meetingId: Int64, url: String, title: String? = nil, at date: Date = Date()) throws -> MeetingLink {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            var link = MeetingLink(meetingId: meetingId, url: url, title: title?.isEmpty == false ? title : nil, createdAt: date)
            try link.insert(db)
            return link
        }
    }

    public func deleteLink(_ id: Int64) throws {
        try writer.write { db in _ = try MeetingLink.deleteOne(db, key: id) }
    }

    public func link(id: Int64) throws -> MeetingLink? {
        try writer.read { db in try MeetingLink.fetchOne(db, key: id) }
    }

    public func links(meetingId: Int64) throws -> [MeetingLink] {
        try writer.read { db in
            try MeetingLink.filter(Column("meetingId") == meetingId).order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    public func linksByMeeting() throws -> [Int64: [MeetingLink]] {
        try writer.read { db in
            Dictionary(grouping: try MeetingLink.order(Column("createdAt"), Column("id")).fetchAll(db), by: \.meetingId)
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

    // MARK: - Transcript and speakers

    /// Replaces the whole transcript of a meeting atomically, so a re-run of
    /// the pipeline never leaves a mix of old and new segments.
    public func saveTranscript(meetingId: Int64, speakers: [MeetingSpeaker], segments: [Segment]) throws {
        try writer.write { db in
            // Explicit deletes keep the FTS index in sync (see deleteMeeting).
            try Segment.filter(Column("meetingId") == meetingId).deleteAll(db)
            try MeetingSpeaker.filter(Column("meetingId") == meetingId).deleteAll(db)
            for speaker in speakers {
                try speaker.insert(db)
            }
            for var segment in segments {
                segment.id = nil
                try segment.insert(db)
            }
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
            meeting.status = .done
            meeting.statusDetail = nil
            try meeting.update(db)
        }
    }

    /// Adds a batch transcribed while the meeting is still being recorded:
    /// its segments, and the voices heard so far (`speakers` replaces what is
    /// stored about each). A voice that already has a person keeps it — the
    /// user may have named it mid-call — and every segment of a voice takes
    /// its person, including earlier ones.
    public func appendTranscript(meetingId: Int64, speakers: [MeetingSpeaker], segments: [Segment]) throws {
        try writer.write { db in
            for var speaker in speakers {
                let stored = try MeetingSpeaker
                    .filter(Column("meetingId") == meetingId && Column("diarCluster") == speaker.diarCluster)
                    .fetchOne(db)
                speaker.personId = stored?.personId ?? speaker.personId
                try speaker.save(db)
            }
            let people = try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db)
                .reduce(into: [Int: Int64]()) { people, speaker in people[speaker.diarCluster] = speaker.personId }
            for var segment in segments {
                segment.id = nil
                segment.personId = segment.diarCluster.flatMap { people[$0] }
                try segment.insert(db)
            }
            for (cluster, personId) in people {
                try Segment
                    .filter(Column("meetingId") == meetingId && Column("diarCluster") == cluster && Column("personId") == nil)
                    .updateAll(db, Column("personId").set(to: personId))
            }
        }
    }

    public func speakers(meetingId: Int64) throws -> [MeetingSpeaker] {
        try writer.read { db in
            try MeetingSpeaker
                .filter(Column("meetingId") == meetingId)
                .order(Column("diarCluster"))
                .fetchAll(db)
        }
    }

    public func persons() throws -> [Person] {
        try writer.read { db in
            try Person.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    public func voiceprints() throws -> [Voiceprint] {
        try writer.read { db in try Voiceprint.fetchAll(db) }
    }

    /// Names a voice of a meeting. The person is created when new, every
    /// segment of that voice is attributed to them, and the voice becomes a
    /// voiceprint so future meetings recognize them automatically.
    @discardableResult
    public func assignSpeaker(meetingId: Int64, diarCluster: Int, personName: String) throws -> Person {
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            var person = try Person.filter(Column("name").collating(.nocase) == name).fetchOne(db)
                ?? Person(name: name, createdAt: Date())
            if person.id == nil {
                try person.insert(db)
            }
            let personId = person.id!
            guard var speaker = try MeetingSpeaker
                .filter(Column("meetingId") == meetingId && Column("diarCluster") == diarCluster)
                .fetchOne(db) else { return person }
            speaker.personId = personId
            try speaker.update(db)
            try Segment
                .filter(Column("meetingId") == meetingId && Column("diarCluster") == diarCluster)
                .updateAll(db, Column("personId").set(to: personId))
            if let embedding = speaker.embedding {
                // Re-naming the same voice replaces its voiceprint instead of
                // piling up duplicates (or a wrong first guess).
                try Voiceprint
                    .filter(Column("meetingId") == meetingId)
                    .filter(Column("embedding") == embedding)
                    .deleteAll(db)
                var voiceprint = Voiceprint(
                    personId: personId,
                    meetingId: meetingId,
                    embedding: embedding,
                    createdAt: Date()
                )
                try voiceprint.insert(db)
            }
            return person
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

    /// Speech and notes matching every word of the query (accents ignored),
    /// newest meeting first.
    public func search(_ query: String) throws -> [SearchHit] {
        let meetingsById = Dictionary(uniqueKeysWithValues: try meetings().compactMap { meeting in
            meeting.id.map { ($0, meeting.startedAt) }
        })
        let speech = try searchSegments(query).map { segment in
            SearchHit(
                meetingId: segment.meetingId,
                tMs: segment.tStartMs,
                text: segment.text,
                kind: .speech(segment.channel, diarCluster: segment.diarCluster, personId: segment.personId)
            )
        }
        let notes = try searchNotes(query).map { note in
            SearchHit(meetingId: note.meetingId, tMs: note.tMs, text: note.text, kind: .note)
        }
        return (speech + notes).sorted { lhs, rhs in
            let left = meetingsById[lhs.meetingId] ?? .distantPast
            let right = meetingsById[rhs.meetingId] ?? .distantPast
            return left != right ? left > right : lhs.tMs < rhs.tMs
        }
    }

    /// Names of the known people heard in each meeting.
    public func noteCounts() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT meetingId, count(*) AS n FROM note GROUP BY meetingId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["meetingId"], $0["n"]) })
        }
    }

    public func attachmentCounts() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT note.meetingId, count(*) AS n
                FROM attachment JOIN note ON note.id = attachment.noteId
                GROUP BY note.meetingId
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["meetingId"], $0["n"]) })
        }
    }

    public func documentKinds() throws -> [Int64: [String]] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT meetingId, kind FROM meetingDocument ORDER BY kind")
            var result: [Int64: [String]] = [:]
            for row in rows {
                result[row["meetingId"], default: []].append(row["kind"])
            }
            return result
        }
    }

    public func peopleByMeeting() throws -> [Int64: [String]] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT meetingSpeaker.meetingId, person.name
                FROM meetingSpeaker JOIN person ON person.id = meetingSpeaker.personId
                ORDER BY person.name
                """)
            var result: [Int64: [String]] = [:]
            for row in rows {
                result[row["meetingId"], default: []].append(row["name"])
            }
            return result
        }
    }
}
