import AVFoundation
import Foundation

/// Converts incoming PCM buffers (any format/rate) to 16kHz mono Int16 WAV,
/// the input format expected by Whisper and small enough to keep whole
/// meetings on disk.
public final class ResamplingWavWriter {
    public static let outputSampleRate: Double = 16000

    private var converter: AVAudioConverter
    private var inputFormat: AVAudioFormat
    private var file: AVAudioFile?
    private let outputFormat: AVAudioFormat
    private let meter: SpeechMeter?

    public init(inputFormat: AVAudioFormat, fileURL: URL, meter: SpeechMeter? = nil) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw CaptureError.unsupportedFormat("output 16kHz mono")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.unsupportedFormat("conversion from \(inputFormat)")
        }
        self.outputFormat = outputFormat
        self.meter = meter
        self.inputFormat = inputFormat
        self.converter = converter
        self.file = try AVAudioFile(
            forWriting: fileURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, buffer.frameLength > 0 else { return }
        // The input format can change mid-file when the capture pipeline is
        // rebuilt (output device switch); only the converter is replaced, the
        // file keeps its fixed 16kHz mono format.
        if buffer.format != inputFormat {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw CaptureError.unsupportedFormat("conversion from \(buffer.format)")
            }
            converter = newConverter
            inputFormat = buffer.format
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.unsupportedFormat("output buffer allocation")
        }

        // The input block is invoked synchronously on this thread during
        // convert(to:error:), so the captures never race despite the
        // @Sendable annotation on the block.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? CaptureError.unsupportedFormat("conversion failed")
        }
        if output.frameLength > 0 {
            try file.write(from: output)
            if let meter, let samples = output.int16ChannelData?[0] {
                meter.hear(level: SpeechMeter.level(of: UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
            }
        }
    }

    public func appendSilence(seconds: TimeInterval) throws {
        guard let file, seconds > 0 else { return }
        let frames = AVAudioFrameCount(seconds * outputFormat.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else {
            throw CaptureError.unsupportedFormat("silence buffer allocation")
        }
        silence.frameLength = frames
        // Freshly allocated PCM buffers are not guaranteed to be zeroed.
        if let samples = silence.int16ChannelData?[0] {
            samples.update(repeating: 0, count: Int(frames))
        }
        try file.write(from: silence)
    }

    /// Releases the underlying AVAudioFile, which is what finalizes the WAV
    /// header on disk. Reading the file before this reports zero frames.
    public func finish() {
        file = nil
    }
}
