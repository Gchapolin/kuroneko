import Foundation

/// A meeting as plain Markdown: what the terminal shows and what Claude
/// reads to summarize it. Notes stay in the timeline where they were taken.
public enum TranscriptText {
    public static func render(
        _ meeting: MeetingExport,
        includeDocuments: Bool = true,
        timeZone: TimeZone = .current
    ) -> String {
        var lines = ["# \(meeting.title)", header(meeting, timeZone: timeZone)]
        let people = meeting.voices.map(\.name)
        if !people.isEmpty {
            lines.append("Participantes: \(people.joined(separator: ", "))")
        }
        if includeDocuments {
            for document in meeting.documents {
                let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
                // A summary from Claude already opens with its own heading.
                lines += body.hasPrefix("#") ? ["", body] : ["", "## \(title(ofKind: document.kind))", "", body]
            }
        }
        lines += ["", "## Transcrição", ""]
        for entry in meeting.timeline {
            let time = ClockTime.format(ms: entry.startMs)
            if entry.type == "note" {
                let at = entry.at.map { " (às \(clock($0, timeZone: timeZone)))" } ?? ""
                let files = (entry.attachments ?? []).map { $0.kind == "image" ? "[print]" : "[arquivo]" }
                let text = ([entry.text] + files).filter { !$0.isEmpty }.joined(separator: " ")
                lines.append("[\(time)] NOTA\(at): \(text)")
            } else {
                lines.append("[\(time)] \(entry.name ?? "?"): \(entry.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func title(ofKind kind: String) -> String {
        kind == "summary" ? "Resumo" : kind.prefix(1).uppercased() + kind.dropFirst()
    }

    private static func header(_ meeting: MeetingExport, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, d 'de' MMM 'de' yyyy, HH:mm"
        var text = formatter.string(from: meeting.startedAt)
        if let end = meeting.endedAt {
            text += "–\(clock(end, timeZone: timeZone))"
        }
        if let duration = meeting.durationMs {
            text += " (\(max(1, duration / 60_000)) min)"
        }
        return text
    }

    private static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Recording offsets as people write them: "03:21", "1:03:21".
public enum ClockTime {
    public static func format(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// "03:21" and "1:03:21" are clock offsets, "201000ms" is milliseconds
    /// and a bare number is seconds.
    public static func parse(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("ms") {
            return Int(text.dropLast(2)).flatMap { $0 >= 0 ? $0 : nil }
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let numbers = parts.compactMap { $0 }
        if numbers.count > 1, numbers.dropFirst().contains(where: { $0 >= 60 }) { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 } * 1000
    }
}

/// What Claude is asked when summarizing; the transcript goes on stdin.
public enum SummaryPrompt {
    public static let instructions = """
        Resuma a reunião cuja transcrição vem a seguir. Ela foi transcrita automaticamente: pode ter palavras erradas, e "Pessoa N" é uma voz ainda não identificada. Os horários [mm:ss] contam do início da gravação. Linhas "NOTA" são anotações pessoais do usuário, feitas durante a reunião naquele momento.

        Escreva em português, em Markdown, só com as seções que tiverem conteúdo:

        ## Resumo
        De 3 a 6 frases sobre o que foi tratado.

        ## Decisões
        ## Pendências
        Uma por linha: "- [ ] o quê — quem (se foi dito) [mm:ss]".

        ## Minhas notas
        Cada NOTA do usuário, com o assunto que estava sendo falado naquele momento e o que ficou combinado sobre ele.

        ## Pontos em aberto

        Cite o horário [mm:ss] de onde tirou cada item. Não invente nada que não esteja na transcrição. Responda só com o Markdown, sem comentários antes ou depois.
        """
}

/// The app and the `kuroneko` command share the database; after a change
/// the command tells the app to reload what it shows.
public enum ExternalChange {
    public static let notification = Notification.Name("com.gandarfh.kuroneko.dataChanged")

    public static func post() {
        DistributedNotificationCenter.default().postNotificationName(
            notification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
