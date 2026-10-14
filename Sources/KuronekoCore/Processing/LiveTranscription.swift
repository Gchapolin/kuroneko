import Foundation

/// Where a batch of a meeting still being recorded ends.
public enum LiveCut {
    static let minPause = 0.3

    /// In the latest pause of both channels (`speech` holds the speech of
    /// both), so no utterance is split between two batches; at `duration`
    /// when nobody paused at all.
    public static func point(speech: [SpeechSpan], duration: Double) -> Double {
        var talking: [(start: Double, end: Double)] = []
        for span in speech.sorted(by: { $0.start < $1.start }) {
            if let last = talking.last, span.start < last.end + minPause {
                talking[talking.count - 1].end = max(last.end, span.end)
            } else {
                talking.append((span.start, span.end))
            }
        }
        guard let last = talking.last else { return duration }
        if duration - last.end >= minPause {
            return (last.end + duration) / 2
        }
        guard talking.count > 1 else { return duration }
        return (talking[talking.count - 2].end + last.start) / 2
    }
}

/// The voices heard so far in a meeting being recorded. Each batch is
/// diarized on its own, with labels of its own; a voice is followed from one
/// batch to the next by its embedding, the way known people are recognized
/// across meetings.
public struct LiveVoices: Sendable {
    public struct Voice: Equatable, Sendable {
        public var embedding: [Float]
        public var seconds: Double
    }

    /// Below this a batch's voice is someone not heard before. On the AMI
    /// benchmark in 2-minute batches the same person scored 0.80–0.98
    /// between batches and different people at most 0.48.
    static let sameVoice: Float = 0.65

    public private(set) var voices: [Int: Voice] = [:]
    private var lastIndex = -1

    public init() {}

    /// The cluster index of each label of a batch, longest speakers first.
    /// A label without an embedding cannot be compared and is a new voice.
    public mutating func link(labels: Set<String>, embeddings: [String: [Float]], seconds: [String: Double]) -> [String: Int] {
        var links: [String: Int] = [:]
        let ordered = labels.sorted { (seconds[$0] ?? 0, $1) > (seconds[$1] ?? 0, $0) }
        for label in ordered {
            guard let embedding = embeddings[label], !embedding.isEmpty else {
                links[label] = newIndex()
                continue
            }
            let closest = voices
                .map { (index: $0.key, similarity: SpeakerMatcher.cosine(embedding, $0.value.embedding)) }
                .max { ($0.similarity, $1.index) < ($1.similarity, $0.index) }
            if let closest, closest.similarity >= Self.sameVoice {
                links[label] = closest.index
                absorb(embedding, seconds: seconds[label] ?? 0, into: closest.index)
            } else {
                let index = newIndex()
                links[label] = index
                voices[index] = Voice(embedding: embedding, seconds: seconds[label] ?? 0)
            }
        }
        return links
    }

    private mutating func newIndex() -> Int {
        lastIndex += 1
        return lastIndex
    }

    /// The voice's embedding becomes the mean of everything heard from it,
    /// weighted by how long each batch had it speaking.
    private mutating func absorb(_ embedding: [Float], seconds: Double, into index: Int) {
        guard var voice = voices[index], voice.embedding.count == embedding.count else { return }
        let total = voice.seconds + seconds
        guard total > 0 else { return }
        for dimension in voice.embedding.indices {
            voice.embedding[dimension] = Float(
                (Double(voice.embedding[dimension]) * voice.seconds + Double(embedding[dimension]) * seconds) / total
            )
        }
        voice.seconds = total
        voices[index] = voice
    }
}

/// After the call, the whole recording is diarized at once, which separates
/// voices better than batch by batch. Its labels take the cluster indexes used
/// during the call, so a voice named mid-call keeps its name.
public enum VoiceRelabel {
    /// Each label of the final diarization goes to the cluster whose speech
    /// it overlaps most, one label per cluster; labels left over get new
    /// indexes in order of first speech.
    public static func clusters(for spans: [SpeechSpan], segments: [Segment]) -> [String: Int] {
        var overlap: [String: [Int: Double]] = [:]
        for segment in segments {
            guard let cluster = segment.diarCluster else { continue }
            for span in spans {
                let shared = sharedSeconds(span, segment)
                if shared > 0 {
                    overlap[span.speaker, default: [:]][cluster, default: 0] += shared
                }
            }
        }
        let pairs = overlap
            .flatMap { label, clusters in clusters.map { (label: label, cluster: $0.key, seconds: $0.value) } }
            .sorted { ($0.seconds, $1.label, $1.cluster) > ($1.seconds, $0.label, $0.cluster) }
        var mapping: [String: Int] = [:]
        var taken = Set<Int>()
        for pair in pairs where mapping[pair.label] == nil && !taken.contains(pair.cluster) {
            mapping[pair.label] = pair.cluster
            taken.insert(pair.cluster)
        }
        var next = max(segments.compactMap(\.diarCluster).max() ?? -1, taken.max() ?? -1) + 1
        for span in spans.sorted(by: { $0.start < $1.start }) where mapping[span.speaker] == nil {
            mapping[span.speaker] = next
            next += 1
        }
        return mapping
    }

    /// The label that covers most of `segment`, or the closest one in time.
    public static func label(of segment: Segment, in spans: [SpeechSpan]) -> String? {
        var seconds: [String: Double] = [:]
        for span in spans {
            let shared = sharedSeconds(span, segment)
            if shared > 0 {
                seconds[span.speaker, default: 0] += shared
            }
        }
        if let best = seconds.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return best.key
        }
        let start = Double(segment.tStartMs) / 1000, end = Double(segment.tEndMs) / 1000
        return spans.min { distance($0, start, end) < distance($1, start, end) }?.speaker
    }

    private static func sharedSeconds(_ span: SpeechSpan, _ segment: Segment) -> Double {
        max(0, min(span.end, Double(segment.tEndMs) / 1000) - max(span.start, Double(segment.tStartMs) / 1000))
    }

    private static func distance(_ span: SpeechSpan, _ start: Double, _ end: Double) -> Double {
        max(0, max(span.start, start) - min(span.end, end))
    }
}
