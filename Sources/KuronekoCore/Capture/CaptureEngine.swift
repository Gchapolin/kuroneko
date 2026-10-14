import AVFoundation
import Foundation
import os

/// Orchestrates the two independent recording channels of a meeting:
/// microphone ("me") and system audio ("them").
public final class CaptureEngine: @unchecked Sendable {
    public struct RecordingPaths: Equatable, Sendable {
        /// nil when the microphone is unavailable (permission denied, no
        /// input device): the meeting is still recorded from Chrome alone.
        public let mic: URL?
        public let system: URL
    }

    public enum SystemSource: String, Sendable {
        case chrome
        case global
    }

    private let mic = MicRecorder()
    private let tap = ProcessTapRecorder()
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "CaptureEngine")

    public private(set) var systemSource: SystemSource?
    public private(set) var isMicRecording = false

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

        // The other participants are the point of the recording; losing the
        // "me" channel degrades it but must not cancel it.
        let granted = await MicRecorder.requestPermission()
        FileLog.shared.append("capture.start: mic permissão=\(granted)")
        guard granted else {
            logger.notice("Sem permissão de microfone; gravando só o áudio do sistema")
            return RecordingPaths(mic: nil, system: systemURL)
        }
        do {
            try mic.start(fileURL: micURL)
            isMicRecording = true
            FileLog.shared.append("capture.start: mic ok")
            return RecordingPaths(mic: micURL, system: systemURL)
        } catch {
            logger.error("Mic indisponível; gravando só o áudio do sistema: \(error)")
            FileLog.shared.append("capture.start: mic FALHOU: \(error)")
            return RecordingPaths(mic: nil, system: systemURL)
        }
    }

    public func stop() {
        mic.stop()
        tap.stop()
        systemSource = nil
        isMicRecording = false
    }
}
