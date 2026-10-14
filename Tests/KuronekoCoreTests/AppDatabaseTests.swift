import Foundation
import Testing
@testable import KuronekoCore

@Suite struct AppDatabaseTests {
    @Test func startMeetingCreatesActiveMeeting() throws {
        let db = try AppDatabase.inMemory()

        let meeting = try db.startMeeting(title: "Daily 9 jul")

        #expect(meeting.id != nil)
        #expect(try db.activeMeeting()?.id == meeting.id)
    }

    @Test func endMeetingClearsActiveMeeting() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "1:1 Maria")

        try db.endMeeting(meeting.id!)

        #expect(try db.activeMeeting() == nil)
        let stored = try db.meetings().first
        #expect(stored?.endedAt != nil)
    }

    @Test func activeMeetingReturnsMostRecentOpenMeeting() throws {
        let db = try AppDatabase.inMemory()
        let old = try db.startMeeting(title: "Planning", at: Date(timeIntervalSinceNow: -3600))
        try db.endMeeting(old.id!)

        let current = try db.startMeeting(title: "Refinamento")

        #expect(try db.activeMeeting()?.id == current.id)
    }

    @Test func meetingsAreOrderedByMostRecentFirst() throws {
        let db = try AppDatabase.inMemory()
        let older = try db.startMeeting(title: "Daily ontem", at: Date(timeIntervalSinceNow: -86400))
        let newer = try db.startMeeting(title: "Daily hoje")

        let all = try db.meetings()

        #expect(all.map(\.id) == [newer.id, older.id])
    }

    @Test func segmentsAreOrderedByStartTime() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily")

        try db.addSegment(meetingId: meeting.id!, tStartMs: 5000, tEndMs: 8000, channel: .system, text: "segundo")
        try db.addSegment(meetingId: meeting.id!, tStartMs: 1000, tEndMs: 4000, channel: .mic, text: "primeiro")

        let segments = try db.segments(meetingId: meeting.id!)
        #expect(segments.map(\.text) == ["primeiro", "segundo"])
        #expect(segments.first?.channel == .mic)
    }

    @Test func searchSegmentsFindsTextAcrossMeetings() throws {
        let db = try AppDatabase.inMemory()
        let daily = try db.startMeeting(title: "Daily")
        let planning = try db.startMeeting(title: "Planning")
        try db.addSegment(meetingId: daily.id!, tStartMs: 0, tEndMs: 1000, channel: .system, text: "o deploy quebrou ontem")
        try db.addSegment(meetingId: planning.id!, tStartMs: 0, tEndMs: 1000, channel: .system, text: "vamos priorizar o deploy")
        try db.addSegment(meetingId: daily.id!, tStartMs: 2000, tEndMs: 3000, channel: .mic, text: "sem novidades")

        let results = try db.searchSegments("deploy")

        #expect(results.count == 2)
        #expect(Set(results.map(\.meetingId)) == [daily.id!, planning.id!])
    }

    @Test func searchIgnoresAccents() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Refinamento")
        try db.addSegment(meetingId: meeting.id!, tStartMs: 0, tEndMs: 1000, channel: .system, text: "a estimativa da migração ficou alta")

        let results = try db.searchSegments("migracao")

        #expect(results.count == 1)
    }

    @Test func searchNotesFindsByText() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "1:1")
        try db.addNote(meetingId: meeting.id!, tMs: 1000, text: "perguntar sobre a promoção do Pedro #duvida")
        try db.addNote(meetingId: meeting.id!, tMs: 2000, text: "agendar review de metas")

        let results = try db.searchNotes("promocao")

        #expect(results.count == 1)
        #expect(results.first?.tags == ["duvida"])
    }

    @Test func deleteMeetingRemovesChildrenAndSearchIndex() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily")
        try db.addSegment(meetingId: meeting.id!, tStartMs: 0, tEndMs: 1000, channel: .system, text: "assunto secreto")
        try db.addNote(meetingId: meeting.id!, tMs: 500, text: "lembrete secreto")
        try db.addScreenshot(meetingId: meeting.id!, tMs: 700, imagePath: "/tmp/print.png")

        try db.deleteMeeting(meeting.id!)

        #expect(try db.meetings().isEmpty)
        #expect(try db.segments(meetingId: meeting.id!).isEmpty)
        #expect(try db.notes(meetingId: meeting.id!).isEmpty)
        #expect(try db.screenshots(meetingId: meeting.id!).isEmpty)
        #expect(try db.searchSegments("secreto").isEmpty)
        #expect(try db.searchNotes("secreto").isEmpty)
    }

    @Test func screenshotsAndNotesRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Planning")

        let note = try db.addNote(meetingId: meeting.id!, tMs: 1234, text: "qual o prazo?")
        let shot = try db.addScreenshot(meetingId: meeting.id!, tMs: 5678, imagePath: "/tmp/board.png", caption: "quadro da sprint")

        #expect(note.id != nil)
        #expect(shot.id != nil)
        #expect(try db.notes(meetingId: meeting.id!) == [note])
        #expect(try db.screenshots(meetingId: meeting.id!) == [shot])
    }
}
