import Foundation
import Testing
@testable import KuronekoCore

/// Benchmark on two real AMI corpus meetings with the same four people
/// (ES2004a, ES2004b): who-spoke-when accuracy, and recognition of named
/// voices across meetings. Opt-in; fetch the Mix-Headset WAVs and the
/// pyannote AMI-diarization-setup RTTMs into one folder, then
/// KURONEKO_AMI=/that/folder swift test --filter DiarizationBenchmark
/// Baseline (FluidAudio 0.17.7, out/2026): 98% and 98%.
@Suite struct DiarizationBenchmarkTests {
    static let dir = ProcessInfo.processInfo.environment["KURONEKO_AMI"]

    struct Turn { let start: Double, end: Double, who: String }

    func rttm(_ name: String) throws -> [Turn] {
        try String(contentsOfFile: "\(Self.dir!)/\(name).rttm", encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                let f = line.split(separator: " ")
                guard f.count > 7, let s = Double(f[3]), let d = Double(f[4]) else { return nil }
                return Turn(start: s, end: s + d, who: String(f[7]))
            }
    }

    /// Per 100 ms frame with exactly one true speaker and one predicted label.
    func frames(_ truth: [Turn], _ spans: [SpeechSpan], length: Double) -> [(who: String, label: String)] {
        stride(from: 0.0, to: length, by: 0.1).compactMap { t in
            let real = truth.filter { $0.start <= t && t < $0.end }
            let predicted = spans.filter { $0.start <= t && t < $0.end }
            guard real.count == 1, predicted.count == 1 else { return nil }
            return (real[0].who, predicted[0].speaker)
        }
    }

    @Test(.enabled(if: dir != nil))
    func diarizesAndRecognizesRealMeetings() async throws {
        let diarizer = FluidDiarizer()
        var voiceprints: [Voiceprint] = []
        var names: [Int64: String] = [:]
        for (index, meeting) in ["ES2004a", "ES2004b"].enumerated() {
            let samples = try AudioSamples.load(URL(fileURLWithPath: "\(Self.dir!)/\(meeting).wav"))
            let started = Date()
            let result = try await diarizer.diarize(samples)
            let elapsed = Date().timeIntervalSince(started)
            let truth = try rttm(meeting)
            let pairs = frames(truth, result.spans, length: Double(samples.count) / 16000)
            var votes: [String: [String: Int]] = [:]
            for pair in pairs { votes[pair.label, default: [:]][pair.who, default: 0] += 1 }
            let majority = votes.mapValues { $0.max { $0.value < $1.value }!.key }
            let correct = pairs.filter { majority[$0.label] == $0.who }.count
            #expect(Double(correct) / Double(max(1, pairs.count)) >= 0.9)
            print(String(format: "AMI %@: %.0f min, %d vozes encontradas (reais %d), %.1fs; fala na voz certa (melhor mapeamento): %.0f%%",
                         meeting, Double(samples.count) / 16000 / 60, votes.count, Set(truth.map(\.who)).count, elapsed,
                         100 * Double(correct) / Double(max(1, pairs.count))))
            for (label, counts) in votes.sorted(by: { $0.key < $1.key }) {
                print("AMI \(meeting) \(label): \(counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value / 10)s" }.joined(separator: ", "))")
            }

            if index == 0 {
                // "Name" each voice of the first meeting after its majority speaker.
                for (label, who) in majority {
                    guard let embedding = result.embeddings[label] else { continue }
                    let personId = Int64(names.count + 1)
                    names[personId] = who
                    voiceprints.append(Voiceprint(personId: personId, meetingId: 1, embedding: EmbeddingCodec.encode(embedding), createdAt: Date()))
                }
            } else {
                var recognized: [String: String] = [:]
                for (label, embedding) in result.embeddings {
                    let sims = voiceprints.map { String(format: "%@ %.2f", names[$0.personId]!, SpeakerMatcher.cosine(embedding, EmbeddingCodec.decode($0.embedding))) }
                    let match = SpeakerMatcher.match(embedding, voiceprints: voiceprints)
                    recognized[label] = match.map { names[$0.personId]! }
                    print("AMI reconhecimento \(label) (de verdade: \(majority[label] ?? "?")): \(sims.joined(separator: ", ")) → \(recognized[label] ?? "desconhecida")")
                }
                let right = pairs.filter { recognized[$0.label] == $0.who }.count
                #expect(Double(right) / Double(pairs.count) >= 0.9)
                let unknown = pairs.filter { recognized[$0.label] == nil }.count
                print(String(format: "AMI ES2004b reconhecida automaticamente: %.0f%% certa, %.0f%% desconhecida, %.0f%% errada",
                             100 * Double(right) / Double(pairs.count), 100 * Double(unknown) / Double(pairs.count),
                             100 * Double(pairs.count - right - unknown) / Double(pairs.count)))
            }
        }
    }
}
