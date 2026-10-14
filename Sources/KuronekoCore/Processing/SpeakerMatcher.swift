import Foundation

/// Recognizes voices already named in earlier meetings.
public enum SpeakerMatcher {
    /// Cosine similarity a voice needs to any voiceprint of a person. A first
    /// estimate for these embeddings; the similarities are logged per meeting
    /// to calibrate it on real calls.
    public static let threshold: Float = 0.55
    /// The best person must beat the runner-up by this much, otherwise two
    /// similar voices would be confused silently.
    static let margin: Float = 0.05

    public struct Match: Equatable, Sendable {
        public var personId: Int64
        public var similarity: Float
    }

    public static func match(_ embedding: [Float], voiceprints: [Voiceprint]) -> Match? {
        let ranked = rank(embedding, voiceprints: voiceprints)
        guard let best = ranked.first, best.similarity >= threshold else { return nil }
        if ranked.count > 1, best.similarity - ranked[1].similarity < margin {
            return nil
        }
        return best
    }

    /// Every person with a voiceprint, closest voice first; a person's
    /// similarity is the best over all of their voiceprints.
    public static func rank(_ embedding: [Float], voiceprints: [Voiceprint]) -> [Match] {
        var bestPerPerson: [Int64: Float] = [:]
        for voiceprint in voiceprints {
            let similarity = cosine(embedding, EmbeddingCodec.decode(voiceprint.embedding))
            bestPerPerson[voiceprint.personId] = max(bestPerPerson[voiceprint.personId] ?? -1, similarity)
        }
        return bestPerPerson
            .map { Match(personId: $0.key, similarity: $0.value) }
            .sorted { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.personId < $1.personId }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return -1 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
