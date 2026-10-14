import Foundation
import Testing
@testable import KuronekoCore

@Suite struct AttachmentTests {
    /// A capture as the screen helper leaves it: a file outside the meeting.
    private func capture(_ storage: MeetingStorage, name: String = "print.png") throws -> URL {
        let folder = storage.root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("png".utf8).write(to: url)
        return url
    }

    @Test func noteWithAPrintMovesTheFileIntoTheMeeting() throws {
        let storage = MeetingStorage.temporary()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let db = try AppDatabase.inMemory(storage: storage)
        let meeting = try db.startMeeting(title: "Planning")
        let id = meeting.id!
        let print = try capture(storage)

        let note = try db.addNote(meetingId: id, tMs: 21_000, text: "", attachments: [print])

        let attachments = try db.attachments(meetingId: id)
        #expect(attachments.count == 1)
        let attachment = try #require(attachments.first)
        #expect(attachment.noteId == note.id)
        #expect(attachment.kind == "image")
        #expect(attachment.url.deletingLastPathComponent().standardizedFileURL == storage.attachmentsDirectory(meetingId: id).standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
        #expect(!FileManager.default.fileExists(atPath: print.path))
        #expect(try db.attachments(noteId: note.id!) == attachments)
        #expect(try db.attachmentCounts() == [id: 1])

        let entry = try #require(try db.export(meetingId: id)?.timeline.first)
        #expect(entry.type == "note")
        #expect(entry.text == "")
        #expect(entry.attachments?.map(\.path) == [attachment.url.path])
        #expect(entry.attachments?.map(\.kind) == ["image"])

        let timeline = Timeline.entries(segments: [], notes: try db.notes(meetingId: id), attachments: attachments)
        #expect(timeline == [.note(note, attachments: attachments)])
    }

    @Test func deletingTheNoteDeletesItsFiles() throws {
        let storage = MeetingStorage.temporary()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let db = try AppDatabase.inMemory(storage: storage)
        let id = try db.startMeeting(title: "Planning").id!
        let note = try db.addNote(meetingId: id, tMs: 1000, text: "quadro", attachments: [try capture(storage)])
        let kept = try db.addNote(meetingId: id, tMs: 2000, text: "outro", attachments: [try capture(storage, name: "b.png")])
        let file = try #require(try db.attachments(noteId: note.id!).first?.url)

        try db.deleteNote(note.id!)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try db.attachments(meetingId: id).map(\.noteId) == [kept.id!])
    }

    @Test func deletingTheMeetingDeletesAttachmentsAndItsDirectory() throws {
        let storage = MeetingStorage.temporary()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let db = try AppDatabase.inMemory(storage: storage)
        let id = try db.startMeeting(title: "Planning").id!
        try db.addNote(meetingId: id, tMs: 1000, text: "quadro", attachments: [try capture(storage)])

        try db.deleteMeeting(id)

        #expect(try db.attachments(meetingId: id).isEmpty)
        #expect(try db.attachmentCounts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.meetingDirectory(id: id).path))
    }

    @Test func aFailedNoteGivesTheCaptureBack() throws {
        let storage = MeetingStorage.temporary()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let db = try AppDatabase.inMemory(storage: storage)
        let print = try capture(storage)

        // No such meeting: the foreign key rejects the note.
        #expect(throws: (any Error).self) {
            try db.addNote(meetingId: 99, tMs: 0, text: "x", attachments: [print])
        }
        #expect(FileManager.default.fileExists(atPath: print.path))
    }

    @Test func kindComesFromTheFileType() {
        #expect(Attachment.kind(of: URL(fileURLWithPath: "/tmp/a.png")) == "image")
        #expect(Attachment.kind(of: URL(fileURLWithPath: "/tmp/a.HEIC")) == "image")
        #expect(Attachment.kind(of: URL(fileURLWithPath: "/tmp/a.pdf")) == "file")
    }
}
