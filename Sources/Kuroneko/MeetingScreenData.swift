import Foundation
import KuronekoCore
import os

/// Everything the meeting screen shows, read from the database at once
/// whenever stored data changes.
struct MeetingScreenData {
    /// A person, the user or an unnamed voice heard in the meeting.
    struct Voice: Identifiable {
        /// "me" or "c<cluster>", as `SpeechBlock.speakerKey`.
        var key: String
        var cluster: Int?
        /// Nil for a voice nobody named yet.
        var name: String?

        var id: String { key }
        var label: String {
            if key == "me" { return "Você" }
            return name ?? "Pessoa \((cluster ?? 0) + 1)"
        }
    }

    var meeting: Meeting
    var entries: [TimelineEntry]
    var notes: [Note]
    var attachments: [Int64: [NoteAttachment]]
    var noteContexts: [Int64: NoteContext]
    var voices: [Voice]
    var persons: [Int64: String]
    var clusterPersons: [Int: Int64]
    var candidates: [Int: [PendingVoice.Candidate]]
    var samples: [Int: VoiceSample]
    var summary: MeetingDocument?
    var overview: SummaryOverview
    var tasks: [TaskItem]
    var decisions: [SummaryItem]
    var links: [MeetingLink]
    var hasSpeech: Bool
    /// During the call: up to where the transcript is ready.
    var transcribedUntilMs: Int

    private static let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MeetingScreen")

    static func load(db: AppDatabase, meetingId: Int64) -> MeetingScreenData? {
        do {
            return try read(db: db, meetingId: meetingId)
        } catch {
            logger.error("Falha ao ler a reunião \(meetingId): \(String(describing: error))")
            return nil
        }
    }

    private static func read(db: AppDatabase, meetingId: Int64) throws -> MeetingScreenData? {
        guard let meeting = try db.meeting(id: meetingId) else { return nil }
        let segments = try db.segments(meetingId: meetingId)
        let notes = try db.notes(meetingId: meetingId)
        let attachments = try db.attachments(meetingId: meetingId)
        let speakers = try db.speakers(meetingId: meetingId)
        let people = try db.persons()
        let voiceprints = try db.voiceprints()
        let summary = try db.documents(meetingId: meetingId).first { $0.kind == "summary" }
        let persons = Dictionary(uniqueKeysWithValues: people.compactMap { person in person.id.map { ($0, person.name) } })

        return MeetingScreenData(
            meeting: meeting,
            entries: Timeline.entries(segments: segments, notes: notes, attachments: attachments),
            notes: notes,
            attachments: Dictionary(grouping: attachments, by: \.noteId),
            noteContexts: Dictionary(uniqueKeysWithValues: notes.compactMap { note in
                guard let id = note.id, let context = Timeline.context(forNoteAtMs: note.tMs, segments: segments) else { return nil }
                return (id, context)
            }),
            voices: voices(speakers: speakers, persons: persons, hasMic: segments.contains { $0.channel == .mic }),
            persons: persons,
            clusterPersons: speakers.reduce(into: [:]) { result, speaker in result[speaker.diarCluster] = speaker.personId },
            candidates: Dictionary(uniqueKeysWithValues: speakers.map { speaker in
                (speaker.diarCluster, VoiceReview.candidates(for: speaker.embedding, persons: people, voiceprints: voiceprints))
            }),
            samples: Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
                VoiceReview.sample(cluster: speaker.diarCluster, segments: segments).map { (speaker.diarCluster, $0) }
            }),
            summary: summary,
            overview: summary.map { SummaryOverview.parse($0.body) } ?? SummaryOverview(intro: [], sections: []),
            tasks: try db.tasks(meetingId: meetingId),
            decisions: summary.map { SummaryItems.parse($0.body).filter { $0.kind == "decision" } } ?? [],
            links: try db.links(meetingId: meetingId),
            hasSpeech: !segments.isEmpty,
            transcribedUntilMs: LiveProgress.transcribedUntilMs(segments)
        )
    }

    /// Named people (one chip each, by their most talkative voice), the
    /// user, then the voices still to be named that said enough to matter.
    private static func voices(speakers: [MeetingSpeaker], persons: [Int64: String], hasMic: Bool) -> [Voice] {
        var named: [Int64: MeetingSpeaker] = [:]
        for speaker in speakers {
            guard let personId = speaker.personId, persons[personId] != nil else { continue }
            if speaker.speechMs > (named[personId]?.speechMs ?? -1) {
                named[personId] = speaker
            }
        }
        let people = named
            .map { personId, speaker in Voice(key: "c\(speaker.diarCluster)", cluster: speaker.diarCluster, name: persons[personId]) }
            .sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        let unnamed = speakers
            .filter { ($0.personId == nil || persons[$0.personId!] == nil) && $0.speechMs >= VoiceReview.minSpeechMs }
            .map { Voice(key: "c\($0.diarCluster)", cluster: $0.diarCluster, name: nil) }
        return people + (hasMic ? [Voice(key: "me", cluster: nil, name: nil)] : []) + unnamed
    }

    // MARK: - Reading

    var isRecording: Bool {
        meeting.status == .recording
    }

    func attachments(of note: Note) -> [NoteAttachment] {
        note.id.flatMap { attachments[$0] } ?? []
    }

    func images(of note: Note) -> [NoteAttachment] {
        attachments(of: note).filter { $0.kind == "image" }
    }

    func context(of note: Note) -> NoteContext? {
        note.id.flatMap { noteContexts[$0] }
    }

    /// Who speaks in a block: "Você", a person's name or "Pessoa N".
    func name(of block: SpeechBlock) -> String {
        if block.speakerKey == "me" { return "Você" }
        if let personId = block.segments.first?.personId, let name = persons[personId] { return name }
        return "Pessoa \((block.segments.first?.diarCluster ?? 0) + 1)"
    }

    /// The name a voice of the call was given, if any.
    func personName(cluster: Int) -> String? {
        clusterPersons[cluster].flatMap { persons[$0] }
    }

    /// Where the scrubber marks the notes.
    var noteMarks: [Int] {
        notes.map(\.tMs)
    }
}
