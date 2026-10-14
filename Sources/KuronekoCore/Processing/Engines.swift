import CoreML
import FluidAudio
import Foundation
import WhisperKit

public struct RecognizedSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var avgLogprob: Float
    public var compressionRatio: Float

    public init(start: Double, end: Double, text: String, avgLogprob: Float, compressionRatio: Float) {
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
    }
}

public struct Diarization: Sendable {
    public var spans: [SpeechSpan]
    /// One representative embedding per speaker label.
    public var embeddings: [String: [Float]]

    public init(spans: [SpeechSpan], embeddings: [String: [Float]]) {
        self.spans = spans
        self.embeddings = embeddings
    }
}

public protocol SpeechRecognizing: Sendable {
    /// Log-probabilities of each language code for the given audio.
    func languageLogProbs(_ samples: [Float]) async throws -> [String: Float]
    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [RecognizedSegment]
    func unload() async
}

public protocol SpeakerDiarizing: Sendable {
    func diarize(_ samples: [Float]) async throws -> Diarization
    func unload() async
}

public protocol SpeechDetecting: Sendable {
    func speechSpans(_ samples: [Float]) async throws -> [SpeechSpan]
    func unload() async
}

// MARK: - WhisperKit

/// Models load lazily on first use (and download on the very first run) and
/// are released with `unload()`, so ~1.5 GB is not held while idle.
public actor WhisperKitRecognizer: SpeechRecognizing {
    public static let defaultModel = "large-v3-v20240930_turbo"

    private let modelsDirectory: URL
    private let model: String
    private var whisper: WhisperKit?

    public init(modelsDirectory: URL, model: String = WhisperKitRecognizer.defaultModel) {
        self.modelsDirectory = modelsDirectory
        self.model = model
    }

    /// Scores of the candidate languages for one utterance. WhisperKit's
    /// `detectLangauge` only reports the winning language, which hides how
    /// close Portuguese and Spanish were; this runs the same first decoder
    /// step and reads the raw scores of the candidate language tokens.
    public func languageLogProbs(_ samples: [Float]) async throws -> [String: Float] {
        let kit = try await loaded()
        guard let tokenizer = kit.tokenizer else { throw WhisperError.tokenizerUnavailable() }
        let windowSamples = kit.featureExtractor.windowSamples ?? 480_000
        guard let window = kit.audioProcessor.padOrTrim(fromArray: samples, startAt: 0, toLength: windowSamples),
              let mel = try await kit.featureExtractor.logMelSpectrogram(fromAudio: window),
              let encoded = try await kit.audioEncoder.encodeFeatures(mel) else {
            throw WhisperError.transcriptionFailed("Falha ao codificar o áudio para detectar o idioma")
        }
        let inputs = try kit.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken])
        var tokens: [String: Int] = [:]
        for code in LanguagePicker.candidates {
            tokens[code] = tokenizer.convertTokenToId("<|\(code)|>")
        }
        let sampler = LanguageScoreSampler(tokens: tokens)
        _ = try await kit.textDecoder.detectLanguage(
            from: encoded,
            using: inputs,
            sampler: sampler,
            options: DecodingOptions(),
            temperature: 0
        )
        return sampler.scores
    }

    public func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [RecognizedSegment] {
        let kit = try await loaded()
        let promptTokens = kit.tokenizer.map { tokenizer in
            tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            promptTokens: promptTokens,
            chunkingStrategy: ChunkingStrategy.none
        )
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).map { segment in
            RecognizedSegment(
                start: Double(segment.start),
                end: Double(segment.end),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                avgLogprob: segment.avgLogprob,
                compressionRatio: segment.compressionRatio
            )
        }
    }

    public func unload() async {
        await whisper?.unloadModels()
        whisper = nil
    }

    private func loaded() async throws -> WhisperKit {
        if let whisper { return whisper }
        let config = WhisperKitConfig(
            model: model,
            downloadBase: modelsDirectory,
            tokenizerFolder: modelsDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        whisper = kit
        return kit
    }
}

/// Captures the decoder's scores for a few language tokens on the language
/// detection step, then answers like a greedy sampler would.
final class LanguageScoreSampler: TokenSampling, @unchecked Sendable {
    private let tokens: [String: Int]
    private let lock = NSLock()
    private var captured: [String: Float] = [:]

    init(tokens: [String: Int]) {
        self.tokens = tokens
    }

    var scores: [String: Float] {
        lock.withLock { captured }
    }

    func update(tokens current: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        var scores: [String: Float] = [:]
        var best: (token: Int, score: Float)?
        for (code, token) in tokens where token < logits.count {
            let score = logits[token].floatValue
            scores[code] = score
            if best == nil || score > best!.score {
                best = (token, score)
            }
        }
        lock.withLock { captured = scores }
        let next = best?.token ?? current.last ?? 0
        return SamplingResult(tokens: current + [next], logProbs: logProbs + [0], completed: true)
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        SamplingResult(tokens: tokens, logProbs: logProbs, completed: true)
    }
}

// MARK: - FluidAudio

/// Offline pyannote community-1 pipeline (segmentation + VBx clustering) on
/// the Neural Engine. Runs on the system channel only, where every voice is
/// a remote participant.
///
/// `OfflineDiarizerManager` is not Sendable, so this is a class instead of an
/// actor; `MeetingProcessor` (an actor) is its only caller and runs one
/// meeting at a time, and the lock covers the lazy load.
public final class FluidDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var manager: OfflineDiarizerManager?

    public init() {}

    public func diarize(_ samples: [Float]) async throws -> Diarization {
        let manager = try await loaded()
        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            // Sound but nobody talking: a quiet batch of a call.
            return Diarization(spans: [], embeddings: [:])
        }
        let spans = result.segments.map { segment in
            SpeechSpan(
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds),
                speaker: segment.speakerId
            )
        }
        var embeddings = result.speakerDatabase ?? [:]
        // Fall back to averaging segment embeddings when the pipeline does
        // not expose per-speaker centroids.
        for (speaker, segments) in Dictionary(grouping: result.segments, by: \.speakerId)
        where embeddings[speaker] == nil {
            let vectors = segments.map(\.embedding).filter { !$0.isEmpty }
            guard let dimension = vectors.first?.count else { continue }
            var mean = [Float](repeating: 0, count: dimension)
            for vector in vectors where vector.count == dimension {
                for index in 0..<dimension { mean[index] += vector[index] / Float(vectors.count) }
            }
            embeddings[speaker] = mean
        }
        return Diarization(spans: spans, embeddings: embeddings)
    }

    public func unload() async {
        lock.withLock { manager = nil }
    }

    private func loaded() async throws -> OfflineDiarizerManager {
        if let cached = lock.withLock({ self.manager }) { return cached }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        lock.withLock { self.manager = manager }
        return manager
    }
}

/// Silero VAD, used on the mic channel ("me" has no one to separate from).
public actor FluidSpeechDetector: SpeechDetecting {
    private var vad: VadManager?

    public init() {}

    public func speechSpans(_ samples: [Float]) async throws -> [SpeechSpan] {
        let vad = try await loaded()
        let config = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.6, maxSpeechDuration: 30)
        return try await vad.segmentSpeech(samples, config: config).map { segment in
            SpeechSpan(start: segment.startTime, end: segment.endTime, speaker: MeetingProcessor.meSpeaker)
        }
    }

    public func unload() async {
        vad = nil
    }

    private func loaded() async throws -> VadManager {
        if let vad { return vad }
        let vad = try await VadManager()
        self.vad = vad
        return vad
    }
}
