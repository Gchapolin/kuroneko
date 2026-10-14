import Foundation

/// The meeting's texts (the summary above all) call a voice the way the
/// transcript did when they were written: "Pessoa 2" before anyone said who
/// it was. Naming the voice later updates them in place, without asking
/// Claude again.
public enum NameReplacement {
    /// Every whole-word `old` in `text` becomes `new`: "Pessoa 1" never
    /// matches inside "Pessoa 10", nor "Ana" inside "Mariana".
    public static func replace(_ old: String, with new: String, in text: String) -> String {
        guard !old.isEmpty, old != new else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: new)
        )
    }
}
