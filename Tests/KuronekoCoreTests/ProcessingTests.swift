import Foundation
import Testing
@testable import KuronekoCore

@Suite struct TurnBuilderTests {
    @Test func mergesSameSpeakerAcrossShortPauses() {
        let turns = TurnBuilder.turns(from: [
            SpeechSpan(start: 0, end: 2, speaker: "S1"),
            SpeechSpan(start: 2.5, end: 4, speaker: "S1"),
            SpeechSpan(start: 4.2, end: 6, speaker: "S2"),
            SpeechSpan(start: 9, end: 10, speaker: "S2"),
        ])

        #expect(turns == [
            SpeechSpan(start: 0, end: 4, speaker: "S1"),
            SpeechSpan(start: 4.2, end: 6, speaker: "S2"),
            SpeechSpan(start: 9, end: 10, speaker: "S2"),
        ])
    }

    @Test func neverMergesPastMaxDuration() {
        let spans = (0..<10).map { SpeechSpan(start: Double($0) * 5, end: Double($0) * 5 + 4.5, speaker: "S1") }

        let turns = TurnBuilder.turns(from: spans, maxDuration: 30)

        #expect(turns.allSatisfy { $0.duration <= 30 })
        #expect(turns.count == 2)
    }

    @Test func neverMergesDifferentLanguages() {
        let turns = TurnBuilder.turns(from: [
            SpeechSpan(start: 0, end: 3, speaker: "S1", language: "pt"),
            SpeechSpan(start: 3.5, end: 6, speaker: "S1", language: "es"),
        ])
        #expect(turns.count == 2)
    }

    @Test func isolatedSpansStayApartFromFullUtterances() {
        let turns = TurnBuilder.turns(from: [
            SpeechSpan(start: 0, end: 3, speaker: "S1", language: "pt"),
            SpeechSpan(start: 3.5, end: 6, speaker: "S1", language: "pt", isolated: true),
            SpeechSpan(start: 6.5, end: 9, speaker: "S1", language: "pt"),
        ])
        #expect(turns.count == 3)
    }

    @Test func isolatedSpansAbsorbShortFragments() {
        // "sobre" (1 s) right before "o que podemos hablar acá".
        let turns = TurnBuilder.turns(from: [
            SpeechSpan(start: 240.3, end: 241.3, speaker: "S1", language: "pt"),
            SpeechSpan(start: 242.1, end: 244.4, speaker: "S1", language: "pt", isolated: true),
        ])
        #expect(turns == [SpeechSpan(start: 240.3, end: 244.4, speaker: "S1", language: "pt", isolated: true)])
    }

    @Test func dropsBlips() {
        #expect(TurnBuilder.turns(from: [SpeechSpan(start: 1, end: 1.1, speaker: "S1")]).isEmpty)
    }
}

@Suite struct SpanAssemblerTests {
    @Test func recoversSpeechTheDiarizerMissed() {
        let diarized = [
            SpeechSpan(start: 134, end: 135.4, speaker: "S1"),
            SpeechSpan(start: 140, end: 150, speaker: "S2"),
        ]
        let detected = [
            SpeechSpan(start: 119.7, end: 120.9, speaker: "me"), // a lone "Olá"
            SpeechSpan(start: 133.9, end: 135.5, speaker: "me"), // already covered
            SpeechSpan(start: 151, end: 152, speaker: "me"),
        ]

        let spans = SpanAssembler.assemble(diarized: diarized, detected: detected)

        #expect(spans.map(\.speaker) == ["S1", "S1", "S2", "S2"])
        #expect(spans.first == SpeechSpan(start: 119.7, end: 120.9, speaker: "S1"))
    }

    @Test func speechTouchingADiarizedSpanExtendsIt() {
        let diarized = [SpeechSpan(start: 229.3, end: 232.6, speaker: "S1")]
        let detected = [SpeechSpan(start: 228.0, end: 238.4, speaker: "me")]

        let spans = SpanAssembler.assemble(diarized: diarized, detected: detected)

        #expect(spans == [
            SpeechSpan(start: 228.0, end: 238.4, speaker: "S1"),
        ])
    }

    @Test func withoutDiarizationAllSpeechIsOneVoice() {
        let detected = [SpeechSpan(start: 1, end: 3, speaker: "me")]
        #expect(SpanAssembler.assemble(diarized: [], detected: detected) == [SpeechSpan(start: 1, end: 3, speaker: "S1")])
    }
}

@Suite struct LanguagePickerTests {
    @Test func renormalizesAmongTeamLanguages() {
        let distribution = LanguagePicker.distribution(logProbs: ["pt": logf(0.3), "es": logf(0.1), "en": logf(0.1), "gl": logf(0.5)])

        #expect(abs((distribution["pt"] ?? 0) - 0.6) < 0.001)
        #expect(distribution["gl"] == nil)
    }

    private func span(_ start: Double, _ end: Double, _ speaker: String = "S1") -> SpeechSpan {
        SpeechSpan(start: start, end: end, speaker: speaker)
    }

