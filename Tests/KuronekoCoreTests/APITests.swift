import Foundation
import Testing
@testable import KuronekoCore

@Suite struct CLICommandTests {
    @Test func parsesEveryCommand() throws {
        #expect(try CLICommand.parse([]) == .help)
        #expect(try CLICommand.parse(["meetings"]) == .meetings)
        #expect(try CLICommand.parse(["meeting", "4"]) == .meeting(id: 4))
        #expect(try CLICommand.parse(["transcript", "4"]) == .transcript(id: 4))
        #expect(try CLICommand.parse(["search", "migrar", "banco"]) == .search("migrar banco"))
        #expect(try CLICommand.parse(["name", "4", "c1", "Renato", "Souza"]) == .name(meetingId: 4, voice: "c1", person: "Renato Souza"))
        #expect(try CLICommand.parse(["note", "add", "4", "--at", "03:21", "falar", "com", "ele"]) == .noteAdd(meetingId: 4, atMs: 201_000, text: "falar com ele"))
        #expect(try CLICommand.parse(["note", "add", "4", "falar", "--at", "201000ms"]) == .noteAdd(meetingId: 4, atMs: 201_000, text: "falar"))
        #expect(try CLICommand.parse(["note", "rm", "9"]) == .noteRemove(noteId: 9))
        #expect(try CLICommand.parse(["summarize", "4"]) == .summarize(meetingId: 4))
        #expect(try CLICommand.parse(["doc", "set", "4", "summary"]) == .documentSet(meetingId: 4, kind: "summary"))
        #expect(try CLICommand.parse(["doc", "rm", "4", "summary"]) == .documentRemove(meetingId: 4, kind: "summary"))
        #expect(try CLICommand.parse(["play", "4"]) == .play(meetingId: 4, fromMs: 0))
        #expect(try CLICommand.parse(["play", "4", "--at", "1:03:21"]) == .play(meetingId: 4, fromMs: 3_801_000))
    }

    @Test func rejectsBadInput() {
        #expect(throws: CLIError.self) { try CLICommand.parse(["meeting"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["meeting", "abc"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["note", "add", "4", "sem horário"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["note", "add", "4", "--at", "03:21"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["play", "4", "--at", "99:99"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["meetings", "extra"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["voar"]) }
    }

    @Test func readsTimesAsPeopleWriteThem() {
        #expect(ClockTime.parse("03:21") == 201_000)
        #expect(ClockTime.parse("1:03:21") == 3_801_000)
        #expect(ClockTime.parse("95") == 95_000)
        #expect(ClockTime.parse("1500ms") == 1500)
        #expect(ClockTime.parse("03:") == nil)
        #expect(ClockTime.parse("-5") == nil)
        #expect(ClockTime.parse("1:75") == nil)
        #expect(ClockTime.format(ms: 3_801_000) == "1:03:21")
    }

    @Test func voiceCanBeTheKeyOrTheLabel() {
        #expect(VoiceRef.cluster(from: "c1") == 1)
        #expect(VoiceRef.cluster(from: "2") == 1)
        #expect(VoiceRef.cluster(from: "Pessoa 2") == 1)
        #expect(VoiceRef.cluster(from: "0") == nil)
        #expect(VoiceRef.cluster(from: "Renato") == nil)
    }
}

