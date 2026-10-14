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
///
/// A meeting being recorded is transcribed in batches as it goes
/// (`advanceLive`); when it ends, `process` only does what is left and
/// re-attributes the speech with a diarization of the whole recording.
/// Without that history (the app restarted, a batch failed) `process`
/// transcribes the whole recording at once.
///
/// Callers run one call at a time (`ProcessingQueue`): the engines are not
/// meant to serve two meetings at once.
public actor MeetingProcessor {
    public static let meSpeaker = "me"
    /// Audio a batch gathers during the call before it is transcribed.
    public static let liveBatchSeconds = 120.0
    /// The last moments written may still be in flight on the other channel.
    static let liveMargin = 2.0

    /// A meeting transcribed in batches so far.
    struct LiveTranscript {
        var processedUntil = 0.0
        var voices = LiveVoices()
        var speechSeconds: [Int: Double] = [:]
        var languageSeconds: [Int: [String: Double]] = [:]
        /// People recognized automatically during the call; anyone else on a
        /// voice was named by the user and stays.
        var recognized: [Int: Int64] = [:]
        var failed = false
    }

    private let db: AppDatabase
    private let engines: ProcessingEngines
    private let extraVocabulary: @Sendable () -> [String]
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MeetingProcessor")
    private var live: [Int64: LiveTranscript] = [:]

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

    /// Meetings transcribed in batches during the call, with only the end
    /// left to do once it is over.
    public func liveMeetingIds() -> Set<Int64> {
        Set(live.filter { !$0.value.failed }.keys)
    }

    public func process(meetingId: Int64, progress: @Sendable (Double) -> Void = { _ in }) async throws {
        guard let meeting = try db.meeting(id: meetingId) else { return }
        try db.setStatus(.processing, meetingId: meetingId)
        if let state = live.removeValue(forKey: meetingId), !state.failed {
            do {
                try await finishLive(meeting, state, progress: progress)
                return
            } catch {
                logger.error("Falha ao concluir a reunião \(meetingId) transcrita durante a call: \(error)")
                FileLog.shared.append("live: reunião \(meetingId) não concluiu (\(error)); transcrevendo tudo de novo")
            }
        }
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
        var systemDetected: [SpeechSpan] = []
        if hasSound(system) {
            diarization = try await engines.diarizer.diarize(system)
            systemDetected = try await engines.detector.speechSpans(system)
        }
        progress(0.1)
        let micDetected = hasSound(mic) ? try await engines.detector.speechSpans(mic) : []
        let turns = try await speechTurns(
            diarized: diarization.spans,
            systemDetected: systemDetected,
            micDetected: micDetected,
            system: system,
            mic: mic,
            progress: { progress(0.15 + 0.25 * $0) }
        )
        let clusters = clusterIndexes(for: turns)
        let (segments, languageTime) = try await recognize(
            turns,
            system: system,
            mic: mic,
            offset: 0,
            clusters: clusters,
            meetingId: meetingId,
            progress: { progress(0.4 + 0.58 * $0) }
        )

        let voiceprints = try db.voiceprints()
        var speakers: [MeetingSpeaker] = []
        var named = segments
        for (label, cluster) in clusters.sorted(by: { $0.value < $1.value }) {
            let embedding = diarization.embeddings[label]
            let match = embedding.flatMap { recognize(voice: cluster, embedding: $0, voiceprints: voiceprints) }
            let speechMs = turns.filter { $0.speaker == label }.reduce(0) { $0 + Int($1.duration * 1000) }
            speakers.append(MeetingSpeaker(
                meetingId: meetingId,
                personId: match,
                diarCluster: cluster,
                embedding: embedding.map(EmbeddingCodec.encode),
                speechMs: speechMs,
                lang: languageTime[label]?.max(by: { $0.value < $1.value })?.key
            ))
            if let match {
                for index in named.indices where named[index].diarCluster == cluster {
                    named[index].personId = match
                }
            }
        }
        progress(1)
        return (speakers, named)
    }

    // MARK: - During the call

    /// Transcribes what the meeting being recorded gathered since its last
    /// batch, once there is `liveBatchSeconds` of it. Returns whether it did;
    /// after a failure the meeting waits to be transcribed whole at the end.
    public func advanceLive(meetingId: Int64) async -> Bool {
        var state = live[meetingId] ?? LiveTranscript()
        guard !state.failed,
              let meeting = try? db.meeting(id: meetingId), meeting.status == .recording,
              let systemPath = meeting.audioSystemPath,
              let recorded = try? AudioSamples.recordedDuration(URL(fileURLWithPath: systemPath)),
              recorded - Self.liveMargin - state.processedUntil >= Self.liveBatchSeconds else { return false }
        do {
            try await transcribeBatch(meeting, until: recorded - Self.liveMargin, final: false, state: &state)
            live[meetingId] = state
            return true
        } catch {
            logger.error("Falha ao transcrever a reunião \(meetingId) durante a call: \(error)")
            FileLog.shared.append("live: reunião \(meetingId) FALHOU durante a call: \(error)")
            state.failed = true
            live[meetingId] = state
            return false
        }
    }

    /// One batch: `state.processedUntil` up to `end` seconds, cut earlier at
    /// a pause unless it is the last one.
    private func transcribeBatch(_ meeting: Meeting, until end: Double, final: Bool, state: inout LiveTranscript) async throws {
        let meetingId = meeting.id!
        let from = state.processedUntil
        guard let systemPath = meeting.audioSystemPath, end > from else { return }
        var system = try AudioSamples.load(URL(fileURLWithPath: systemPath), from: from, to: end)
        let micPath = meeting.audioMicPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        var mic = try micPath.map { try AudioSamples.load(URL(fileURLWithPath: $0), from: from, to: end) } ?? []
        var systemDetected = hasSound(system) ? try await engines.detector.speechSpans(system) : []
        var micDetected = hasSound(mic) ? try await engines.detector.speechSpans(mic) : []

        let duration = Double(system.count) / Double(AudioSamples.sampleRate)
        let cut = final ? duration : LiveCut.point(speech: systemDetected + micDetected, duration: duration)
        system = Array(system.prefix(Int(cut * Double(AudioSamples.sampleRate))))
        mic = Array(mic.prefix(system.count))
        systemDetected = clip(systemDetected, at: cut)
        micDetected = clip(micDetected, at: cut)

        var diarization = Diarization(spans: [], embeddings: [:])
        if hasSound(system) {
            diarization = try await engines.diarizer.diarize(system)
        }
        var seconds: [String: Double] = [:]
        for span in diarization.spans {
            seconds[span.speaker, default: 0] += span.duration
        }
        let links = state.voices.link(
            labels: Set(diarization.spans.map(\.speaker)),
            embeddings: diarization.embeddings,
            seconds: seconds
        )
        // Voices carry their index across batches from here on.
        let diarized = diarization.spans.map { span in
            SpeechSpan(start: span.start, end: span.end, speaker: links[span.speaker].map { "c\($0)" } ?? span.speaker)
        }
        let turns = try await speechTurns(
            diarized: diarized,
            systemDetected: systemDetected,
            micDetected: micDetected,
            system: system,
            mic: mic,
            progress: { _ in }
        )
        let clusters = Dictionary(uniqueKeysWithValues: Set(links.values).map { ("c\($0)", $0) })
        let (segments, languageTime) = try await recognize(
            turns,
            system: system,
            mic: mic,
            offset: from,
            clusters: clusters,
            meetingId: meetingId,
            progress: { _ in }
        )

        for turn in turns {
            guard let cluster = clusters[turn.speaker] else { continue }
            state.speechSeconds[cluster, default: 0] += turn.duration
        }
        for (label, languages) in languageTime {
            guard let cluster = clusters[label] else { continue }
            for (language, time) in languages {
                state.languageSeconds[cluster, default: [:]][language, default: 0] += time
            }
        }
        let voiceprints = try db.voiceprints()
        var speakers: [MeetingSpeaker] = []
        for cluster in Set(clusters.values).sorted() {
            let voice = state.voices.voices[cluster]
            if state.recognized[cluster] == nil, let voice,
               let match = recognize(voice: cluster, embedding: voice.embedding, voiceprints: voiceprints) {
                state.recognized[cluster] = match
            }
            speakers.append(MeetingSpeaker(
                meetingId: meetingId,
                personId: state.recognized[cluster],
                diarCluster: cluster,
                embedding: voice.map { EmbeddingCodec.encode($0.embedding) },
                speechMs: Int((state.speechSeconds[cluster] ?? 0) * 1000),
                lang: state.languageSeconds[cluster]?.max(by: { $0.value < $1.value })?.key
            ))
        }
        try db.appendTranscript(meetingId: meetingId, speakers: speakers, segments: segments)
        state.processedUntil = from + cut
        FileLog.shared.append(String(
            format: "live: reunião %lld %.0f–%.0fs, %d trechos, vozes %@",
            meetingId, from, from + cut, segments.count, links.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: " ")
        ))
    }

    /// The end of a meeting transcribed during the call: the last batch, then
    /// a diarization of the whole recording decides who said each segment.
    private func finishLive(_ meeting: Meeting, _ state: LiveTranscript, progress: @Sendable (Double) -> Void) async throws {
        let meetingId = meeting.id!
        var state = state
        guard let systemPath = meeting.audioSystemPath else { return }
        let systemURL = URL(fileURLWithPath: systemPath)
        try await transcribeBatch(meeting, until: try AudioSamples.recordedDuration(systemURL), final: true, state: &state)
        progress(0.3)

        let system = try AudioSamples.load(systemURL)
        let diarization = hasSound(system)
            ? try await engines.diarizer.diarize(system)
            : Diarization(spans: [], embeddings: [:])
        progress(0.8)

        var segments = try db.segments(meetingId: meetingId)
        let before = Dictionary(uniqueKeysWithValues: try db.speakers(meetingId: meetingId).map { ($0.diarCluster, $0) })
        let clusters = VoiceRelabel.clusters(for: diarization.spans, segments: segments.filter { $0.channel == .system })
        for index in segments.indices where segments[index].channel == .system {
            if let label = VoiceRelabel.label(of: segments[index], in: diarization.spans), let cluster = clusters[label] {
                segments[index].diarCluster = cluster
            }
        }

        let labels = Dictionary(uniqueKeysWithValues: clusters.map { ($0.value, $0.key) })
        let voiceprints = try db.voiceprints()
        var speakers: [MeetingSpeaker] = []
        for cluster in Set(segments.compactMap(\.diarCluster)).sorted() {
            // A voice the final diarization did not hear keeps what the call found.
            guard let label = labels[cluster] else {
                if let speaker = before[cluster] { speakers.append(speaker) }
                continue
            }
            let embedding = diarization.embeddings[label]
            let previous = before[cluster]?.personId
            let namedByUser = previous != nil && previous != state.recognized[cluster]
            let personId = namedByUser ? previous : embedding.flatMap { recognize(voice: cluster, embedding: $0, voiceprints: voiceprints) }
            var languages: [String: Int] = [:]
            for segment in segments where segment.diarCluster == cluster {
                languages[segment.lang ?? "pt", default: 0] += segment.tEndMs - segment.tStartMs
            }
            speakers.append(MeetingSpeaker(
                meetingId: meetingId,
                personId: personId,
                diarCluster: cluster,
                embedding: embedding.map(EmbeddingCodec.encode),
                speechMs: diarization.spans.filter { $0.speaker == label }.reduce(0) { $0 + Int($1.duration * 1000) },
                lang: languages.max(by: { $0.value < $1.value })?.key
            ))
        }
        let people = Dictionary(uniqueKeysWithValues: speakers.map { ($0.diarCluster, $0.personId) })
        for index in segments.indices {
            segments[index].personId = segments[index].diarCluster.flatMap { people[$0] ?? nil }
        }
        try db.saveTranscript(meetingId: meetingId, speakers: speakers, segments: segments)
        try applySpeakerMarks(meetingId: meetingId, segments: segments)
        progress(1)
        FileLog.shared.append("processor: reunião \(meetingId) concluída depois da call, \(segments.count) trechos, \(speakers.count) vozes")
    }

    // MARK: - Stages

    /// Who spoke when, in turns of one voice and one language: the system
    /// channel's diarization completed by speech detection, the mic minus
    /// echo, and the language of each utterance.
    private func speechTurns(
        diarized: [SpeechSpan],
        systemDetected: [SpeechSpan],
        micDetected: [SpeechSpan],
        system: [Float],
        mic: [Float],
        progress: (Double) -> Void
    ) async throws -> [SpeechSpan] {
        var systemSpans: [SpeechSpan] = []
        if !diarized.isEmpty || !systemDetected.isEmpty {
            systemSpans = SpanAssembler.assemble(diarized: diarized, detected: systemDetected)
            FileLog.shared.append("processor: sistema \(diarized.count) trechos do separador + \(systemSpans.count - diarized.count) recuperados pelo detector de fala")
        }

        var micSpans: [SpeechSpan] = []
        if !micDetected.isEmpty {
            micSpans = EchoGate.filter(spans: micDetected, mic: mic, system: system)
            FileLog.shared.append("processor: mic \(micDetected.count) trechos de fala, \(micDetected.count - micSpans.count) descartados como eco")
        }

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
            progress(Double(index + 1) / Double(spans.count))
        }
        for (index, language) in LanguagePicker.assign(spans, distributions: distributions).enumerated() {
            spans[index].language = language
            spans[index].isolated = distributions[index].map(LanguagePicker.isMixed) ?? false
        }
        return TurnBuilder.turns(from: spans)
    }

    /// Each turn transcribed alone in its language, invented text dropped;
    /// segment times are `offset` seconds into the recording. Also returns
    /// how long each voice spoke each language.
    private func recognize(
        _ turns: [SpeechSpan],
        system: [Float],
        mic: [Float],
        offset: Double,
        clusters: [String: Int],
        meetingId: Int64,
        progress: (Double) -> Void
    ) async throws -> ([Segment], [String: [String: Double]]) {
        let persons = try db.persons()
        let prompt = Vocabulary.prompt(names: persons.map(\.name), extra: extraVocabulary())
        var segments: [Segment] = []
        var languageTime: [String: [String: Double]] = [:]
        for (index, turn) in turns.enumerated() {
            let isMe = turn.speaker == Self.meSpeaker
            let language = turn.language ?? "pt"
            languageTime[turn.speaker, default: [:]][language, default: 0] += turn.duration
            let samples = AudioSamples.slice(isMe ? mic : system, from: turn.start, to: turn.end)
            var pieces = try await engines.recognizer.transcribe(samples, language: language, prompt: prompt).filter(Self.keep)
            if pieces.isEmpty, turn.duration >= Self.retryEmptyTurnsFrom {
                // Whisper falls back to sampling when a decode looks bad, so
                // the same audio can come back empty once and right the next
                // time: 1 in 6 runs on 28 s of the user's own speech.
                pieces = try await engines.recognizer.transcribe(samples, language: language, prompt: prompt).filter(Self.keep)
                FileLog.shared.append(String(format: "processor: turno %.1f–%.1fs %@ veio vazio; de novo: %d trechos", offset + turn.start, offset + turn.end, turn.speaker, pieces.count))
            }
            for piece in pieces {
                let start = turn.start + piece.start
                let end = min(turn.end, turn.start + max(piece.end, piece.start))
                segments.append(Segment(
                    meetingId: meetingId,
                    tStartMs: Int((offset + start) * 1000),
                    tEndMs: Int((offset + max(end, start)) * 1000),
                    channel: isMe ? .mic : .system,
                    diarCluster: isMe ? nil : clusters[turn.speaker],
                    lang: language,
                    text: piece.text,
                    confidence: Double(exp(piece.avgLogprob))
                ))
            }
            progress(Double(index + 1) / Double(turns.count))
        }
        return (segments, languageTime)
    }

    /// The known person a voice belongs to, logged with every similarity so
    /// the threshold can be checked against real calls.
    private func recognize(voice cluster: Int, embedding: [Float], voiceprints: [Voiceprint]) -> Int64? {
        let match = SpeakerMatcher.match(embedding, voiceprints: voiceprints)
        let similarities = SpeakerMatcher.rank(embedding, voiceprints: voiceprints)
            .map { "\($0.personId): \(String(format: "%.2f", $0.similarity))" }
        FileLog.shared.append("processor: voz \(cluster) similaridades [\(similarities.joined(separator: ", "))] → \(match.map { "\($0.personId)" } ?? "desconhecida")")
        return match?.personId
    }

    /// Turns at least this long are transcribed again when nothing came out.
    static let retryEmptyTurnsFrom = 2.0

    private static func keep(_ piece: RecognizedSegment) -> Bool {
        HallucinationFilter.keep(text: piece.text, avgLogprob: piece.avgLogprob, compressionRatio: piece.compressionRatio)
    }

    private func clip(_ spans: [SpeechSpan], at end: Double) -> [SpeechSpan] {
        spans.compactMap { span in
            guard span.start < end else { return nil }
            var span = span
            span.end = min(span.end, end)
            return span
        }
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
