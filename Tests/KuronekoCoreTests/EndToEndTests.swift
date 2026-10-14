import AVFoundation
import Foundation
import Testing
@testable import KuronekoCore

/// Runs the real models on a real recording. Opt-in (downloads and loads
/// ~2 GB of models): KURONEKO_E2E_AUDIO=/path/system.wav swift test --filter EndToEnd
/// (KURONEKO_E2E_MIC=/path/mic.wav adds the mic).
@Suite struct EndToEndTests {
    static let audioPath = ProcessInfo.processInfo.environment["KURONEKO_E2E_AUDIO"]

    @Test(.enabled(if: audioPath != nil))
    func transcribesARealMeeting() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "E2E", source: "test")
        let micPath = ProcessInfo.processInfo.environment["KURONEKO_E2E_MIC"]
        try db.updateAudio(meetingId: meeting.id!, startedAt: Date(), micPath: micPath, systemPath: Self.audioPath)
        try db.endMeeting(meeting.id!)
        let models = MeetingStorage.standard().root.appendingPathComponent("models", isDirectory: true)
        let processor = MeetingProcessor(db: db, engines: .live(modelsDirectory: models))

        let started = Date()
        try await processor.process(meetingId: meeting.id!)
        let elapsed = Date().timeIntervalSince(started)

        let segments = try db.segments(meetingId: meeting.id!)
        print("E2E: \(segments.count) trechos em \(String(format: "%.1f", elapsed))s")
        for segment in segments {
            let who = segment.channel == .mic ? "eu" : "voz \(segment.diarCluster ?? -1)"
            print(String(format: "E2E [%06.1f] %@ (%@, %.2f): %@", Double(segment.tStartMs) / 1000, who, segment.lang ?? "?", segment.confidence ?? 0, segment.text))
        }
        #expect(try db.meeting(id: meeting.id!)?.status == .done)
        #expect(!segments.isEmpty)
    }

    /// The same recording replayed as if it were being recorded: written a
    /// minute at a time, transcribed in batches as it grows, then finished.
    @Test(.enabled(if: audioPath != nil))
    func transcribesARealMeetingWhileItIsRecorded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let micSource = ProcessInfo.processInfo.environment["KURONEKO_E2E_MIC"]
        let sources = [("system.wav", Self.audioPath)] + (micSource.map { [("mic.wav", $0)] } ?? [])
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        var channels: [(samples: [Float], writer: ResamplingWavWriter)] = []
        for (name, source) in sources {
            channels.append((try AudioSamples.load(URL(fileURLWithPath: source!)), try ResamplingWavWriter(
                inputFormat: format,
                fileURL: directory.appendingPathComponent(name)
            )))
        }
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "E2E ao vivo", source: "test")
        let id = try #require(meeting.id)
        try db.updateAudio(
            meetingId: id,
            startedAt: Date(),
            micPath: micSource == nil ? nil : directory.appendingPathComponent("mic.wav").path,
            systemPath: directory.appendingPathComponent("system.wav").path
        )
        let models = MeetingStorage.standard().root.appendingPathComponent("models", isDirectory: true)
        let processor = MeetingProcessor(db: db, engines: .live(modelsDirectory: models))

        let minute = 60 * AudioSamples.sampleRate
        let length = channels[0].samples.count
        for start in stride(from: 0, to: length, by: minute) {
            for channel in channels {
                let piece = Array(channel.samples[min(start, channel.samples.count)..<min(start + minute, channel.samples.count)])
                guard !piece.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(piece.count)) else { continue }
                buffer.frameLength = AVAudioFrameCount(piece.count)
                piece.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: piece.count) }
                try channel.writer.append(buffer)
            }
            let started = Date()
            if await processor.advanceLive(meetingId: id) {
                let shown = try db.segments(meetingId: id).last.map { Double($0.tEndMs) / 1000 } ?? 0
                print(String(format: "E2E ao vivo: gravado até %.0fs, lote levou %.1fs, transcrição até %.0fs",
                             Double(min(length, start + minute)) / 16000, Date().timeIntervalSince(started), shown))
            }
        }
        for channel in channels { channel.writer.finish() }
        try db.endMeeting(id)
        let started = Date()
        try await processor.process(meetingId: id)
        let segments = try db.segments(meetingId: id)
        print(String(format: "E2E ao vivo: concluída %.1fs depois do fim; %d trechos (%d do mic), %d vozes",
                     Date().timeIntervalSince(started), segments.count, segments.filter { $0.channel == .mic }.count,
                     try db.speakers(meetingId: id).count))
        for segment in segments {
            let who = segment.channel == .mic ? "eu" : "voz \(segment.diarCluster ?? -1)"
            print(String(format: "E2E ao vivo [%06.1f] %@: %@", Double(segment.tStartMs) / 1000, who, segment.text))
        }
        #expect(try db.meeting(id: id)?.status == .done)
        #expect(!segments.isEmpty)
    }
}
