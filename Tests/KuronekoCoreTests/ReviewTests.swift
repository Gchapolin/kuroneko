import Foundation
import Testing
@testable import KuronekoCore

@Suite struct TimelineTests {
    private func segment(_ start: Int, _ end: Int, _ channel: SegmentChannel, _ cluster: Int? = nil, _ text: String) -> Segment {
        Segment(meetingId: 1, tStartMs: start, tEndMs: end, channel: channel, diarCluster: cluster, text: text)
    }

    @Test func groupsSpeakerRunsAndPlacesNotes() {
        let entries = Timeline.entries(
            segments: [
                segment(0, 2000, .system, 0, "oi pessoal"),
                segment(2500, 4000, .system, 0, "vamos começar"),
                segment(4500, 6000, .mic, nil, "bora"),
                segment(6500, 8000, .system, 1, "hola"),
                segment(20000, 21000, .system, 1, "otra cosa"),
            ],
            notes: [Note(id: 9, meetingId: 1, tMs: 3000, text: "cobrar deploy")]
        )

        let shape = entries.map { entry -> String in
            switch entry {
            case .speech(let block): "\(block.speakerKey):\(block.segments.count)"
            case .note: "nota"
            }
        }
        #expect(shape == ["c0:2", "nota", "me:1", "c1:1", "c1:1"])
    }
}

@Suite struct WeekGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: text)!
    }

    @Test func groupsByWeekNewestFirst() {
        let now = date("2026-10-14T10:00:00-03:00")
        let meetings = [
            Meeting(id: 1, startedAt: date("2026-10-01T10:00:00-03:00"), title: "a"),
            Meeting(id: 2, startedAt: date("2026-10-13T10:00:00-03:00"), title: "b"),
            Meeting(id: 3, startedAt: date("2026-10-07T10:00:00-03:00"), title: "c"),
            Meeting(id: 4, startedAt: date("2026-10-12T09:00:00-03:00"), title: "d"),
        ]

        let groups = WeekGrouping.group(meetings, now: now, calendar: calendar)

        #expect(groups.map(\.title) == ["Esta semana", "Semana passada", "27 de set. – 3 de out."])
        #expect(groups.map { $0.meetings.map(\.id!) } == [[2, 4], [3], [1]])
    }
}

@Suite struct SearchTests {
    @Test func findsSpeechAndNotesNewestMeetingFirst() throws {
        let db = try AppDatabase.inMemory()
        let old = try db.startMeeting(title: "Antiga", at: Date(timeIntervalSinceNow: -86400))
        let new = try db.startMeeting(title: "Nova")
        try db.addSegment(meetingId: old.id!, tStartMs: 1000, tEndMs: 2000, channel: .system, text: "o deploy atrasou")
        try db.addSegment(meetingId: new.id!, tStartMs: 5000, tEndMs: 6000, channel: .mic, text: "deploy hoje à tarde")
        try db.addNote(meetingId: new.id!, tMs: 3000, text: "confirmar deploy #acao")

        let hits = try db.search("deploy")

        #expect(hits.map(\.meetingId) == [new.id!, new.id!, old.id!])
        #expect(hits.first?.kind == .note)
    }

    @Test func listsKnownPeoplePerMeeting() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily")
        try db.saveTranscript(
            meetingId: meeting.id!,
            speakers: [MeetingSpeaker(meetingId: meeting.id!, diarCluster: 0), MeetingSpeaker(meetingId: meeting.id!, diarCluster: 1)],
            segments: []
        )
        try db.assignSpeaker(meetingId: meeting.id!, diarCluster: 0, personName: "Valentina")

        #expect(try db.peopleByMeeting() == [meeting.id!: ["Valentina"]])
    }
}

@Suite struct VoiceReviewTests {
    private func print(_ personId: Int64, _ vector: [Float]) -> Voiceprint {
        Voiceprint(personId: personId, meetingId: nil, embedding: EmbeddingCodec.encode(vector), createdAt: Date())
    }

    private func speaker(_ cluster: Int, speechMs: Int, personId: Int64? = nil, _ vector: [Float]? = nil) -> MeetingSpeaker {
        MeetingSpeaker(meetingId: 7, personId: personId, diarCluster: cluster, embedding: vector.map(EmbeddingCodec.encode), speechMs: speechMs)
    }

