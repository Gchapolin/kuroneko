import AVFoundation
import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SpeechMeterTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func loudSoundIsSpeech() {
        let meter = SpeechMeter()
        meter.hear(level: -20, at: t0)
        #expect(meter.isSpeaking(at: t0))
    }

    @Test func quietSoundIsNot() {
        let meter = SpeechMeter()
        meter.hear(level: -60, at: t0)
        #expect(!meter.isSpeaking(at: t0))
        #expect(!SpeechMeter().isSpeaking(at: t0))
    }

    /// Short pauses between words keep it speaking; a real pause ends it.
    @Test func holdsThroughShortPauses() {
        let meter = SpeechMeter()
        meter.hear(level: -20, at: t0)
        meter.hear(level: -70, at: t0 + 0.3)
        #expect(meter.isSpeaking(at: t0 + 0.5))
        #expect(!meter.isSpeaking(at: t0 + SpeechMeter.hold + 0.01))
    }

    /// Either channel speaking counts: a quiet mic does not cancel the call.
    @Test func anyChannelCounts() {
        let meter = SpeechMeter()
        meter.hear(level: -20, at: t0)        // system
        meter.hear(level: -80, at: t0 + 0.1)  // mic, silent
        #expect(meter.isSpeaking(at: t0 + 0.2))
    }

    @Test func resetForgets() {
        let meter = SpeechMeter()
        meter.hear(level: -20, at: t0)
        meter.reset()
        #expect(!meter.isSpeaking(at: t0))
    }

    @Test func levelOfInt16Samples() {
        let full: [Int16] = [Int16.max, Int16.min, Int16.max, Int16.min]
        let silence = [Int16](repeating: 0, count: 4)
        full.withUnsafeBufferPointer { #expect(abs(SpeechMeter.level(of: $0)) < 0.01) }
        silence.withUnsafeBufferPointer { #expect(SpeechMeter.level(of: $0) == -.infinity) }
    }

    @Test func writerReportsWhatItWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let samples = buffer.floatChannelData![0]

        let meter = SpeechMeter()
        let writer = try ResamplingWavWriter(inputFormat: format, fileURL: url, meter: meter)
        for i in 0..<4800 { samples[i] = 0 }
        try writer.append(buffer)
        #expect(!meter.isSpeaking())

        for i in 0..<4800 { samples[i] = 0.5 * sinf(Float(i) * 2 * .pi * 440 / 48000) }
        try writer.append(buffer)
        #expect(meter.isSpeaking())
        writer.finish()
    }
}

@Suite struct CatAnimationTests {
    private func run(_ animation: inout CatAnimation, _ speaking: [Bool]) -> [String] {
        speaking.map { s in
            animation.advance(speaking: s)
            return "\(animation.clip == .idle ? "i" : "t")\(animation.frame)"
        }
    }

    @Test func idlesInALoop() {
        var a = CatAnimation(idleCount: 2, typingCount: 3)
        #expect(run(&a, [false, false, false]) == ["i1", "i0", "i1"])
    }

    @Test func startsTypingAtOnce() {
        var a = CatAnimation(idleCount: 4, typingCount: 3)
        #expect(run(&a, [false, true, true]) == ["i1", "t0", "t1"])
    }

    /// Back to idle only at the end of the typing loop, where both loops
    /// share the resting pose.
    @Test func finishesTheLoopBeforeResting() {
        var a = CatAnimation(idleCount: 4, typingCount: 3)
        #expect(run(&a, [true, false, false, false, false]) == ["t0", "t1", "t2", "i0", "i1"])
    }

    @Test func keepsTypingWhileSpeaking() {
        var a = CatAnimation(idleCount: 4, typingCount: 2)
        #expect(run(&a, [true, true, true, true]) == ["t0", "t1", "t0", "t1"])
    }

    @Test func emptyClipsStayPut() {
        var a = CatAnimation(idleCount: 0, typingCount: 0)
        #expect(run(&a, [true, false]) == ["i0", "i0"])
    }
}