    @Test func catchesASwitchToSpanishMidTurn() {
        // The first test call: Portuguese, then Spanish after a short pause.
        let spans = [span(229.3, 232.6), span(233.5, 238.2), span(242.1, 244.4), span(246.9, 248.1)]
        let languages = LanguagePicker.assign(spans, distributions: [
            0: ["pt": 0.9, "es": 0.08, "en": 0.02],
            1: ["pt": 0.2, "es": 0.78, "en": 0.02],
            2: ["pt": 0.25, "es": 0.7, "en": 0.05],
        ])

        // The 1.2 s tail is too short to detect: it follows its neighbor.
        #expect(languages == ["pt", "es", "es", "es"])
    }

    @Test func flagsUtterancesThatMayMixLanguages() {
        #expect(!LanguagePicker.isMixed(["pt": 1.0, "es": 0, "en": 0]))
        #expect(LanguagePicker.isMixed(["pt": 0.77, "es": 0.15, "en": 0.08]))
    }

    @Test func jargonHeavyPortugueseDoesNotBecomeEnglish() {
        let languages = LanguagePicker.assign([span(0, 5)], distributions: [0: ["pt": 0.3, "es": 0.05, "en": 0.65]])
        #expect(languages == ["pt"])
    }

    @Test func clearEnglishIsAllowed() {
        let languages = LanguagePicker.assign([span(0, 5)], distributions: [0: ["pt": 0.05, "es": 0.05, "en": 0.9]])
        #expect(languages == ["en"])
    }

    @Test func ambiguousOrIsolatedSpansFallBackToTheSpeakersLanguage() {
        let spans = [span(0, 20, "S1"), span(100, 101, "S1"), span(200, 205, "S1"), span(300, 301, "S2")]
        let languages = LanguagePicker.assign(spans, distributions: [
            0: ["es": 0.9, "pt": 0.1],
            2: ["es": 0.5, "pt": 0.45, "en": 0.05],
        ])

        #expect(languages == ["es", "es", "es", "pt"])
    }

    @Test func neighborsOfAnotherSpeakerDoNotCount() {
        let spans = [span(0, 5, "S1"), span(5.5, 6, "S2")]
        let languages = LanguagePicker.assign(spans, distributions: [0: ["es": 0.9, "pt": 0.1]])
        #expect(languages == ["es", "pt"])
    }

    @Test func priorWeighsByTimeSpoken() {
        let priors = LanguagePicker.speakerPriors([
            (speaker: "S1", duration: 20, distribution: ["es": 0.9, "pt": 0.1]),
            (speaker: "S1", duration: 3, distribution: ["pt": 0.9, "es": 0.1]),
            (speaker: "S2", duration: 10, distribution: ["pt": 0.8, "es": 0.2]),
            (speaker: "S3", duration: 1, distribution: ["es": 1]),
        ])

        #expect(priors == ["S1": "es", "S2": "pt"])
    }
}

@Suite struct HallucinationFilterTests {
    private func keep(_ text: String, logprob: Float = -0.3, ratio: Float = 1.5) -> Bool {
        HallucinationFilter.keep(text: text, avgLogprob: logprob, compressionRatio: ratio)
    }

    @Test func keepsRealSpeech() {
        #expect(keep("Tô testando aqui uma aplicação nova chamada Kuroneko"))
        #expect(keep("¿Cuándo hacemos el deploy?"))
        #expect(keep("Obrigado por assistir a demo, alguma pergunta?"))
    }

    @Test func dropsSilenceHallucinationsSeenInTheFirstTest() {
        #expect(!keep("Продолжение следует..."))
        #expect(!keep("ご視聴ありがとうございました"))
    }

    @Test func dropsCreditsAndOutros() {
        #expect(!keep("Legendas pela comunidade Amara.org"))
        #expect(!keep("Obrigado por assistir!"))
        #expect(!keep("Thanks for watching."))
    }

    @Test func dropsLowConfidenceAndRepetitiveText() {
        #expect(!keep("sim sim sim", logprob: -1.4))
        #expect(!keep("e aí e aí e aí e aí e aí e aí", ratio: 3.1))
        #expect(!keep("..."))
    }
}

@Suite struct EchoGateTests {
    private let rate = 16000