    @Test func ranksPeopleByTheirClosestVoiceprint() {
        let prints = [print(1, [0, 1, 0]), print(1, [0.8, 0.6, 0]), print(2, [0.6, 0.8, 0]), print(3, [0, 0, 1])]

        let ranked = SpeakerMatcher.rank([1, 0, 0], voiceprints: prints)

        #expect(ranked.map(\.personId) == [1, 2, 3])
        #expect(abs(ranked[0].similarity - 0.8) < 0.001)
    }

    @Test func asksOnlyAboutUnnamedVoicesWithEnoughSpeech() {
        let persons = [
            Person(id: 1, name: "Ana", createdAt: Date()),
            Person(id: 2, name: "Bruno", createdAt: Date()),
            Person(id: 3, name: "Carla", createdAt: Date()),
        ]
        let pending = VoiceReview.pending(
            meetingId: 7,
            speakers: [
                speaker(0, speechMs: 20000, personId: 2, [0, 1, 0]),
                speaker(1, speechMs: 5000, [0.45, 0, 0.89]),
                speaker(2, speechMs: 40000, [0, 0, 1]),
                speaker(3, speechMs: 1200, [1, 0, 0]),
            ],
            segments: [],
            persons: persons,
            voiceprints: [print(1, [1, 0, 0]), print(2, [0, 1, 0])]
        )

        // Most talkative first; the named voice and the cough are left out.
        #expect(pending.map(\.diarCluster) == [2, 1])
        // Ana sounds a bit different today: below automatic recognition,
        // but still the first suggestion. Carla has no voiceprint: last.
        let voice = pending[1]
        #expect(voice.candidates.map(\.name) == ["Ana", "Bruno", "Carla"])
        #expect(voice.candidates.map(\.isLikely) == [true, false, false])
        #expect(SpeakerMatcher.match([0.45, 0, 0.89], voiceprints: [print(1, [1, 0, 0])]) == nil)
    }

    @Test func choosingAKnownPersonTeachesTheirNewSound() throws {
        let db = try AppDatabase.inMemory()
        let first = try db.startMeeting(title: "Daily")
        try db.saveTranscript(
            meetingId: first.id!,
            speakers: [MeetingSpeaker(meetingId: first.id!, diarCluster: 0, embedding: EmbeddingCodec.encode([1, 0, 0]), speechMs: 9000)],
            segments: []
        )
        try db.assignSpeaker(meetingId: first.id!, diarCluster: 0, personName: "Ana")
        let second = try db.startMeeting(title: "Planning")
        let today: [Float] = [0.45, 0.89, 0]
        try db.saveTranscript(
            meetingId: second.id!,
            speakers: [MeetingSpeaker(meetingId: second.id!, diarCluster: 0, embedding: EmbeddingCodec.encode(today), speechMs: 9000)],
            segments: []
        )

        #expect(try db.pendingVoices(meetingId: second.id!).first?.candidates.first?.name == "Ana")
        try db.assignSpeaker(meetingId: second.id!, diarCluster: 0, personName: "Ana")

        #expect(try db.pendingVoices(meetingId: second.id!).isEmpty)
        #expect(SpeakerMatcher.match([0.47, 0.88, 0], voiceprints: try db.voiceprints()) != nil)
    }

    @Test func sampleIsTheLongestStretchOfThatVoice() {
        let segments = [
            Segment(meetingId: 7, tStartMs: 0, tEndMs: 1000, channel: .system, diarCluster: 0, text: "oi"),
            Segment(meetingId: 7, tStartMs: 5000, tEndMs: 7000, channel: .system, diarCluster: 0, text: "então"),
            Segment(meetingId: 7, tStartMs: 7200, tEndMs: 9000, channel: .system, diarCluster: 0, text: "vamos lá"),
            Segment(meetingId: 7, tStartMs: 9000, tEndMs: 30000, channel: .system, diarCluster: 1, text: "outra voz"),
            Segment(meetingId: 7, tStartMs: 40000, tEndMs: 41000, channel: .system, diarCluster: 0, text: "tchau"),
        ]

        #expect(VoiceReview.sample(cluster: 0, segments: segments) == VoiceSample(startMs: 5000, durationMs: 4000))
        #expect(VoiceReview.sample(cluster: 1, segments: segments) == VoiceSample(startMs: 9000, durationMs: 8000))
        #expect(VoiceReview.sample(cluster: 2, segments: segments) == nil)
    }
}

