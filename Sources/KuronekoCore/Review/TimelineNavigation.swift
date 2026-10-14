import Foundation

/// Finding text in a meeting: case and accents ignored, so "acao" finds
/// "ação".
public enum TextFind {
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}

extension Timeline {
    /// One occurrence of what is being looked for: the entry, and which of
    /// the entry's occurrences it is.
    public struct Match: Equatable, Hashable, Sendable {
        public var entryIndex: Int
        public var occurrence: Int

        public init(entryIndex: Int, occurrence: Int) {
            self.entryIndex = entryIndex
            self.occurrence = occurrence
        }
    }

    /// The text of an entry as the meeting screen shows it, and finds in it.
    public static func text(of entry: TimelineEntry) -> String {
        switch entry {
        case .speech(let block): block.segments.map(\.text).joined(separator: " ")
        case .note(let note, _): note.text
        }
    }

    /// Every occurrence of `query`, in the order of the meeting.
    public static func matches(of query: String, in entries: [TimelineEntry]) -> [Match] {
        entries.indices.flatMap { index in
            TextFind.ranges(of: query, in: text(of: entries[index])).indices.map { Match(entryIndex: index, occurrence: $0) }
        }
    }

    /// The speech block heard at `ms`: the last one that started by then,
    /// while it lasts and a little after (a short pause before the next
    /// one); nil in a longer silence or before anyone spoke. `entries` are
    /// in the order of `entries(segments:notes:)`.
    public static func speechIndex(atMs ms: Int, in entries: [TimelineEntry], lingerMs: Int = 3000) -> Int? {
        // First entry starting after `ms`.
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].startMs <= ms {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var index = low - 1
        while index >= 0 {
            if case .speech(let block) = entries[index] {
                return ms <= block.endMs + lingerMs ? index : nil
            }
            index -= 1
        }
        return nil
    }
}

/// Where the transcript of a call being recorded stands: it arrives in
/// batches of `MeetingProcessor.liveBatchSeconds`, a little behind the
/// conversation.
public enum LiveProgress {
    /// Up to where the transcript is ready: the end of the last thing said.
    public static func transcribedUntilMs(_ segments: [Segment]) -> Int {
        segments.map(\.tEndMs).max() ?? 0
    }

    /// Roughly how long until the next batch is transcribed, `elapsedMs`
    /// into the recording: batches fall about every `liveBatchSeconds`
    /// (each is cut a little earlier, at a pause).
    public static func untilNextBatchMs(elapsedMs: Int) -> Int {
        let batchMs = Int(MeetingProcessor.liveBatchSeconds * 1000), marginMs = Int(MeetingProcessor.liveMargin * 1000)
        let done = max(0, elapsedMs - marginMs) / batchMs
        return (done + 1) * batchMs + marginMs - elapsedMs
    }

    /// The "~N min" to show: whole minutes, at least one.
    public static func minutesUntilNextBatch(elapsedMs: Int) -> Int {
        let remaining = untilNextBatchMs(elapsedMs: elapsedMs)
        return max(1, (remaining + 59_999) / 60_000)
    }
}