    private func noiseBurst(seconds: Double, seed: UInt64, amplitude: Float = 0.2) -> [Float] {
        var state = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 2 * amplitude
        }
    }

    /// System talks 1–4 s and 6–9 s with a varying envelope; the mic hears it
    /// back 50 ms later at a lower level, and the user talks 11–13 s alone.
    private func scenario() -> (mic: [Float], system: [Float]) {
        let total = 14 * rate
        var system = [Float](repeating: 0, count: total)
        for (start, seconds) in [(1.0, 3.0), (6.0, 3.0)] {
            let burst = noiseBurst(seconds: seconds, seed: UInt64(start * 10))
            for (offset, sample) in burst.enumerated() {
                // Syllable-like 4 Hz modulation so the envelopes have shape.
                let t = Double(offset) / Double(rate)
                system[Int(start * Double(rate)) + offset] = sample * Float(0.55 + 0.45 * sin(2 * .pi * 4 * t))
            }
        }
        var mic = noiseBurst(seconds: 14, seed: 99, amplitude: 0.0005)
        let delay = Int(0.05 * Double(rate))
        for index in delay..<total {
            mic[index] += 0.3 * system[index - delay]
        }
        let me = noiseBurst(seconds: 2, seed: 7)
        for (offset, sample) in me.enumerated() {
            mic[11 * rate + offset] += sample
        }
        return (mic, system)
    }

    @Test func dropsEchoAndKeepsTheUser() {
        let (mic, system) = scenario()
        let spans = [
            SpeechSpan(start: 1, end: 4, speaker: "me"),
            SpeechSpan(start: 6, end: 9, speaker: "me"),
            SpeechSpan(start: 11, end: 13, speaker: "me"),
        ]

        let kept = EchoGate.filter(spans: spans, mic: mic, system: system)

        #expect(kept == [SpeechSpan(start: 11, end: 13, speaker: "me")])
    }

    @Test func findsTheEchoDelay() {
        let (mic, system) = scenario()

        let lag = EchoGate.estimateLag(mic: EchoGate.envelope(mic), system: EchoGate.envelope(system))

        #expect(abs(lag - 5) <= 1)
    }

    @Test func withoutSystemAudioEverythingIsTheUser() {
        let mic = noiseBurst(seconds: 3, seed: 1)
        let spans = [SpeechSpan(start: 0, end: 3, speaker: "me")]

        #expect(EchoGate.filter(spans: spans, mic: mic, system: []) == spans)
    }
}

@Suite struct SpeakerMatcherTests {
    private func print(_ personId: Int64, _ vector: [Float]) -> Voiceprint {
        Voiceprint(personId: personId, meetingId: nil, embedding: EmbeddingCodec.encode(vector), createdAt: Date())
    }

    @Test func matchesTheClosestKnownVoice() {
        let prints = [print(1, [1, 0, 0]), print(1, [0.9, 0.1, 0]), print(2, [0, 1, 0])]

        #expect(SpeakerMatcher.match([0.95, 0.05, 0], voiceprints: prints)?.personId == 1)
        #expect(SpeakerMatcher.match([0.05, 0.95, 0], voiceprints: prints)?.personId == 2)
    }

    @Test func unknownVoiceStaysUnknown() {
        #expect(SpeakerMatcher.match([0, 0, 1], voiceprints: [print(1, [1, 0, 0])]) == nil)
        #expect(SpeakerMatcher.match([1, 0, 0], voiceprints: []) == nil)
    }

    @Test func refusesToChooseBetweenNearlyIdenticalCandidates() {
        let prints = [print(1, [1, 0.01, 0]), print(2, [1, 0, 0.01])]
        #expect(SpeakerMatcher.match([1, 0, 0], voiceprints: prints) == nil)
    }
}

@Suite struct VocabularyTests {
    @Test func putsNamesFirstWithoutDuplicates() {
        let prompt = Vocabulary.prompt(names: ["Matías", "Kuroneko"])
        #expect(prompt.hasPrefix("Matías, Kuroneko, Google Meet"))
        #expect(prompt.components(separatedBy: "Kuroneko").count == 2)
    }
}

@Suite struct SpeakerMarksTests {
    private let turns = [
        SpeakerMarks.Turn(startMs: 0, endMs: 5000, cluster: 0),
        SpeakerMarks.Turn(startMs: 6000, endMs: 12000, cluster: 1),
        SpeakerMarks.Turn(startMs: 30000, endMs: 35000, cluster: 2),
    ]

    @Test func parsesMentions() {
        #expect(SpeakerMarks.mentions(in: "@Valentina falando do deploy") == ["Valentina"])
        #expect(SpeakerMarks.mentions(in: "@Matías e @Bruno") == ["Matías", "Bruno"])
        #expect(SpeakerMarks.mentions(in: "sem marcação, só #acao") == [])
    }

    @Test func namesTheVoiceSpeakingAtTheMark() {
        let names = SpeakerMarks.resolve([SpeakerMarks.Mark(tMs: 8000, name: "Valentina")], turns: turns)
        #expect(names == [1: "Valentina"])
    }

    @Test func aMarkJustAfterTheVoiceStoppedStillCounts() {
        let names = SpeakerMarks.resolve([SpeakerMarks.Mark(tMs: 14000, name: "Valentina")], turns: turns)
        #expect(names == [1: "Valentina"])
    }

    @Test func aMarkInLongSilenceNamesNobody() {
        #expect(SpeakerMarks.resolve([SpeakerMarks.Mark(tMs: 22000, name: "Ana")], turns: turns).isEmpty)
    }

    @Test func mostFrequentNameWinsForOneVoice() {
        let names = SpeakerMarks.resolve([
            SpeakerMarks.Mark(tMs: 1000, name: "Ana"),
            SpeakerMarks.Mark(tMs: 2000, name: "Bruno"),
            SpeakerMarks.Mark(tMs: 3000, name: "ana"),
        ], turns: turns)
        #expect(names == [0: "ana"])
    }
}
