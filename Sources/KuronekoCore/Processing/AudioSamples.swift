import AVFoundation
import Foundation

/// 16kHz mono Float32 samples, the format every model in the pipeline eats.
public enum AudioSamples {
    public static let sampleRate = 16000

    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == Double(sampleRate), format.channelCount == 1 else {
            throw CaptureError.unsupportedFormat("esperado 16kHz mono em \(url.lastPathComponent)")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CaptureError.unsupportedFormat("buffer de leitura")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    public static func slice(_ samples: [Float], from start: Double, to end: Double) -> [Float] {
        let lower = max(0, min(samples.count, Int(start * Double(sampleRate))))
        let upper = max(lower, min(samples.count, Int(end * Double(sampleRate))))
        return Array(samples[lower..<upper])
    }
}
