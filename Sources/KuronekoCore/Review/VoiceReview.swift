import Foundation

/// A voice of a meeting nobody has named yet, with who it might be, so it can
/// be named right after the transcription instead of later, by digging
/// through the meeting.
public struct PendingVoice: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable {
        public var personId: Int64
        public var name: String
        /// Best cosine similarity to the person's voiceprints; nil for
        /// someone without a voiceprint to compare with.
        public var similarity: Float?

        public init(personId: Int64, name: String, similarity: Float?) {
            self.personId = personId
            self.name = name
            self.similarity = similarity
        }

        /// Close enough to be worth suggesting first, even below the
        /// automatic-recognition threshold: the same person on another mic
        /// or another day lands here.
        public var isLikely: Bool {
            (similarity ?? -1) >= VoiceReview.likelySimilarity
        }
    }

    public var meetingId: Int64
    public var diarCluster: Int
    public var speechMs: Int
    /// Every known person, closest voice first.
    public var candidates: [Candidate]
    public var sample: VoiceSample?

    public init(meetingId: Int64, diarCluster: Int, speechMs: Int, candidates: [Candidate], sample: VoiceSample?) {
        self.meetingId = meetingId
        self.diarCluster = diarCluster
        self.speechMs = speechMs
        self.candidates = candidates
        self.sample = sample
    }
}

/// A stretch of audio where only that voice speaks.
public struct VoiceSample: Equatable, Sendable {
    public var startMs: Int
    public var durationMs: Int
}

public enum VoiceReview {
    /// Shorter voices are usually a cough, an echo or a fragment split off
    /// from someone else: not worth an interruption.
    public static let minSpeechMs = 3000
    /// Different people stay at or below ~0.32 in the AMI benchmark, the same
    /// person across meetings at 0.92 or more.
    public static let likelySimilarity: Float = 0.4
    static let sampleRangeMs = 1500...8000

    /// Unnamed voices of a meeting, most talkative first.
    public static func pending(
        meetingId: Int64,
        speakers: [MeetingSpeaker],
        segments: [Segment],
        persons: [Person],
        voiceprints: [Voiceprint]
    ) -> [PendingVoice] {
        speakers
            .filter { $0.meetingId == meetingId && $0.personId == nil && $0.speechMs >= minSpeechMs }
            .sorted { $0.speechMs != $1.speechMs ? $0.speechMs > $1.speechMs : $0.diarCluster < $1.diarCluster }
            .map { speaker in
                PendingVoice(
                    meetingId: meetingId,
                    diarCluster: speaker.diarCluster,
                    speechMs: speaker.speechMs,
                    candidates: candidates(for: speaker.embedding, persons: persons, voiceprints: voiceprints),
                    sample: sample(cluster: speaker.diarCluster, segments: segments)
                )
            }
    }

    /// People ranked by how close their voice is; the ones without a
    /// voiceprint follow in the given (alphabetical) order.
    public static func candidates(for embedding: Data?, persons: [Person], voiceprints: [Voiceprint]) -> [PendingVoice.Candidate] {
        let names = Dictionary(uniqueKeysWithValues: persons.compactMap { person in person.id.map { ($0, person.name) } })
        let ranked = embedding.map { SpeakerMatcher.rank(EmbeddingCodec.decode($0), voiceprints: voiceprints) } ?? []
        let compared = ranked.compactMap { match in
            names[match.personId].map { PendingVoice.Candidate(personId: match.personId, name: $0, similarity: match.similarity) }
        }
        let comparedIds = Set(compared.map(\.personId))
        let rest = persons.compactMap { person -> PendingVoice.Candidate? in
            guard let id = person.id, !comparedIds.contains(id) else { return nil }
            return PendingVoice.Candidate(personId: id, name: person.name, similarity: nil)
        }
        return compared + rest
    }

    /// The voice's longest uninterrupted stretch, a few seconds of it: long
    /// enough to recognize someone, short enough to name several in a row.
    public static func sample(cluster: Int, segments: [Segment]) -> VoiceSample? {
        let own = segments.filter { $0.channel == .system && $0.diarCluster == cluster }
        let blocks = Timeline.entries(segments: own, notes: [], maxPauseMs: 1000).compactMap { entry -> SpeechBlock? in
            if case .speech(let block) = entry { return block }
            return nil
        }
        guard let longest = blocks.max(by: { $0.endMs - $0.startMs < $1.endMs - $1.startMs }) else { return nil }
        let length = longest.endMs - longest.startMs
        return VoiceSample(
            startMs: longest.startMs,
            durationMs: min(sampleRangeMs.upperBound, max(sampleRangeMs.lowerBound, length))
        )
    }
}

/// When to ask about unnamed voices: as soon as a transcription finishes,
/// never during a call. Once dismissed (by hand or by its countdown) the
/// question waits in the menu until the next transcription.
public struct VoicePromptSchedule: Sendable {
    /// Meetings with voices still to name, oldest first.
    public private(set) var meetingIds: [Int64] = []
    private var isDismissed = false
    private var skipped: [Int64: Set<Int>] = [:]

    public init() {}

    /// A freshly transcribed meeting pops up even after a dismissal.
    public mutating func add(_ meetingId: Int64) {
        meetingIds.removeAll { $0 == meetingId }
        meetingIds.append(meetingId)
        isDismissed = false
    }

    public mutating func remove(_ meetingId: Int64) {
        meetingIds.removeAll { $0 == meetingId }
        skipped[meetingId] = nil
    }

    public mutating func dismiss() {
        isDismissed = true
    }

    /// Asked for from the menu.
    public mutating func resume() {
        isDismissed = false
    }

    /// "Don't know" for one voice: it is not asked about again.
    public mutating func skip(meetingId: Int64, diarCluster: Int) {
        skipped[meetingId, default: []].insert(diarCluster)
    }

    public func isSkipped(meetingId: Int64, diarCluster: Int) -> Bool {
        skipped[meetingId]?.contains(diarCluster) ?? false
    }

    /// The meeting to ask about now, if any: the most recent one, whose
    /// voices are freshest in memory.
    public func due(inCall: Bool) -> Int64? {
        guard !inCall, !isDismissed else { return nil }
        return meetingIds.last
    }
}

extension AppDatabase {
    public func pendingVoices(meetingId: Int64) throws -> [PendingVoice] {
        VoiceReview.pending(
            meetingId: meetingId,
            speakers: try speakers(meetingId: meetingId),
            segments: try segments(meetingId: meetingId),
            persons: try persons(),
            voiceprints: try voiceprints()
        )
    }
}
