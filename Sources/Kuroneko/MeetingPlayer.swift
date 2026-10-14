import AVFoundation
import Foundation
import KuronekoCore
import Observation

/// Plays both channels of a meeting together, so a block of the transcript
/// can be heard as it happened (the user's mic and the call, mixed).
@MainActor
@Observable
final class MeetingPlayer {
    private(set) var isPlaying = false
    private(set) var positionMs = 0

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var stopAtMs: Int?

    func load(_ meeting: Meeting) {
        stop()
        players = [meeting.audioSystemPath, meeting.audioMicPath]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap { try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: $0)) }
        players.forEach { $0.prepareToPlay() }
    }

    var hasAudio: Bool { !players.isEmpty }

    /// `stopAfterMs` plays just a sample, then pauses.
    func play(fromMs ms: Int, stopAfterMs: Int? = nil) {
        guard let first = players.first else { return }
        stopAtMs = stopAfterMs.map { ms + $0 }
        let start = first.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(Double(ms) / 1000, player.duration)
            player.play(atTime: start)
        }
        isPlaying = true
        positionMs = ms
        startTicker()
    }

    func toggle() {
        stopAtMs = nil
        if isPlaying {
            pause()
        } else {
            play(fromMs: positionMs)
        }
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker?.invalidate()
    }

    func stop() {
        pause()
        players = []
        positionMs = 0
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let first = self.players.first else { return }
                self.positionMs = Int(first.currentTime * 1000)
                if let stopAt = self.stopAtMs, self.positionMs >= stopAt {
                    self.stopAtMs = nil
                    self.pause()
                    return
                }
                if !first.isPlaying, self.isPlaying {
                    self.isPlaying = false
                    self.ticker?.invalidate()
                }
            }
        }
    }
}
