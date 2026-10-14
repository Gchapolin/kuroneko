import AVFoundation
import Foundation
import KuronekoCore
import Observation

/// Plays both channels of a meeting together, so a block of the transcript
/// can be heard as it happened (the user's mic and the call, mixed). The
/// channels always start, seek and change speed together, on the same
/// device time, so they never drift apart.
@MainActor
@Observable
final class MeetingPlayer {
    static let rates: [Float] = [1, 1.25, 1.5, 2]
    static let skipMs = 15_000

    private(set) var isPlaying = false
    /// Updated about 20 times a second while playing, for the scrubber.
    private(set) var positionMs = 0
    /// The same, changing once a second: for views that show the time and
    /// don't need to redraw more often.
    private(set) var positionSecond = 0
    private(set) var durationMs = 0
    private(set) var rate: Float = 1
    private(set) var hasAudio = false
    /// Played or moved by the user at least once: notes then go to the
    /// player's moment instead of the end of the meeting.
    private(set) var hasPosition = false

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var stopAtMs: Int?
    /// Playback starts a moment after it is asked for (both channels on the
    /// same device time); until then the players don't count as playing.
    @ObservationIgnored private var startedAt = Date.distantPast

    func load(_ meeting: Meeting) {
        stop()
        players = [meeting.audioSystemPath, meeting.audioMicPath]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap { try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: $0)) }
            // The longest channel keeps the time.
            .sorted { $0.duration > $1.duration }
        for player in players {
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
        }
        durationMs = Int((players.first?.duration ?? 0) * 1000)
        hasAudio = !players.isEmpty
    }

    /// `stopAfterMs` plays just a sample, then pauses.
    func play(fromMs ms: Int, stopAfterMs: Int? = nil) {
        guard hasAudio else { return }
        stopAtMs = stopAfterMs.map { ms + $0 }
        if stopAfterMs == nil { hasPosition = true }
        start(atMs: clamped(ms))
    }

    func toggle() {
        stopAtMs = nil
        if isPlaying {
            pause()
        } else {
            hasPosition = true
            // From the start again once it reached the end.
            start(atMs: positionMs >= durationMs - 500 ? 0 : positionMs)
        }
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
        if let clock = players.first {
            setPosition(Int(clock.currentTime * 1000))
        }
    }

    func stop() {
        pause()
        players = []
        hasAudio = false
        durationMs = 0
        hasPosition = false
        setPosition(0)
    }

    func seek(toMs ms: Int) {
        guard hasAudio else { return }
        hasPosition = true
        stopAtMs = nil
        let ms = clamped(ms)
        if isPlaying {
            start(atMs: ms)
        } else {
            for player in players {
                player.currentTime = min(Double(ms) / 1000, player.duration)
            }
            setPosition(ms)
        }
    }

    /// ±15 s, from where it is now.
    func skip(by ms: Int) {
        seek(toMs: positionMs + ms)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        guard hasAudio else { return }
        if isPlaying {
            // Restarted together, or the channels drift apart.
            start(atMs: currentMs)
        } else {
            players.forEach { $0.rate = rate }
        }
    }

    // MARK: - Private

    private var currentMs: Int {
        players.first.map { Int($0.currentTime * 1000) } ?? positionMs
    }

    private func clamped(_ ms: Int) -> Int {
        min(max(0, ms), durationMs)
    }

    private func start(atMs ms: Int) {
        guard let clock = players.first else { return }
        players.forEach { $0.pause() }
        let startAt = clock.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(Double(ms) / 1000, player.duration)
            player.rate = rate
            player.play(atTime: startAt)
        }
        isPlaying = true
        startedAt = Date()
        setPosition(ms)
        startTicker()
    }

    private func setPosition(_ ms: Int) {
        if ms != positionMs { positionMs = ms }
        let second = ms / 1000
        if second != positionSecond { positionSecond = second }
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes: keeps going while the scrubber is dragged or the
        // transcript scrolled.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let clock = players.first else { return }
        setPosition(Int(clock.currentTime * 1000))
        if let stopAt = stopAtMs, positionMs >= stopAt {
            stopAtMs = nil
            pause()
            return
        }
        if !clock.isPlaying, isPlaying, Date().timeIntervalSince(startedAt) > 0.3 {
            // Reached the end.
            isPlaying = false
            ticker?.invalidate()
            ticker = nil
            setPosition(durationMs)
        }
    }
}
