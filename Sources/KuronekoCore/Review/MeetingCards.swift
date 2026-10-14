import Foundation

/// Who was in a meeting, in one line: "Ana, Bruno, Lucía, Marta e mais 2".
public enum PeopleText {
    public static func line(_ names: [String], limit: Int = 4) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        return names.prefix(limit).joined(separator: ", ") + " e mais \(names.count - limit)"
    }
}

/// What a meeting card says it has, in this order. `kind` is free-form
/// ("summary", "tasks", "notes", "voices") so the UI picks its colors.
public struct MeetingBadge: Equatable, Sendable {
    public var kind: String
    public var text: String

    public static func badges(for item: MeetingListItem) -> [MeetingBadge] {
        var badges: [MeetingBadge] = []
        if item.documents.contains("summary") {
            badges.append(MeetingBadge(kind: "summary", text: "Resumo"))
        }
        if item.openTaskCount > 0 {
            badges.append(MeetingBadge(kind: "tasks", text: CountText.of(item.openTaskCount, "pendência", "pendências")))
        }
        if item.noteCount > 0 {
            var text = CountText.of(item.noteCount, "nota", "notas")
            if item.attachmentCount > 0 {
                text += " · " + CountText.of(item.attachmentCount, "print", "prints")
            }
            badges.append(MeetingBadge(kind: "notes", text: text))
        }
        if item.unnamedVoiceCount > 0 {
            badges.append(MeetingBadge(kind: "voices", text: CountText.of(item.unnamedVoiceCount, "voz sem nome", "vozes sem nome")))
        }
        return badges
    }
}

/// The lines of a "Novidades" item in the menu.
public enum NewsText {
    /// "3 pendências · 2 decisões · 1h de reunião"; counts of zero are left out.
    public static func summaryReady(openTasks: Int, decisions: Int, durationMs: Int?) -> String {
        var parts: [String] = []
        if openTasks > 0 { parts.append(CountText.of(openTasks, "pendência", "pendências")) }
        if decisions > 0 { parts.append(CountText.of(decisions, "decisão", "decisões")) }
        if let durationMs { parts.append("\(DurationText.short(ms: durationMs)) de reunião") }
        return parts.joined(separator: " · ")
    }
}
