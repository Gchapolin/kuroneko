import Foundation

/// Words the recognizer should spell the way the team writes them. Whisper
/// is conditioned on this text as if it were the previous sentence, which
/// pulls jargon towards its English spelling and names towards the right one.
public enum Vocabulary {
    public static let base = [
        "Kuroneko", "Google Meet", "pull request", "PR", "review", "merge", "deploy", "commit", "branch",
        "pipeline", "bug", "feature", "sprint", "daily", "backlog", "refinement", "precision", "recall",
        "dashboard", "endpoint", "Jira", "Slack", "GitHub", "OK",
    ]

    /// Kept short: Whisper only reads the last ~224 prompt tokens.
    public static func prompt(names: [String], extra: [String] = []) -> String {
        let words = names + extra + base
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        return unique.prefix(60).joined(separator: ", ") + "."
    }
}
