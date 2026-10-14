import AVFoundation
import Foundation
import os

/// Records the user's microphone to 16kHz mono WAV via AVAudioEngine,
/// independent from the system-audio tap so the "me" channel stays separate.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MicRecorder")
    private var writer: ResamplingWavWriter?
    private var configurationObserver: NSObjectProtocol?

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start(fileURL: URL) throws {
        try lock.withLock {
            guard writer == nil else { throw CaptureError.alreadyRecording }
            let format = engine.inputNode.inputFormat(forBus: 0)
            FileLog.shared.append("mic.start: formato de entrada \(format.sampleRate)Hz \(format.channelCount)ch")
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.unsupportedFormat("mic input format indisponível")
            }
            let writer = try ResamplingWavWriter(inputFormat: format, fileURL: fileURL)
            try installTapAndStart(writer: writer)
            self.writer = writer
        }
        // The engine stops itself when the input device changes (AirPods
        // connecting mid-call); without a restart the "me" channel would go
        // silent for the rest of the meeting.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    public func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        lock.withLock {
            guard let writer else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            writer.finish()
            self.writer = nil
        }
    }

    // MARK: - Engine (always called with `lock` held)

    private func installTapAndStart(writer: ResamplingWavWriter) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [logger] buffer, _ in
            do {
                try writer.append(buffer)
            } catch {
                logger.error("Falha ao gravar buffer do mic: \(error)")
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func restartAfterConfigurationChange() {
        lock.withLock {
            guard let writer else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            let format = engine.inputNode.inputFormat(forBus: 0)
            FileLog.shared.append("mic.restart: novo formato \(format.sampleRate)Hz \(format.channelCount)ch")
            guard format.sampleRate > 0, format.channelCount > 0 else {
                logger.error("Mic sem formato válido após troca de dispositivo")
                return
            }
            do {
                // The writer keeps its fixed 16kHz mono file and swaps only
                // the converter when the input format changes.
                try installTapAndStart(writer: writer)
            } catch {
                logger.error("Falha ao reiniciar o mic após troca de dispositivo: \(error)")
                FileLog.shared.append("mic.restart FALHOU: \(error)")
            }
        }
    }
}
