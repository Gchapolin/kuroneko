import AVFoundation
import Foundation
import Testing
@testable import KuronekoCore

@Suite struct ResamplingWavWriterTests {
    private func makeBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = sinf(Float(frame) * 2 * .pi * 440 / Float(sampleRate))
            }
        }
        return buffer
    }

    private func tempWavURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kuroneko-test-\(UUID().uuidString).wav")
    }

    @Test func resamples48kStereoTo16kMono() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try makeBuffer(sampleRate: 48000, channels: 2, frames: 48000)

        let writer = try ResamplingWavWriter(inputFormat: input.format, fileURL: url)
        try writer.append(input)

        writer.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        // One second of input should produce close to one second of output;
        // the resampler is allowed a small amount of internal latency.
        #expect(file.length > 15000)
        #expect(file.length <= 16100)
    }

    @Test func acceptsInputFormatChangeMidFile() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try makeBuffer(sampleRate: 48000, channels: 2, frames: 4800)
        let second = try makeBuffer(sampleRate: 44100, channels: 1, frames: 4410)

        let writer = try ResamplingWavWriter(inputFormat: first.format, fileURL: url)
        try writer.append(first)
        try writer.append(second)

        writer.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        // Two tenths of a second in, minus converter latency.
        #expect(file.length > 2800)
    }

    @Test func padsLeadingSilenceToAlignChannels() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try makeBuffer(sampleRate: 48000, channels: 1, frames: 4800)

        let writer = try ResamplingWavWriter(inputFormat: input.format, fileURL: url)
        try writer.appendSilence(seconds: 1.5)
        try writer.append(input)

        writer.finish()
        let samples = try AudioSamples.load(url)
        // 0.1 s of input, minus the resampler latency.
        #expect(samples.count > 24000 + 1000)
        #expect(samples.prefix(24000).allSatisfy { $0 == 0 })
        #expect(samples.suffix(1000).contains { $0 != 0 })
    }

    /// Transcription during the call reads the files while they are written.
    @Test func readsTheWavWhileItIsBeingRecorded() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try makeBuffer(sampleRate: 48000, channels: 1, frames: 48000)

        let writer = try ResamplingWavWriter(inputFormat: input.format, fileURL: url)
        try writer.appendSilence(seconds: 1.5)
        try writer.append(input)

        let duration = try AudioSamples.recordedDuration(url)
        #expect(duration > 2.4 && duration <= 2.5)
        let recording = try AudioSamples.load(url, from: 1, to: 2)
        #expect(recording.count == 16000)
        #expect(recording.prefix(8000).allSatisfy { $0 == 0 })
        #expect(recording.suffix(1000).contains { $0 != 0 })
        // Past the end it returns what there is.
        #expect(try AudioSamples.load(url, from: 2, to: 60).count == Int((duration - 2) * 16000))

        writer.finish()
        let whole = try AudioSamples.load(url)
        #expect(try AudioSamples.load(url, from: 1, to: 2) == Array(whole[16000..<32000]))
        #expect(try AudioSamples.recordedDuration(url) == Double(whole.count) / 16000)
    }

    @Test func ignoresEmptyBuffers() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        empty.frameLength = 0

        let writer = try ResamplingWavWriter(inputFormat: format, fileURL: url)
        try writer.append(empty)

        writer.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 0)
    }
}

@Suite struct AudioProcessFinderTests {
    @Test func matchesChromeAndItsHelpers() {
        #expect(AudioProcessFinder.matchesChrome(bundleID: "com.google.Chrome"))
        #expect(AudioProcessFinder.matchesChrome(bundleID: "com.google.Chrome.helper"))
        #expect(AudioProcessFinder.matchesChrome(bundleID: "com.google.chrome.helper.audio"))
    }

    @Test func rejectsOtherApps() {
        #expect(!AudioProcessFinder.matchesChrome(bundleID: "com.apple.Safari"))
        #expect(!AudioProcessFinder.matchesChrome(bundleID: "com.spotify.client"))
        #expect(!AudioProcessFinder.matchesChrome(bundleID: nil))
    }
}

@Suite struct MeetingStorageTests {
    @Test func layoutIsStableUnderRoot() {
        let storage = MeetingStorage(root: URL(fileURLWithPath: "/tmp/kuroneko"))

        #expect(storage.databaseURL.path == "/tmp/kuroneko/kuroneko.sqlite")
        #expect(storage.meetingDirectory(id: 42).path == "/tmp/kuroneko/meetings/42")
        #expect(storage.screenshotsDirectory(meetingId: 42).path == "/tmp/kuroneko/meetings/42/screenshots")
    }

    @Test func lastAudioWriteIsTheNewestAudioFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MeetingStorage(root: root)
        let directory = storage.meetingDirectory(id: 7)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        for (name, date) in [("mic.wav", older), ("system.wav", newer)] {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        #expect(storage.lastAudioWrite(meetingId: 7) == newer)
        #expect(storage.lastAudioWrite(meetingId: 8) == nil)
    }
}

@Suite struct AudioPathsTests {
    @Test func updateAudioPathsPersistsBothChannels() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily")

        try db.updateAudio(
            meetingId: meeting.id!,
            startedAt: Date(),
            micPath: "/tmp/kuroneko/meetings/1/mic.wav",
            systemPath: "/tmp/kuroneko/meetings/1/system.wav"
        )

        let stored = try #require(try db.meetings().first)
        #expect(stored.audioMicPath == "/tmp/kuroneko/meetings/1/mic.wav")
        #expect(stored.audioSystemPath == "/tmp/kuroneko/meetings/1/system.wav")
    }
}
