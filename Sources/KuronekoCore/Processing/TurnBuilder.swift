import Foundation

/// A stretch of speech attributed to one voice. `speaker` is "me" for the
/// mic channel or the diarizer's cluster label for the system channel.
public struct SpeechSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    /// Set once the language of the span is decided; turns never mix two.
    public var language: String?
    /// Transcribed on its own, never merged: used when its language is in
    /// doubt (code-switching), because Whisper given a whole turn in one
    /// language translates the other parts into it, while a lone utterance
    /// comes out in the words actually spoken.
    public var isolated: Bool

    public init(start: Double, end: Double, speaker: String, language: String? = nil, isolated: Bool = false) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.language = language
        self.isolated = isolated
    }

    public var duration: Double { end - start }
}

public enum TurnBuilder {
    /// Merges consecutive spans of the same voice and language separated by
    /// short pauses into turns: each turn is transcribed on its own, so it
    /// must hold one speaker and one language only, but be long enough to
    /// give Whisper context. A turn never grows past `maxDuration` by merging.
    public static func turns(
        from spans: [SpeechSpan],
        maxGap: Double = 1.0,
        maxDuration: Double = 30,
        minDuration: Double = 0.3
    ) -> [SpeechSpan] {
        var turns: [SpeechSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.duration > 0 {
            if var last = turns.last,
               last.speaker == span.speaker,
               last.language == span.language,
               span.start - last.end <= maxGap,
               span.end - last.start <= maxDuration,
               isolationAllowsMerging(last, span, shortBelow: shortBelow) {
                last.end = max(last.end, span.end)
                last.isolated = last.isolated || span.isolated
                turns[turns.count - 1] = last
            } else {
                turns.append(span)
            }
        }
        return turns.filter { $0.duration >= minDuration }
    }

    /// Below this a span is too short to have had its own language detected,
    /// so it carries no evidence against joining an isolated neighbor.
    static let shortBelow = 2.0

    /// An isolated utterance stays apart from other full utterances, but
    /// absorbs short fragments around it (a lone "sobre" before it), which
    /// alone would be too little audio to transcribe.
    private static func isolationAllowsMerging(_ turn: SpeechSpan, _ span: SpeechSpan, shortBelow: Double) -> Bool {
        switch (turn.isolated, span.isolated) {
        case (false, false): true
        case (true, false): span.duration < shortBelow
        case (false, true): turn.duration < shortBelow
        case (true, true): false
        }
    }
}

public enum SpanAssembler {
    /// Combines both views of the system channel: speech detection is better
    /// at *where* someone speaks (the diarizer drops short utterances like a
    /// lone "Olá"), the diarizer knows *who*. Diarizer spans are kept as they
    /// are; detected speech they miss is added and given to the voice that
    /// spoke closest in time.
    public static func assemble(diarized: [SpeechSpan], detected: [SpeechSpan], minDuration: Double = 0.4) -> [SpeechSpan] {
        guard !diarized.isEmpty else {
            return detected.map { SpeechSpan(start: $0.start, end: $0.end, speaker: "S1") }
        }
        let covered = diarized.sorted { $0.start < $1.start }
        var spans = covered
        var extra: [SpeechSpan] = []
        for span in detected {
            for piece in uncovered(span, by: covered) where piece.end - piece.start >= minDuration {
                let nearest = covered.indices.min { distance(piece, covered[$0]) < distance(piece, covered[$1]) }!
                if distance(piece, covered[nearest]) <= touching {
                    // Speech running straight into a diarized utterance is
                    // the same utterance with a clipped edge: extend it
                    // rather than cutting the sentence in two.
                    spans[nearest].start = min(spans[nearest].start, piece.start)
                    spans[nearest].end = max(spans[nearest].end, piece.end)
                } else {
                    extra.append(SpeechSpan(start: piece.start, end: piece.end, speaker: covered[nearest].speaker))
                }
            }
        }
        return (spans + extra).sorted { $0.start < $1.start }
    }

    static let touching = 0.3

    private static func uncovered(_ span: SpeechSpan, by covered: [SpeechSpan]) -> [(start: Double, end: Double)] {
        var pieces: [(start: Double, end: Double)] = []
        var cursor = span.start
        for cover in covered where cover.end > span.start && cover.start < span.end {
            if cover.start > cursor {
                pieces.append((cursor, min(cover.start, span.end)))
            }
            cursor = max(cursor, cover.end)
        }
        if cursor < span.end {
            pieces.append((cursor, span.end))
        }
        return pieces
    }

    private static func distance(_ piece: (start: Double, end: Double), _ span: SpeechSpan) -> Double {
        if span.end <= piece.start { return piece.start - span.end }
        if span.start >= piece.end { return span.start - piece.end }
        return 0
    }
}
