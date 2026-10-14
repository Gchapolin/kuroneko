import Foundation

/// Without headphones the laptop mic also hears the speakers, so the "me"
/// channel carries everyone else's voice too. The system channel is the exact
/// signal those speakers played, which makes echo recognizable: a mic stretch
/// whose loudness follows the system audio, slightly delayed, is the room
/// echoing the call, not the user talking. Echo is dropped (that speech is
/// already in the system channel, with the right speaker); double talk is
/// kept as the user's.
///
/// The delay is not constant: in a real hour-long call it drifted from
/// -60 ms to -10 ms and then jumped to +100 ms (the two devices run on their
/// own clocks and either side can drop buffers). One delay for the whole
/// meeting stopped recognizing echo after the jump, so it is measured around
/// each utterance.
public enum EchoGate {
    static let frameSize = 160 // 10 ms at 16 kHz
    static let lagRange = -20...60 // frames: device latencies, speaker → mic
    static let minSystemActivity = 0.3
    static let echoCorrelation: Float = 0.6
    /// Audio around an utterance also used to measure its delay: 2 s.
    static let lagContext = 200

    public static func filter(spans: [SpeechSpan], mic: [Float], system: [Float]) -> [SpeechSpan] {
        guard !spans.isEmpty, !mic.isEmpty, !system.isEmpty else { return spans }
        let micEnvelope = envelope(mic)
        let systemEnvelope = envelope(system)
        let systemFloor = percentile(systemEnvelope, 0.1)
        return spans.filter { span in
            let spoken = frames(of: span, count: micEnvelope.count)
            let around = max(0, spoken.lowerBound - lagContext)..<min(micEnvelope.count, spoken.upperBound + lagContext)
            let lag = estimateLag(mic: micEnvelope, system: systemEnvelope, in: around)
            return !isEcho(span, mic: micEnvelope, system: systemEnvelope, lag: lag, systemFloor: systemFloor)
        }
    }

    /// Loudness per 10 ms frame, in dB.
    static func envelope(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - frameSize + 1, by: frameSize).map { start in
            var energy: Float = 0
            for index in start..<(start + frameSize) {
                energy += samples[index] * samples[index]
            }
            return 10 * log10(energy / Float(frameSize) + 1e-10)
        }
    }

    /// The delay (in frames) at which the mic best follows the system audio
    /// over `range` (the whole recording by default): mic[t] ≈ system[t - lag].
    static func estimateLag(mic: [Float], system: [Float], in range: Range<Int>? = nil) -> Int {
        let range = range ?? 0..<mic.count
        var best = (lag: 0, correlation: -Float.infinity)
        for lag in lagRange {
            let pairs = alignedPairs(mic: mic, system: system, lag: lag, range: range)
            let correlation = pearson(pairs)
            if correlation > best.correlation {
                best = (lag, correlation)
            }
        }
        return best.lag
    }

    static func isEcho(_ span: SpeechSpan, mic: [Float], system: [Float], lag: Int, systemFloor: Float) -> Bool {
        let spoken = frames(of: span, count: mic.count)
        guard !spoken.isEmpty else { return false }
        let pairs = alignedPairs(mic: mic, system: system, lag: lag, range: spoken)
        guard !pairs.isEmpty else { return false }
        let active = pairs.filter { $0.1 > systemFloor + 15 }.count
        // The user talking while the call is quiet is never echo.
        guard Double(active) / Double(pairs.count) >= minSystemActivity else { return false }
        return pearson(pairs) >= echoCorrelation
    }

    /// The envelope frames (10 ms each) an utterance covers.
    private static func frames(of span: SpeechSpan, count: Int) -> Range<Int> {
        let first = min(count, max(0, Int(span.start * 100)))
        return first..<max(first, min(count, Int(span.end * 100)))
    }

    private static func alignedPairs(mic: [Float], system: [Float], lag: Int, range: Range<Int>) -> [(Float, Float)] {
        range.compactMap { index in
            let systemIndex = index - lag
            guard systemIndex >= 0, systemIndex < system.count, index < mic.count else { return nil }
            return (mic[index], system[systemIndex])
        }
    }

    static func pearson(_ pairs: [(Float, Float)]) -> Float {
        guard pairs.count > 2 else { return 0 }
        let count = Float(pairs.count)
        let meanX = pairs.reduce(0) { $0 + $1.0 } / count
        let meanY = pairs.reduce(0) { $0 + $1.1 } / count
        var covariance: Float = 0, varianceX: Float = 0, varianceY: Float = 0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        guard varianceX > 0, varianceY > 0 else { return 0 }
        return covariance / (varianceX.squareRoot() * varianceY.squareRoot())
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }
}