@Suite struct MeetingExportTests {
    private func recordedMeeting(_ db: AppDatabase) throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try db.startMeeting(title: "Planning", source: "meet", at: start)
        let id = meeting.id!
        try db.updateAudio(meetingId: id, startedAt: start, micPath: nil, systemPath: "/tmp/system.wav")
        try db.endMeeting(id, at: start.addingTimeInterval(600))
        try db.saveTranscript(
            meetingId: id,
            speakers: [
                MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 9000),
                MeetingSpeaker(meetingId: id, diarCluster: 1, speechMs: 4000),
            ],
            segments: [
                Segment(meetingId: id, tStartMs: 60_000, tEndMs: 65_000, channel: .system, diarCluster: 0, text: "precisamos migrar o banco"),
                Segment(meetingId: id, tStartMs: 65_500, tEndMs: 69_000, channel: .system, diarCluster: 0, text: "até sexta"),
                Segment(meetingId: id, tStartMs: 70_000, tEndMs: 72_000, channel: .mic, text: "fechado"),
                Segment(meetingId: id, tStartMs: 80_000, tEndMs: 84_000, channel: .system, diarCluster: 1, text: "e o deploy?"),
            ]
        )
        try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: "Renato")
        try db.addNote(meetingId: id, tMs: 71_000, text: "cobrar migração #acao")
        return id
    }

    @Test func exportsVoicesTimelineNotesAndDocuments() throws {
        let db = try AppDatabase.inMemory()
        let id = try recordedMeeting(db)
        try db.setDocument(meetingId: id, kind: "summary", body: "## Resumo\nMigração até sexta.", source: "claude")

        let meeting = try #require(try db.export(meetingId: id))

        #expect(meeting.voices.map(\.name) == ["Você", "Renato", "Pessoa 2"])
        #expect(meeting.voices.map(\.key) == ["me", "c0", "c1"])
        #expect(meeting.timeline.map(\.type) == ["speech", "speech", "note", "speech"])
        let first = meeting.timeline[0]
        #expect(first.name == "Renato")
        #expect(first.text == "precisamos migrar o banco até sexta")
        #expect(first.segments?.count == 2)
        let note = meeting.timeline[2]
        #expect(note.text == "cobrar migração #acao")
        #expect(note.tags == ["acao"])
        #expect(note.at == Date(timeIntervalSince1970: 1_800_000_071))
        #expect(note.context?.name == "Renato")
        #expect(note.context?.startMs == 60_000)
        #expect(meeting.documents.map(\.kind) == ["summary"])
        #expect(meeting.durationMs == 600_000)
    }

    @Test func listsMeetingsWithWeekPeopleNotesAndDocuments() throws {
        let db = try AppDatabase.inMemory()
        let id = try recordedMeeting(db)
        try db.setDocument(meetingId: id, kind: "summary", body: "x", source: "manual")

        let list = try db.meetingList(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(list.map(\.id) == [id])
        #expect(list.first?.week == "Esta semana")
        #expect(list.first?.people == ["Renato"])
        #expect(list.first?.noteCount == 1)
        #expect(list.first?.documents == ["summary"])
    }

    @Test func documentsAreOnePerKindAndReplaced() throws {
        let db = try AppDatabase.inMemory()
        let id = try recordedMeeting(db)

        try db.setDocument(meetingId: id, kind: "summary", body: "primeiro", source: "claude")
        try db.setDocument(meetingId: id, kind: "summary", body: "editado", source: "manual")
        try db.setDocument(meetingId: id, kind: "ata", body: "ata", source: "manual")

        #expect(try db.documents(meetingId: id).map(\.body) == ["ata", "editado"])
        try db.deleteDocument(meetingId: id, kind: "ata")
        try db.deleteMeeting(id)
        #expect(try db.documents(meetingId: id).isEmpty)
    }

    @Test func transcriptTextKeepsNotesInTheTimeline() throws {
        let db = try AppDatabase.inMemory()
        let id = try recordedMeeting(db)
        try db.setDocument(meetingId: id, kind: "summary", body: "Migração até sexta.", source: "claude")
        let meeting = try #require(try db.export(meetingId: id))
        let utc = TimeZone(identifier: "UTC")!

        let text = TranscriptText.render(meeting, timeZone: utc)
        let forClaude = TranscriptText.render(meeting, includeDocuments: false, timeZone: utc)

        #expect(text.contains("Participantes: Você, Renato, Pessoa 2"))
        #expect(text.contains("## Resumo\n\nMigração até sexta."))
        #expect(text.contains("[01:00] Renato: precisamos migrar o banco até sexta\n[01:10] Você: fechado\n[01:11] NOTA (às 08:01): cobrar migração #acao\n[01:20] Pessoa 2: e o deploy?"))
        #expect(!forClaude.contains("## Resumo"))
    }

    @Test func documentWithItsOwnHeadingIsNotTitledTwice() throws {
        let db = try AppDatabase.inMemory()
        let id = try recordedMeeting(db)
        try db.setDocument(meetingId: id, kind: "summary", body: "## Resumo\nMigração até sexta.", source: "claude")

        let text = TranscriptText.render(try #require(try db.export(meetingId: id)))

        #expect(text.components(separatedBy: "## Resumo").count == 2)
    }
}
