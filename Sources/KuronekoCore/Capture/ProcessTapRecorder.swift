import AVFoundation
import CoreAudio
import Foundation
import os

public enum CaptureError: Error {
    case unsupportedFormat(String)
    case alreadyRecording
    case tapCreationFailed(OSStatus)
}

/// Records system audio through a Core Audio process tap wrapped in a
/// private aggregate device, following the AudioCap/Muesli reference
/// implementations.
public final class ProcessTapRecorder: @unchecked Sendable {
    public enum Target: Sendable {
        case processes([AudioObjectID])
        case globalExcludingCurrentProcess
    }

    private let queue = DispatchQueue(label: "com.gandarfh.kuroneko.tap", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "ProcessTapRecorder")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: ResamplingWavWriter?
    private var tapFormat: AVAudioFormat?
    private var target: Target?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private let meter: SpeechMeter?

    public init(meter: SpeechMeter? = nil) {
        self.meter = meter
    }

    /// Creating a tap is also the only public way to trigger (and probe) the
    /// "System Audio Recording" TCC prompt, so a throwing start doubles as
    /// the permission request.
    public func start(target: Target, fileURL: URL) throws {
        try queue.sync {
            guard writer == nil else { throw CaptureError.alreadyRecording }
            self.target = target
            try buildTapPipeline(fileURL: fileURL)
            installOutputDeviceListener()
        }
    }

    public func stop() {
        queue.sync {
            removeOutputDeviceListener()
            teardownTapPipeline()
            writer?.finish()
            writer = nil
            target = nil
        }
    }

    // MARK: - Pipeline (always called on `queue`)

    private func buildTapPipeline(fileURL: URL?) throws {
        let description = try makeTapDescription()
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard createStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(createStatus)
        }
        tapID = newTapID

        do {
            var streamDescription = try CoreAudioSupport.readTapStreamDescription(tapID)
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.unsupportedFormat("tap stream description")
            }
            tapFormat = format
            if let fileURL {
                writer = try ResamplingWavWriter(inputFormat: format, fileURL: fileURL, meter: meter)
            }

            let outputUID = try CoreAudioSupport.readDefaultSystemOutputDeviceUID()
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Kuroneko Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        // Must be the UUID string: handing CATapDescription
                        // objects to the HAL crashes coreaudiod.
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try CoreAudioSupport.check(
                AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID),
                "createAggregateDevice"
            )
            aggregateID = newAggregateID

            try CoreAudioSupport.check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
                    self?.handleAudio(inInputData)
                },
                "createIOProc"
            )
            try CoreAudioSupport.check(
                AudioDeviceStart(aggregateID, ioProcID),
                "deviceStart"
            )
        } catch {
            teardownTapPipeline()
            throw error
        }
    }

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription
        switch target {
        case .processes(let objects):
            description = CATapDescription(monoMixdownOfProcesses: objects)
        case .globalExcludingCurrentProcess, .none:
            let exclusions = AudioProcessFinder.currentProcessAudioObject().map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: exclusions)
        }
        description.uuid = UUID()
        description.name = "Kuroneko"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func handleAudio(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let writer, let tapFormat else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: bufferList,
            deallocator: nil
        ), buffer.frameLength > 0 else { return }
        do {
            try writer.append(buffer)
        } catch {
            // Never throw out of the IO callback; losing one buffer is
            // better than killing the capture session.
            logger.error("Falha ao gravar buffer do tap: \(error)")
        }
    }

    private func teardownTapPipeline() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapFormat = nil
    }

    // MARK: - Default output device changes

    /// The tap pipeline is bound to the output route at creation time, so
    /// switching outputs mid-meeting (AirPods connecting, for example) would
    /// silently stop delivering audio unless the pipeline is rebuilt.
    private func installOutputDeviceListener() {
        var address = CoreAudioSupport.globalAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async {
                guard self.writer != nil else { return }
                self.logger.notice("Saída padrão mudou; reconstruindo o tap")
                self.teardownTapPipeline()
                do {
                    try self.buildTapPipeline(fileURL: nil)
                } catch {
                    self.logger.error("Falha ao reconstruir tap após troca de saída: \(error)")
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        if status == noErr {
            outputDeviceListener = listener
        }
    }

    private func removeOutputDeviceListener() {
        guard let outputDeviceListener else { return }
        var address = CoreAudioSupport.globalAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            outputDeviceListener
        )
        self.outputDeviceListener = nil
    }
}
