import Foundation
import KuronekoCore
import Observation

/// Transcribes recorded meetings one at a time in the background, never
/// while a meeting is being recorded (the models compete with the call for
/// the CPU and Neural Engine).
@MainActor
@Observable
final class ProcessingQueue {
    struct Current: Equatable {
        var meetingId: Int64
        var title: String
        var progress: Double
    }

    private(set) var current: Current?

    @ObservationIgnored var isBusyRecording: () -> Bool = { false }
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored var onTranscribed: (Int64) -> Void = { _ in }

    private let db: AppDatabase
    private let processor: MeetingProcessor
    @ObservationIgnored private var task: Task<Void, Never>?

    init(db: AppDatabase, processor: MeetingProcessor) {
        self.db = db
        self.processor = processor
    }

    func kick() {
        guard task == nil, !isBusyRecording() else { return }
        task = Task { [weak self] in
            await self?.drain()
            self?.task = nil
        }
    }

    private func drain() async {
        while !isBusyRecording(), let next = (try? db.meetingsToProcess())?.first, let id = next.id {
            current = Current(meetingId: id, title: next.title, progress: 0)
            onChange()
            do {
                try await processor.process(meetingId: id) { fraction in
                    Task { @MainActor [weak self] in
                        guard self?.current?.meetingId == id else { return }
                        self?.current?.progress = fraction
                    }
                }
                onTranscribed(id)
            } catch {
                // Marked as failed by the processor; the next one goes on.
            }
            current = nil
            onChange()
        }
        await processor.unloadModels()
    }
}
