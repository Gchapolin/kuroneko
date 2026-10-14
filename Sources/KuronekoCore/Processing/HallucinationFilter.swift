import Foundation

/// Drops what Whisper invents instead of hearing. Silence and noise make it
/// emit subtitle credits and video outros from its training data ("Продолжение
/// следует...", "ご視聴ありがとうございました", "Legendas pela comunidade
/// Amara.org"); its own no-speech detector is not implemented in WhisperKit,
/// so these checks are the only guard besides feeding it speech only.
public enum HallucinationFilter {
    static let minAvgLogprob: Float = -1.0
    static let maxCompressionRatio: Float = 2.4

    /// Credits and outros that never come from a real meeting.
    static let creditFragments = [
        "amara.org", "legendas pela comunidade", "legendado por", "subtítulos realizados por",
        "subtitulado por", "subtitles by", "transcrição e legendas",
    ]

    /// Video outros, dropped only when they are the whole segment.
    static let outroPhrases: Set<String> = [
        "obrigado por assistir", "obrigada por assistir", "gracias por ver", "thanks for watching",
        "thank you for watching", "inscrevase no canal", "suscríbete", "subscribe",
        "legenda", "legendas", "subtítulos",
    ]

    public static func keep(text: String, avgLogprob: Float, compressionRatio: Float) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: \.isLetter) else { return false }
        guard avgLogprob >= minAvgLogprob, compressionRatio <= maxCompressionRatio else { return false }
        // The team speaks pt/es/en: anything mostly outside the Latin script
        // is invented.
        guard latinShare(of: trimmed) >= 0.7 else { return false }
        let lowered = trimmed.lowercased()
        if creditFragments.contains(where: lowered.contains) { return false }
        let normalized = lowered
            .filter { $0.isLetter || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        return !outroPhrases.contains(normalized)
    }

    private static func latinShare(of text: String) -> Double {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return 0 }
        let latin = letters.filter { $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }
        return Double(latin.count) / Double(letters.count)
    }
}
