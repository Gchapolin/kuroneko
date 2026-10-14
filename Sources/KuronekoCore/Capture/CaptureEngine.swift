import AVFoundation
import CoreAudio
import Foundation
import os

/// Orchestrates the two independent recording channels of a meeting:
/// microphone ("me") and system audio ("them"). Both files share one zero:
/// the moment the system tap started; the mic file is padded with silence
/// for however late it joined, so a second in one is the same second in the
/// other (echo detection and the timeline depend on it).
public final class CaptureEngine: @unchecked Sendable {
    public struct RecordingPaths: Equatable, Sendable {
        /// nil when the microphone is unavailable (permission denied, no
        /// input device): the meeting is still recorded from Chrome alone.
        public let mic: URL?
        public let system: URL
        /// The zero of both files.
        public let startedAt: Date
    }

    public enum SystemSource: String, Sendable {
        case chrome
        case global
    }

    private let mic = MicRecorder()
    private let tap = ProcessTapRecorder()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "CaptureEngine")

    private var startedAt: Date?
    private var micURL: URL?
    private var inputDeviceListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.gandarfh.kuroneko.capture.input")

    public private(set) var systemSource: SystemSource?
    public private(set) var isMicRecording = false
    /// Called when a mic connected mid-meeting starts recording.
    public var onLateMicStart: (@Sendable (URL) -> Void)?

    public init() {}

    public func start(in directory: URL) async throws -> RecordingPaths {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let systemURL = directory.appendingPathComponent("system.wav")
        let micURL = directory.appendingPathComponent("mic.wav")

        let chromeObjects = AudioProcessFinder.chromeAudioObjects()
        FileLog.shared.append("capture.start: chrome audio objects=\(chromeObjects.count)")
        let target: ProcessTapRecorder.Target
        if chromeObjects.isEmpty {
            logger.notice("Chrome sem processos de áudio ativos; usando tap global")
            target = .globalExcludingCurrentProcess
            systemSource = .global
        } else {
            target = .processes(chromeObjects)
            systemSource = .chrome
        }

        do {
            try tap.start(target: target, fileURL: systemURL)
            FileLog.shared.append("capture.start: tap ok (\(systemSource?.rawValue ?? "?"))")
        } catch {
            FileLog.shared.append("capture.start: tap FALHOU: \(error)")
            systemSource = nil
            throw error
        }
        let startedAt = Date()
        lock.withLock {
            self.startedAt = startedAt
            self.micURL = micURL
        }

        // The other participants are the point of the recording; losing the
        // "me" channel degrades it but must not cancel it.
        let granted = await MicRecorder.requestPermission()
        FileLog.shared.append("capture.start: mic permissão=\(granted)")
        guard granted else {
            logger.notice("Sem permissão de microfone; gravando só o áudio do sistema")
            return RecordingPaths(mic: nil, system: systemURL, startedAt: startedAt)
        }
        if startMic() {
            return RecordingPaths(mic: micURL, system: systemURL, startedAt: startedAt)
        }
        // No usable input device yet: start the mic as soon as one appears.
        installInputDeviceListener()
        return RecordingPaths(mic: nil, system: systemURL, startedAt: startedAt)
    }

    public func stop() {
        removeInputDeviceListener()
        mic.stop()
        tap.stop()
        systemSource = nil
        isMicRecording = false
        lock.withLock {
            startedAt = nil
            micURL = nil
        }
    }

    @discardableResult
    private func startMic() -> Bool {
        guard let (startedAt, micURL) = lock.withLock({ () -> (Date, URL)? in
            guard let startedAt = self.startedAt, let micURL = self.micURL else { return nil }
            return (startedAt, micURL)
        }) else { return false }
        do {
            try mic.start(fileURL: micURL, leadingSilence: Date().timeIntervalSince(startedAt))
            isMicRecording = true
            FileLog.shared.append("capture: mic ok")
            return true
        } catch {
            logger.error("Mic indisponível; gravando só o áudio do sistema: \(error)")
            FileLog.shared.append("capture: mic indisponível: \(error)")
            return false
        }
    }

    // MARK: - Mic connected mid-meeting

    private func installInputDeviceListener() {
        var address = CoreAudioSupport.globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.isMicRecording else { return }
            FileLog.shared.append("capture: dispositivo de entrada mudou; tentando o mic")
            guard self.startMic(), let url = self.lock.withLock({ self.micURL }) else { return }
            self.removeInputDeviceListener()
            self.onLateMicStart?(url)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener
        )
        if status == noErr {
            lock.withLock { inputDeviceListener = listener }
        }
    }

    private func removeInputDeviceListener() {
        guard let listener = lock.withLock({ () -> AudioObjectPropertyListenerBlock? in
            defer { inputDeviceListener = nil }
            return inputDeviceListener
        }) else { return }
        var address = CoreAudioSupport.globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener
        )
    }
}
