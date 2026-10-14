import AVFoundation
import Foundation
import Testing
@testable import KuronekoCore

@Suite struct LiveCutTests {
    private func span(_ start: Double, _ end: Double, _ speaker: String = "S1") -> SpeechSpan {
        SpeechSpan(start: start, end: end, speaker: speaker)
    }

    @Test func cutsInTheLatestPauseOfBothChannels() {
        // The other side stops at 100 s, the user answers until 104 s and
        // the other side is mid-sentence when the batch ends.
        let speech = [span(10, 60), span(80, 100), span(100.1, 104, "me"), span(110, 120)]

        #expect(LiveCut.point(speech: speech, duration: 120) == 107)
    }

    @Test func cutsInTheSilenceAtTheEnd() {
        #expect(LiveCut.point(speech: [span(10, 60)], duration: 120) == 90)
    }

    @Test func takesEverythingWhenNobodyPausesOrNobodySpeaks() {
        #expect(LiveCut.point(speech: [span(0, 60), span(60.1, 120)], duration: 120) == 120)
        #expect(LiveCut.point(speech: [], duration: 120) == 120)
    }
}

@Suite struct LiveVoicesTests {
    @Test func followsAVoiceAcrossBatchesWhateverItsLabel() {
        var voices = LiveVoices()

        let first = voices.link(
            labels: ["S1", "S2"],
            embeddings: ["S1": [1, 0, 0], "S2": [0, 1, 0]],
            seconds: ["S1": 20, "S2": 40]
        )
        // Next batch: the diarizer names them the other way around, and a
        // third voice joins.
        let second = voices.link(
            labels: ["S1", "S2", "S3"],
            embeddings: ["S1": [0.1, 0.9, 0], "S2": [0.9, 0.1, 0], "S3": [0, 0, 1]],
            seconds: ["S1": 30, "S2": 10, "S3": 5]
        )

        #expect(first == ["S2": 0, "S1": 1])
        #expect(second == ["S1": 0, "S2": 1, "S3": 2])
        // Weighted by speech: 40 s at [0, 1, 0] and 30 s at [0.1, 0.9, 0].
        let merged = try! #require(voices.voices[0]).embedding
        #expect(abs(merged[0] - 3.0 / 70) < 0.0001)
        #expect(voices.voices[0]?.seconds == 70)
    }

    @Test func aVoiceWithoutEmbeddingIsNewAndItsIndexNeverComesBack() {
        var voices = LiveVoices()

        let first = voices.link(labels: ["S1"], embeddings: [:], seconds: ["S1": 5])
        let second = voices.link(labels: ["S1"], embeddings: ["S1": [1, 0]], seconds: ["S1": 5])

        #expect(first == ["S1": 0])
        #expect(second == ["S1": 1])
    }
}

@Suite struct VoiceRelabelTests {
    private func segment(_ start: Double, _ end: Double, cluster: Int?) -> Segment {
        Segment(
            meetingId: 1,
            tStartMs: Int(start * 1000),
            tEndMs: Int(end * 1000),
            channel: cluster == nil ? .mic : .system,
            diarCluster: cluster,
            text: "x"
        )
    }

    @Test func finalLabelsKeepTheIndexesUsedDuringTheCall() {
        let segments = [
            segment(0, 10, cluster: 1),
            segment(12, 20, cluster: 0),
            segment(22, 30, cluster: 0), // the call merged two people here
        ]
        let spans = [
            SpeechSpan(start: 0, end: 10, speaker: "S1"),
            SpeechSpan(start: 12, end: 20, speaker: "S2"),
            SpeechSpan(start: 22, end: 30, speaker: "S3"),
        ]

        let clusters = VoiceRelabel.clusters(for: spans, segments: segments)

        #expect(clusters == ["S1": 1, "S2": 0, "S3": 2])
    }

    @Test func aSegmentGoesToTheLabelCoveringMostOfIt() {
        let spans = [
            SpeechSpan(start: 0, end: 4, speaker: "S1"),
            SpeechSpan(start: 4, end: 10, speaker: "S2"),
            SpeechSpan(start: 30, end: 40, speaker: "S3"),
        ]

        #expect(VoiceRelabel.label(of: segment(2, 9, cluster: 0), in: spans) == "S2")
        // Covered by nobody: the closest voice in time.
        #expect(VoiceRelabel.label(of: segment(25, 27, cluster: 0), in: spans) == "S3")
    }
}

