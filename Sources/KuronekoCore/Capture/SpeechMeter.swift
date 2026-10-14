import Foundation

/// Whether someone is talking right now, from the loudness of what the mic
/// and the system tap are writing. A level meter, not the VAD: cheap enough
/// for every buffer, so any loud sound counts. Only drives the typing cat.
public final class SpeechMeter: @unchecked Sendable {
    /// dBFS above which a buffer counts as speech.
    public static let threshold: Float = -45
    /// How long it stays speaking after the last loud buffer, so the pauses
    /// between words don't flicker it off.
    public static let hold: TimeInterval = 0.6

    private let lock = NSLock()
    private var lastLoud: Date?

    public init() {}

    public func hear(level: Float, at date: Date = Date()) {
        guard level >= Self.threshold else { return }
        lock.withLock { lastLoud = date }
    }

    public func isSpeaking(at date: Date = Date()) -> Bool {
        lock.withLock {
            guard let lastLoud else { return false }
            return date.timeIntervalSince(lastLoud) <= Self.hold
        }
    }

    public func reset() {
        lock.withLock { lastLoud = nil }
    }

    /// RMS level in dBFS; -infinity for silence.
    public static func level(of samples: UnsafeBufferPointer<Int16>) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        var sum: Float = 0
        for s in samples {
            let x = Float(s) / Float(Int16.max)
            sum += x * x
        }
        return 10 * log10(sum / Float(samples.count))
    }
}
