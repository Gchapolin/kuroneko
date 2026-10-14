import Foundation
import Testing
@testable import KuronekoCore

/// Runs the real models on a real recording. Opt-in (downloads and loads
/// ~2 GB of models): KURONEKO_E2E_AUDIO=/path/system.wav swift test --filter EndToEnd
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
}