@Suite struct AppendTranscriptTests {
    @Test func aVoiceNamedMidCallKeepsItsPersonAndLendsItToEverySegment() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily")
        let id = try #require(meeting.id)
        let first = Segment(meetingId: id, tStartMs: 0, tEndMs: 1000, channel: .system, diarCluster: 0, text: "oi")
        try db.appendTranscript(meetingId: id, speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 1000)], segments: [first])
        let ana = try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: "Ana")

        let later = Segment(meetingId: id, tStartMs: 5000, tEndMs: 6000, channel: .system, diarCluster: 0, text: "tchau")
        try db.appendTranscript(meetingId: id, speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 2000)], segments: [later])

        let speaker = try #require(try db.speakers(meetingId: id).first)
        #expect(speaker.personId == ana.id)
        #expect(speaker.speechMs == 2000)
        #expect(try db.segments(meetingId: id).map(\.personId) == [ana.id, ana.id])
        #expect(try db.meeting(id: id)?.status == .recording)
    }
}

// MARK: - A whole call, transcribed while it is recorded

/// Voices are told apart by loudness: Ana speaks at 0.2, Bruno at 0.5.
private enum FakeVoices {
    static func isAna(_ samples: ArraySlice<Float>) -> Bool {
        (samples.map(abs).max() ?? 0) < 0.35
    }

    /// Stretches of sound, as 10 ms frames grouped across short gaps.
    static func regions(_ samples: [Float]) -> [(start: Double, end: Double, ana: Bool)] {
        var regions: [(start: Double, end: Double, ana: Bool)] = []
        let frame = 160
        for start in stride(from: 0, to: samples.count, by: frame) {
            let chunk = samples[start..<min(samples.count, start + frame)]
            guard (chunk.map(abs).max() ?? 0) > 0.01 else { continue }
            let time = Double(start) / 16000
            if let last = regions.last, time - last.end < 0.3 {
                regions[regions.count - 1].end = time + 0.01
            } else {
                regions.append((time, time + 0.01, isAna(chunk)))
            }
        }
        return regions
    }
}

private struct FakeDetector: SpeechDetecting {
    func speechSpans(_ samples: [Float]) async throws -> [SpeechSpan] {
        FakeVoices.regions(samples).map { SpeechSpan(start: $0.start, end: $0.end, speaker: "me") }
    }

    func unload() async {}
}

/// Labels voices in order of appearance, like a real diarizer: the same
/// person can be "S1" in one batch and "S2" in the next.
private struct FakeDiarizer: SpeakerDiarizing {
    func diarize(_ samples: [Float]) async throws -> Diarization {
        var labels: [Bool: String] = [:]
        var spans: [SpeechSpan] = []
        var embeddings: [String: [Float]] = [:]
        for region in FakeVoices.regions(samples) {
            let label = labels[region.ana] ?? "S\(labels.count + 1)"
            labels[region.ana] = label
            embeddings[label] = region.ana ? [1, 0] : [0, 1]
            spans.append(SpeechSpan(start: region.start, end: region.end, speaker: label))
        }
        return Diarization(spans: spans, embeddings: embeddings)
    }

    func unload() async {}
}

private struct FakeRecognizer: SpeechRecognizing {
    func languageLogProbs(_ samples: [Float]) async throws -> [String: Float] {
        ["pt": 0, "es": -10, "en": -10]
    }

    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [RecognizedSegment] {
        let text = FakeVoices.isAna(samples[...]) ? "fala da Ana" : "fala do Bruno"
        return [RecognizedSegment(start: 0, end: Double(samples.count) / 16000, text: text, avgLogprob: -0.1, compressionRatio: 1.2)]
    }

    func unload() async {}
}

/// Whisper's first answer for the audio is empty; it gets it right when asked again.
private actor FlakyRecognizer: SpeechRecognizing {
    private var calls = 0

    func languageLogProbs(_ samples: [Float]) async throws -> [String: Float] {
        ["pt": 0, "es": -10, "en": -10]
    }

    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [RecognizedSegment] {
        calls += 1
        let text = calls == 1 ? "" : "fala da Ana"
        return [RecognizedSegment(start: 0, end: Double(samples.count) / 16000, text: text, avgLogprob: -0.1, compressionRatio: 1.2)]
    }

    func unload() async {}
}

@Suite struct LiveMeetingTests {
    private func seconds(_ segment: Segment) -> Int {
        (segment.tStartMs + 500) / 1000
    }

