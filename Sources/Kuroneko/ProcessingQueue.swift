import Foundation
import KuronekoCore
import Observation

/// Transcribes meetings one at a time in the background. The meeting being
/// recorded goes in batches as it happens; once it ends only its last part
/// is left, done right away even if another call has started. Anything else
/// waits for no call to be in progress (the models compete with the call
/// for the CPU and Neural Engine).
@MainActor
@Observable
final class ProcessingQueue {
    struct Current: Equatable {
        var meetingId: Int64
        var title: String
        var progress: Double
    }

    private(set) var current: Current?

    @ObservationIgnored var recordingMeetingId: () -> Int64? = { nil }
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
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            await self?.drain()
            self?.task = nil
        }
    }

    private func drain() async {
        while true {
            let pending = (try? db.meetingsToProcess()) ?? []
            let finishing = await processor.liveMeetingIds()
            let recording = recordingMeetingId()
            if let next = pending.first(where: { finishing.contains($0.id ?? -1) }) ?? (recording == nil ? pending.first : nil) {
                await process(next)
            } else if let recording, await processor.advanceLive(meetingId: recording) {
                onChange()
            } else {
                break
            }
        }
        // Kept loaded through the call: the next batch is minutes away.
        if recordingMeetingId() == nil {
            await processor.unloadModels()
        }
    }

    private func process(_ next: Meeting) async {
        guard let id = next.id else { return }
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
}