@Suite struct VoicePromptScheduleTests {
    @Test func asksRightAwayButNeverDuringACall() {
        var schedule = VoicePromptSchedule()
        schedule.add(1)

        #expect(schedule.due(inCall: false) == 1)
        #expect(schedule.due(inCall: true) == nil)
    }

    @Test func dismissedWaitsForTheMenuOrTheNextTranscription() {
        var schedule = VoicePromptSchedule()
        schedule.add(1)
        schedule.dismiss()
        #expect(schedule.due(inCall: false) == nil)

        schedule.resume()
        #expect(schedule.due(inCall: false) == 1)

        schedule.dismiss()
        schedule.add(2)
        #expect(schedule.due(inCall: false) == 2)
    }

    @Test func newestMeetingFirstThenTheOlderOnes() {
        var schedule = VoicePromptSchedule()
        schedule.add(1)
        schedule.add(2)

        #expect(schedule.due(inCall: false) == 2)
        schedule.remove(2)
        #expect(schedule.due(inCall: false) == 1)
        schedule.remove(1)
        #expect(schedule.due(inCall: false) == nil)
    }

    @Test func remembersVoicesTheUserDoesNotKnow() {
        var schedule = VoicePromptSchedule()
        schedule.add(1)
        schedule.skip(meetingId: 1, diarCluster: 3)

        #expect(schedule.isSkipped(meetingId: 1, diarCluster: 3))
        #expect(!schedule.isSkipped(meetingId: 1, diarCluster: 0))
        schedule.remove(1)
        #expect(!schedule.isSkipped(meetingId: 1, diarCluster: 3))
    }
}

@Suite struct NoteContextTests {
    private func segment(_ start: Int, _ end: Int, _ cluster: Int?, _ text: String) -> Segment {
        Segment(meetingId: 1, tStartMs: start, tEndMs: end, channel: cluster == nil ? .mic : .system, diarCluster: cluster, text: text)
    }

    @Test func pointsToWhoWasTalkingAboutTheSubject() {
        let segments = [
            segment(0, 50_000, 1, "pauta de ontem"),
            segment(62_000, 70_000, 0, "a gente precisa migrar o banco"),
            segment(70_500, 78_000, 0, "até sexta, senão trava o deploy"),
            segment(78_500, 80_000, nil, "aham"),
            segment(95_000, 99_000, 1, "outro assunto"),
        ]

        // Noted at 1:21, while the user was saying "aham" right after Renato.
        let context = Timeline.context(forNoteAtMs: 81_000, segments: segments)

        #expect(context?.block.speakerKey == "c0")
        #expect(context?.block.segments.map(\.text) == ["a gente precisa migrar o banco", "até sexta, senão trava o deploy"])
        #expect(context?.playFromMs == 62_000)
    }

    @Test func includesWhatIsSaidWhileTheNoteIsBeingWritten() {
        let segments = [
            segment(75_000, 81_000, 0, "consegue mostrar se está aparecendo?"),
            segment(114_700, 117_600, 0, "acho que tá difícil as coisas"),
            segment(140_000, 145_000, 1, "outro assunto"),
        ]

        // Shortcut pressed at 1:47; the sentence noted came 8s later.
        let context = Timeline.context(forNoteAtMs: 106_900, segments: segments)

        #expect(context?.block.segments.last?.text == "acho que tá difícil as coisas")
    }

    @Test func excerptKeepsTheEndOfWhatWasSaid() {
        let context = NoteContext(block: SpeechBlock(speakerKey: "c0", segments: [
            segment(0, 5000, 0, "bom dia a todos"),
            segment(5000, 9000, 0, "precisamos migrar o banco até sexta"),
        ]))

        #expect(context.excerpt() == "bom dia a todos precisamos migrar o banco até sexta")
        #expect(context.excerpt(maxLength: 24) == "…migrar o banco até sexta")
    }

    @Test func nothingSaidRecentlyHasNoContext() {
        let segments = [segment(0, 5000, 0, "bom dia")]

        #expect(Timeline.context(forNoteAtMs: 60_000, segments: segments) == nil)
        #expect(Timeline.context(forNoteAtMs: 1000, segments: []) == nil)
    }

    @Test func noteTimeIsAlsoAClockTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let meeting = Meeting(startedAt: start, title: "Daily", audioStartedAt: start.addingTimeInterval(2))

        #expect(meeting.date(atOffsetMs: 90_000) == start.addingTimeInterval(92))
        #expect(meeting.audioOffsetMs(at: meeting.date(atOffsetMs: 90_000)) == 90_000)
    }
}
