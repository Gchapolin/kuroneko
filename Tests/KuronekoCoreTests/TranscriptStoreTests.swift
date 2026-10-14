import Foundation
import GRDB
import Testing
@testable import KuronekoCore

@Suite struct TagsTests {
    @Test func parsesHashtagsLowercasedAndUnique() {
        #expect(Tags.parse("revisar #Acao com o time #1on1 #acao") == ["acao", "1on1"])
        #expect(Tags.parse("sem tags aqui") == [])
        #expect(Tags.parse("#migração do banco") == ["migração"])
    }

    @Test func notesDeriveTagsFromText() {
        let note = Note(meetingId: 1, tMs: 0, text: "cobrar o deploy #acao")
        #expect(note.tags == ["acao"])
    }
}

@Suite struct EmbeddingCodecTests {
    @Test func roundTripsFloats() {
        let vector: [Float] = [0.25, -1.5, 3.0, 0]
        #expect(EmbeddingCodec.decode(EmbeddingCodec.encode(vector)) == vector)
    }
}

@Suite struct MigrationTests {
    @Test func v2CarriesKindsIntoTagsAndQueuesMeetingsWithAudio() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO meeting (id, startedAt, endedAt, title, kind, audioSystemPath)
                VALUES (1, '2026-07-09 21:00:00', '2026-07-09 21:30:00', 'Daily', 'daily', NULL),
                       (2, '2026-10-13 23:50:00', '2026-10-13 23:55:00', 'Meet', 'outro', '/tmp/system.wav')
                """)
            try db.execute(sql: "INSERT INTO note (meetingId, tMs, kind, text) VALUES (1, 10, 'acao', 'cobrar deploy')")
        }

        let db = try AppDatabase(queue, storage: .temporary())

        let daily = try #require(try db.meeting(id: 1))
        #expect(daily.tags == ["daily"])
        #expect(daily.status == .done)
        let meet = try #require(try db.meeting(id: 2))
        #expect(meet.status == .recorded)
        #expect(try db.meetingsToProcess().map(\.id) == [2])
        #expect(try db.notes(meetingId: 1).first?.tags == ["acao"])
        #expect(try db.searchNotes("deploy").count == 1)
    }
}

@Suite struct TranscriptStoreTests {
    private func endedMeetingWithAudio(_ db: AppDatabase) throws -> Meeting {
        let meeting = try db.startMeeting(title: "Daily", source: "meet")
        try db.updateAudio(meetingId: meeting.id!, startedAt: Date(), micPath: nil, systemPath: "/tmp/system.wav")
        try db.endMeeting(meeting.id!)
        return try #require(try db.meeting(id: meeting.id!))
    }

    @Test func endingMeetingQueuesOnlyWhenThereIsAudio() throws {
        let db = try AppDatabase.inMemory()
        let withAudio = try endedMeetingWithAudio(db)
        let silent = try db.startMeeting(title: "Sem áudio")
        try db.endMeeting(silent.id!)

        #expect(withAudio.status == .recorded)
        #expect(try db.meeting(id: silent.id!)?.status == .done)
        #expect(try db.meetingsToProcess().map(\.id) == [withAudio.id])
    }

    @Test func saveTranscriptReplacesPreviousRunAndMarksDone() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try endedMeetingWithAudio(db)
        let id = meeting.id!

        try db.saveTranscript(
            meetingId: id,
            speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0)],
            segments: [Segment(meetingId: id, tStartMs: 0, tEndMs: 900, channel: .system, diarCluster: 0, text: "versão antiga")]
        )
        try db.saveTranscript(
            meetingId: id,
            speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0), MeetingSpeaker(meetingId: id, diarCluster: 1)],
            segments: [
                Segment(meetingId: id, tStartMs: 0, tEndMs: 900, channel: .system, diarCluster: 0, text: "olá pessoal"),
                Segment(meetingId: id, tStartMs: 1000, tEndMs: 1900, channel: .system, diarCluster: 1, text: "hola a todos"),
            ]
        )

        #expect(try db.segments(meetingId: id).map(\.text) == ["olá pessoal", "hola a todos"])
        #expect(try db.speakers(meetingId: id).count == 2)
        #expect(try db.searchSegments("antiga").isEmpty)
        #expect(try db.meeting(id: id)?.status == .done)
        #expect(try db.meetingsToProcess().isEmpty)
    }

    @Test func assigningSpeakerNamesSegmentsAndStoresVoiceprint() throws {
        let db = try AppDatabase.inMemory()
        let id = try endedMeetingWithAudio(db).id!
        let embedding = EmbeddingCodec.encode([0.1, 0.2, 0.3])
        try db.saveTranscript(
            meetingId: id,
            speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, embedding: embedding)],
            segments: [
                Segment(meetingId: id, tStartMs: 0, tEndMs: 900, channel: .system, diarCluster: 0, text: "hola"),
                Segment(meetingId: id, tStartMs: 1000, tEndMs: 1900, channel: .mic, text: "oi"),
            ]
        )

        let person = try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: " Matías ")
        // Naming the same voice again (a correction) must not duplicate.
        try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: "matías")

        #expect(person.name == "Matías")
        #expect(try db.persons().map(\.name) == ["Matías"])
        let segments = try db.segments(meetingId: id)
        #expect(segments.first { $0.channel == .system }?.personId == person.id)
        #expect(segments.first { $0.channel == .mic }?.personId == nil)
        let prints = try db.voiceprints()
        #expect(prints.count == 1)
        #expect(prints.first?.personId == person.id)
        #expect(prints.first?.embedding == embedding)
    }
}
