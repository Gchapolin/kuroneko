import Foundation

/// "@Valentina" typed in a quick note while Valentina talks names the voice
/// that was speaking at that moment. Marks live in notes, so they survive
/// re-transcription and are re-applied on every run.
public enum SpeakerMarks {
    public struct Mark: Equatable, Sendable {
        public var tMs: Int
        public var name: String

        public init(tMs: Int, name: String) {
            self.tMs = tMs
            self.name = name
        }
    }

    public struct Turn: Equatable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var cluster: Int

        public init(startMs: Int, endMs: Int, cluster: Int) {
            self.startMs = startMs
            self.endMs = endMs
            self.cluster = cluster
        }
    }

    /// The note is usually typed a moment after the voice was heard, so a
    /// voice that stopped shortly before the mark still counts.
    static let lookBackMs = 4000

    public static func mentions(in text: String) -> [String] {
        text.matches(of: /@([\p{L}\p{N}_-]+)/).map { String($0.output.1) }
    }

    public static func marks(from notes: [Note]) -> [Mark] {
        notes.flatMap { note in mentions(in: note.text).map { Mark(tMs: note.tMs, name: $0) } }
    }

    /// Name per voice cluster. When marks disagree about one voice, the name
    /// marked most often wins, the latest on a tie.
    public static func resolve(_ marks: [Mark], turns: [Turn]) -> [Int: String] {
        var votes: [Int: [(name: String, tMs: Int)]] = [:]
        for mark in marks {
            let speaking = turns.first { $0.startMs <= mark.tMs && mark.tMs <= $0.endMs }
            let justBefore = turns
                .filter { $0.endMs < mark.tMs && mark.tMs - $0.endMs <= lookBackMs }
                .max { $0.endMs < $1.endMs }
            guard let turn = speaking ?? justBefore else { continue }
            votes[turn.cluster, default: []].append((mark.name, mark.tMs))
        }
        return votes.mapValues { candidates in
            let counts = Dictionary(grouping: candidates, by: { $0.name.lowercased() })
            let best = counts.max { lhs, rhs in
                lhs.value.count != rhs.value.count
                    ? lhs.value.count < rhs.value.count
                    : (lhs.value.map(\.tMs).max() ?? 0) < (rhs.value.map(\.tMs).max() ?? 0)
            }!
            return best.value.max { $0.tMs < $1.tMs }!.name
        }
    }
}
