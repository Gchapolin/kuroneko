import Foundation

/// Chooses the transcription language of each turn among the team's
/// languages. Whisper left alone picks one language per 30s window and
/// silently translates whatever else is spoken into it, which is how Spanish
/// came out as Portuguese in the first test.
public enum LanguagePicker {
    public static let candidates = ["pt", "es", "en"]
    /// English must win clearly: a Portuguese sentence full of jargon ("o
    /// pull request do review") must not be transcribed as English.
    static let englishMinimum = 0.8
    /// Below this length Whisper's language guess is noise.
    static let minDurationForDetection = 2.0
    static let minConfidence = 0.6
    /// A clean monolingual utterance scores ~1.0 for its language; Spanish
    /// with a Brazilian accent scored pt 0.77 / es 0.15 in the first test.
    static let mixedBelow = 0.95

    /// Whether an utterance may hold another language than its top guess.
    public static func isMixed(_ distribution: [String: Double]) -> Bool {
        (distribution.values.max() ?? 0) < mixedBelow
    }

    /// Whisper reports log-probabilities over its whole vocabulary; only the
    /// candidates matter, renormalized among themselves.
    public static func distribution(logProbs: [String: Float]) -> [String: Double] {
        let values = candidates.compactMap { code in logProbs[code].map { (code, Double($0)) } }
        guard let maxLog = values.map(\.1).max() else { return [:] }
        let exps = values.map { ($0.0, exp($0.1 - maxLog)) }
        let total = exps.reduce(0) { $0 + $1.1 }
        return Dictionary(uniqueKeysWithValues: exps.map { ($0.0, $0.1 / total) })
    }

    /// A speaker's usual language, weighted by how long they spoke in it.
    public static func speakerPriors(
        _ turns: [(speaker: String, duration: Double, distribution: [String: Double])]
    ) -> [String: String] {
        var weights: [String: [String: Double]] = [:]
        for turn in turns where turn.duration >= minDurationForDetection {
            for (code, probability) in turn.distribution {
                weights[turn.speaker, default: [:]][code, default: 0] += probability * turn.duration
            }
        }
        return weights.compactMapValues { pick(from: normalized($0)) }
    }

    /// Decides the language of every span. Spans long and clear enough keep
    /// their own detection; the rest take the language of the same speaker's
    /// nearest decided span (people switch language in stretches, not word by
    /// word), then the speaker's usual language, then Portuguese.
    public static func assign(_ spans: [SpeechSpan], distributions: [Int: [String: Double]]) -> [String] {
        let priors = speakerPriors(spans.indices.compactMap { index in
            distributions[index].map { (spans[index].speaker, spans[index].duration, $0) }
        })
        var decided: [Int: String] = [:]
        for (index, span) in spans.enumerated() where span.duration >= minDurationForDetection {
            if let distribution = distributions[index], let best = pick(from: distribution),
               (distribution[best] ?? 0) >= minConfidence {
                decided[index] = best
            }
        }
        return spans.indices.map { index in
            if let language = decided[index] { return language }
            let span = spans[index]
            let neighbor = decided.keys
                .filter { spans[$0].speaker == span.speaker }
                .map { ($0, gap(spans[$0], span)) }
                .filter { $0.1 <= neighborWindow }
                .min { $0.1 < $1.1 }
            return neighbor.flatMap { decided[$0.0] } ?? priors[span.speaker] ?? "pt"
        }
    }

    static let neighborWindow = 8.0

    private static func gap(_ a: SpeechSpan, _ b: SpeechSpan) -> Double {
        max(0, max(a.start, b.start) - min(a.end, b.end))
    }

    private static func pick(from distribution: [String: Double]) -> String? {
        guard let best = distribution.max(by: { $0.value < $1.value }) else { return nil }
        if best.key == "en", best.value < englishMinimum {
            return distribution.filter { $0.key != "en" }.max(by: { $0.value < $1.value })?.key ?? best.key
        }
        return best.key
    }

    private static func normalized(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return weights }
        return weights.mapValues { $0 / total }
    }
}
