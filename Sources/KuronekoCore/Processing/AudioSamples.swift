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

    /// Seconds of audio in a WAV written by `ResamplingWavWriter`, including
    /// one still being recorded.
    public static func recordedDuration(_ url: URL) throws -> Double {
        let data = try dataChunkOffset(url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        return Double(size > data ? (size - data) / 2 : 0) / Double(sampleRate)
    }

    /// `start..<end` seconds of such a WAV, even while it is being recorded
    /// (AVAudioFile only sees what the header declares, which is written on
    /// close); shorter when the file ends before `end`.
    public static func load(_ url: URL, from start: Double, to end: Double) throws -> [Float] {
        let data = try dataChunkOffset(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: data + UInt64(max(0, Int(start * Double(sampleRate)))) * 2)
        let count = max(0, Int(end * Double(sampleRate)) - Int(start * Double(sampleRate)))
        let bytes = try handle.read(upToCount: count * 2) ?? Data()
        return bytes.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
    }

    /// Where the samples start: after the RIFF header and every chunk
    /// before "data", whose own size is not final until the file is closed.
    private static func dataChunkOffset(_ url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64 * 1024) ?? Data()
        let bytes = [UInt8](header)
        func id(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        func uint32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        guard bytes.count >= 12, id(0) == "RIFF", id(8) == "WAVE" else {
            throw CaptureError.unsupportedFormat("\(url.lastPathComponent) não é WAV")
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = uint32(offset + 4)
            switch id(offset) {
            case "data":
                return UInt64(offset + 8)
            case "fmt " where offset + 24 <= bytes.count:
                let channels = Int(bytes[offset + 10]) | Int(bytes[offset + 11]) << 8
                let bits = Int(bytes[offset + 22]) | Int(bytes[offset + 23]) << 8
                guard channels == 1, uint32(offset + 12) == sampleRate, bits == 16 else {
                    throw CaptureError.unsupportedFormat("esperado 16kHz mono 16 bits em \(url.lastPathComponent)")
                }
            default:
                break
            }
            offset += 8 + size + size % 2
        }
        throw CaptureError.unsupportedFormat("\(url.lastPathComponent) ainda sem áudio")
    }

    public static func slice(_ samples: [Float], from start: Double, to end: Double) -> [Float] {
        let lower = max(0, min(samples.count, Int(start * Double(sampleRate))))
        let upper = max(lower, min(samples.count, Int(end * Double(sampleRate))))
        return Array(samples[lower..<upper])
    }
}
