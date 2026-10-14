import Foundation
import os

public struct ProcessingEngines: Sendable {
    public var recognizer: any SpeechRecognizing
    public var diarizer: any SpeakerDiarizing
    public var detector: any SpeechDetecting

    public init(recognizer: any SpeechRecognizing, diarizer: any SpeakerDiarizing, detector: any SpeechDetecting) {
        self.recognizer = recognizer
        self.diarizer = diarizer
        self.detector = detector
    }

    public static func live(modelsDirectory: URL) -> ProcessingEngines {
        ProcessingEngines(
            recognizer: WhisperKitRecognizer(modelsDirectory: modelsDirectory),
            diarizer: FluidDiarizer(),
            detector: FluidSpeechDetector()
        )
    }

    public func unload() async {
        await recognizer.unload()
        await diarizer.unload()
        await detector.unload()
    }
}

/// Turns a recorded meeting into a transcript: who spoke when (diarization on
/// the system channel, speech detection on the mic minus echo), then each
/// turn transcribed alone in its own language, invented text filtered out,
/// and known voices named.
public actor MeetingProcessor {
    public static let meSpeaker = "me"

    private let db: AppDatabase
    private let engines: ProcessingEngines
    private let extraVocabulary: @Sendable () -> [String]
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MeetingProcessor")

    /// `extraVocabulary` is read at each run: terms the user added in the
    /// settings (team jargon, product names).
    public init(db: AppDatabase, engines: ProcessingEngines, extraVocabulary: @escaping @Sendable () -> [String] = { [] }) {
        self.db = db
        self.engines = engines
        self.extraVocabulary = extraVocabulary
    }

    /// Releases the models (~2 GB) until the next meeting needs them.
    public func unloadModels() async {
        await engines.unload()
    }

    public func process(meetingId: Int64, progress: @Sendable (Double) -> Void = { _ in }) async throws {
        guard let meeting = try db.meeting(id: meetingId) else { return }
        try db.setStatus(.processing, meetingId: meetingId)
        do {
            let (speakers, segments) = try await transcribe(meeting, progress: progress)
            try db.saveTranscript(meetingId: meetingId, speakers: speakers, segments: segments)
            try applySpeakerMarks(meetingId: meetingId, segments: segments)
            FileLog.shared.append("processor: reunião \(meetingId) transcrita, \(segments.count) trechos, \(speakers.count) vozes")
        } catch {
            logger.error("Falha ao transcrever reunião \(meetingId): \(error)")
            FileLog.shared.append("processor: reunião \(meetingId) FALHOU: \(error)")
            try? db.setStatus(.failed, detail: String(describing: error), meetingId: meetingId)
            throw error
        }
    }

    private func transcribe(
        _ meeting: Meeting,
        progress: @Sendable (Double) -> Void
    ) async throws -> ([MeetingSpeaker], [Segment]) {
        let meetingId = meeting.id!
        let system = try meeting.audioSystemPath.map { try AudioSamples.load(URL(fileURLWithPath: $0)) } ?? []
        let micPath = meeting.audioMicPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let mic = try micPath.map { try AudioSamples.load(URL(fileURLWithPath: $0)) } ?? []
        progress(0.02)

        var diarization = Diarization(spans: [], embeddings: [:])
        var systemSpans: [SpeechSpan] = []
        if hasSound(system) {
            diarization = try await engines.diarizer.diarize(system)
            let detected = try await engines.detector.speechSpans(system)
            systemSpans = SpanAssembler.assemble(diarized: diarization.spans, detected: detected)
            FileLog.shared.append("processor: sistema \(diarization.spans.count) trechos do separador + \(systemSpans.count - diarization.spans.count) recuperados pelo detector de fala")
        }
        progress(0.1)

        var micSpans: [SpeechSpan] = []
        if hasSound(mic) {
            let detected = try await engines.detector.speechSpans(mic)
            micSpans = EchoGate.filter(spans: detected, mic: mic, system: system)
            FileLog.shared.append("processor: mic \(detected.count) trechos de fala, \(detected.count - micSpans.count) descartados como eco")
        }
        progress(0.15)

        // Language is decided per utterance (spans are cut at pauses), so a
        // speaker switching from Portuguese to Spanish mid-turn is caught;
        // turns are then built from same-speaker, same-language utterances.
        var spans = (systemSpans + micSpans).sorted { $0.start < $1.start }
        var distributions: [Int: [String: Double]] = [:]
        for (index, span) in spans.enumerated() where span.duration >= LanguagePicker.minDurationForDetection {
            let samples = AudioSamples.slice(span.speaker == Self.meSpeaker ? mic : system, from: span.start, to: span.end)
            let distribution = LanguagePicker.distribution(
                logProbs: try await engines.recognizer.languageLogProbs(samples)
            )
            distributions[index] = distribution
            let summary = distribution.sorted { $0.value > $1.value }
                .map { String(format: "%@ %.2f", $0.key, $0.value) }
                .joined(separator: ", ")
            FileLog.shared.append(String(format: "processor: idioma %.1f–%.1fs %@: %@", span.start, span.end, span.speaker, summary))
            progress(0.15 + 0.25 * Double(index + 1) / Double(spans.count))
        }
        for (index, language) in LanguagePicker.assign(spans, distributions: distributions).enumerated() {
            spans[index].language = language
            spans[index].isolated = distributions[index].map(LanguagePicker.isMixed) ?? false
        }
        let turns = TurnBuilder.turns(from: spans)

        let persons = try db.persons()
        let prompt = Vocabulary.prompt(names: persons.map(\.name), extra: extraVocabulary())
        let clusters = clusterIndexes(for: turns)

        var segments: [Segment] = []
        var languageTime: [String: [String: Double]] = [:]
        for (index, turn) in turns.enumerated() {
            let isMe = turn.speaker == Self.meSpeaker
            let language = turn.language ?? "pt"
            languageTime[turn.speaker, default: [:]][language, default: 0] += turn.duration
            let samples = AudioSamples.slice(isMe ? mic : system, from: turn.start, to: turn.end)
            let recognized = try await engines.recognizer.transcribe(samples, language: language, prompt: prompt)
            for piece in recognized where HallucinationFilter.keep(
                text: piece.text,
                avgLogprob: piece.avgLogprob,
                compressionRatio: piece.compressionRatio
            ) {
                let start = turn.start + piece.start
                let end = min(turn.end, turn.start + max(piece.end, piece.start))
                segments.append(Segment(
                    meetingId: meetingId,
                    tStartMs: Int(start * 1000),
                    tEndMs: Int(max(end, start) * 1000),
                    channel: isMe ? .mic : .system,
                    diarCluster: isMe ? nil : clusters[turn.speaker],
                    lang: language,
                    text: piece.text,
                    confidence: Double(exp(piece.avgLogprob))
                ))
            }
            progress(0.4 + 0.58 * Double(index + 1) / Double(turns.count))
        }

        let voiceprints = try db.voiceprints()
        var speakers: [MeetingSpeaker] = []
        for (label, cluster) in clusters.sorted(by: { $0.value < $1.value }) {
            let embedding = diarization.embeddings[label]
            let match = embedding.flatMap { SpeakerMatcher.match($0, voiceprints: voiceprints) }
            if let embedding {
                let similarities = SpeakerMatcher.rank(embedding, voiceprints: voiceprints)
                    .map { "\($0.personId): \(String(format: "%.2f", $0.similarity))" }
                FileLog.shared.append("processor: voz \(cluster) similaridades [\(similarities.joined(separator: ", "))] → \(match.map { "\($0.personId)" } ?? "desconhecida")")
            }
            let speechMs = turns.filter { $0.speaker == label }.reduce(0) { $0 + Int($1.duration * 1000) }
            speakers.append(MeetingSpeaker(
                meetingId: meetingId,
                personId: match?.personId,
                diarCluster: cluster,
                embedding: embedding.map(EmbeddingCodec.encode),
                speechMs: speechMs,
                lang: languageTime[label]?.max(by: { $0.value < $1.value })?.key
            ))
            if let personId = match?.personId {
                for index in segments.indices where segments[index].diarCluster == cluster {
                    segments[index].personId = personId
                }
            }
        }
        progress(1)
        return (speakers, segments)
    }

    /// "@Name" notes taken during the call name the voice speaking then; an
    /// explicit mark wins over automatic recognition.
    private func applySpeakerMarks(meetingId: Int64, segments: [Segment]) throws {
        let marks = SpeakerMarks.marks(from: try db.notes(meetingId: meetingId))
        guard !marks.isEmpty else { return }
        let turns = segments.compactMap { segment in
            segment.diarCluster.map { SpeakerMarks.Turn(startMs: segment.tStartMs, endMs: segment.tEndMs, cluster: $0) }
        }
        for (cluster, name) in SpeakerMarks.resolve(marks, turns: turns) {
            try db.assignSpeaker(meetingId: meetingId, diarCluster: cluster, personName: name)
            FileLog.shared.append("processor: voz \(cluster) nomeada \(name) por marcação durante a call")
        }
    }

    /// Stable small integers for diarizer labels, in order of first speech.
    private func clusterIndexes(for turns: [SpeechSpan]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for turn in turns where turn.speaker != Self.meSpeaker && indexes[turn.speaker] == nil {
            indexes[turn.speaker] = indexes.count
        }
        return indexes
    }

    private func hasSound(_ samples: [Float]) -> Bool {
        samples.count > AudioSamples.sampleRate && samples.contains { abs($0) > 0.001 }
    }
}