    /// Writes `speech` (start, end, amplitude) from `from` to `to` seconds.
    private func record(_ writer: ResamplingWavWriter, from: Double, to: Double, speech: [(Double, Double, Float)]) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount((to - from) * 16000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            let time = from + Double(index) / 16000
            let amplitude = speech.first { time >= $0.0 && time < $0.1 }?.2 ?? 0
            samples[index] = amplitude * sinf(Float(index) * 2 * .pi * 200 / 16000)
        }
        try writer.append(buffer)
    }

    @Test func transcribesInBatchesAndSettlesVoicesAtTheEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appendingPathComponent("system.wav")
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily")
        let id = try #require(meeting.id)
        try db.updateAudio(meetingId: id, startedAt: Date(), micPath: nil, systemPath: systemURL.path)
        let processor = MeetingProcessor(
            db: db,
            engines: ProcessingEngines(recognizer: FakeRecognizer(), diarizer: FakeDiarizer(), detector: FakeDetector())
        )
        let ana: Float = 0.2, bruno: Float = 0.5
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let writer = try ResamplingWavWriter(inputFormat: format, fileURL: systemURL)

        // 250 s in; Bruno is mid-sentence at the end.
        try record(writer, from: 0, to: 250, speech: [(10, 20, ana), (30, 45, bruno), (100, 118, bruno), (130, 140, ana), (240, 255, bruno)])
        #expect(await processor.advanceLive(meetingId: id))
        // The batch stops in the pause before Bruno's unfinished sentence.
        #expect(try db.segments(meetingId: id).map(seconds) == [10, 30, 100, 130])
        #expect(await !processor.advanceLive(meetingId: id))

        let anaCluster = try #require(try db.segments(meetingId: id).first?.diarCluster)
        try db.assignSpeaker(meetingId: id, diarCluster: anaCluster, personName: "Ana")

        // Bruno speaks first in the next batch, so the diarizer calls him S1.
        try record(writer, from: 250, to: 400, speech: [(240, 255, bruno), (300, 310, ana), (330, 340, bruno)])
        #expect(await processor.advanceLive(meetingId: id))
        #expect(await processor.liveMeetingIds() == [id])

        writer.finish()
        try db.endMeeting(id)
        try await processor.process(meetingId: id)

        let segments = try db.segments(meetingId: id)
        #expect(segments.map(seconds) == [10, 30, 100, 130, 240, 300, 330])
        for segment in segments {
            #expect((segment.diarCluster == anaCluster) == (segment.text == "fala da Ana"))
        }
        let speakers = try db.speakers(meetingId: id)
        let anaId = try #require(try db.persons().first { $0.name == "Ana" }?.id)
        #expect(speakers.count == 2)
        #expect(speakers.first { $0.diarCluster == anaCluster }?.personId == anaId)
        #expect(segments.filter { $0.text == "fala da Ana" }.allSatisfy { $0.personId == anaId })
        #expect(try db.meeting(id: id)?.status == .done)
        #expect(await processor.liveMeetingIds().isEmpty)
    }

    @Test func aTurnThatComesBackEmptyIsTranscribedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appendingPathComponent("system.wav")
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Daily").id)
        try db.updateAudio(meetingId: id, startedAt: Date(), micPath: nil, systemPath: systemURL.path)
        let processor = MeetingProcessor(
            db: db,
            engines: ProcessingEngines(recognizer: FlakyRecognizer(), diarizer: FakeDiarizer(), detector: FakeDetector())
        )
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let writer = try ResamplingWavWriter(inputFormat: format, fileURL: systemURL)
        try record(writer, from: 0, to: 30, speech: [(5, 15, 0.2)])
        writer.finish()
        try db.endMeeting(id)

        try await processor.process(meetingId: id)

        #expect(try db.segments(meetingId: id).map(\.text) == ["fala da Ana"])
    }

    @Test func aShortCallIsTranscribedWholeAtTheEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appendingPathComponent("system.wav")
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Rápida").id)
        try db.updateAudio(meetingId: id, startedAt: Date(), micPath: nil, systemPath: systemURL.path)
        let processor = MeetingProcessor(
            db: db,
            engines: ProcessingEngines(recognizer: FakeRecognizer(), diarizer: FakeDiarizer(), detector: FakeDetector())
        )
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let writer = try ResamplingWavWriter(inputFormat: format, fileURL: systemURL)

        try record(writer, from: 0, to: 60, speech: [(5, 15, 0.2), (20, 30, 0.5)])
        #expect(await !processor.advanceLive(meetingId: id))
        writer.finish()
        try db.endMeeting(id)
        try await processor.process(meetingId: id)

        #expect(try db.segments(meetingId: id).map(\.text) == ["fala da Ana", "fala do Bruno"])
        #expect(try db.speakers(meetingId: id).count == 2)
        #expect(try db.meeting(id: id)?.status == .done)
    }
}
