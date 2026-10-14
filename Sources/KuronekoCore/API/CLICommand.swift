import Foundation

/// The `kuroneko` command line: one entry point for editors, scripts and
/// Claude. Everything it prints is JSON, except `transcript` and `help`.
public enum CLICommand: Equatable, Sendable {
    case meetings
    case meeting(id: Int64)
    case transcript(id: Int64)
    case search(String)
    case people
    case name(meetingId: Int64, voice: String, person: String)
    case noteAdd(meetingId: Int64, atMs: Int, text: String)
    case noteRemove(noteId: Int64)
    case summarize(meetingId: Int64)
    /// Body read from stdin.
    case documentSet(meetingId: Int64, kind: String)
    case documentRemove(meetingId: Int64, kind: String)
    case linkAdd(meetingId: Int64, url: String, title: String?)
    case linkRemove(linkId: Int64)
    case play(meetingId: Int64, fromMs: Int)
    case help

    public static let usage = """
        kuroneko — reuniões do Kuroneko pela linha de comando (saída em JSON)

          kuroneko meetings                         reuniões, mais recentes primeiro
          kuroneko meeting <id>                     transcrição, vozes, notas e resumos
          kuroneko transcript <id>                  a reunião em Markdown
          kuroneko search <texto>                   busca em falas e notas
          kuroneko people                           pessoas conhecidas
          kuroneko name <id> <voz> <nome>           diz quem é uma voz (c1, 2 ou "Pessoa 2")
          kuroneko note add <id> --at <tempo> <texto>
          kuroneko note rm <id-da-nota>
          kuroneko summarize <id>                   gera o resumo com o Claude e salva
          kuroneko doc set <id> <tipo>              salva um texto da reunião (stdin)
          kuroneko doc rm <id> <tipo>
          kuroneko link add <id> <url> [título]     guarda um link da reunião (PR, ticket, doc)
          kuroneko link rm <id-do-link>
          kuroneko play <id> [--at <tempo>]         toca até o fim ou Ctrl-C; imprime a posição

        <tempo>: 03:21, 1:03:21, 201000ms ou segundos.
        """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        var args = arguments
        guard !args.isEmpty else { return .help }
        let verb = args.removeFirst()
        switch verb {
        case "help", "-h", "--help":
            return .help
        case "meetings", "list":
            try expectNoMore(args)
            return .meetings
        case "meeting", "show":
            return .meeting(id: try takeId(&args))
        case "transcript":
            return .transcript(id: try takeId(&args))
        case "search":
            let query = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { throw CLIError("informe o que buscar") }
            return .search(query)
        case "people":
            try expectNoMore(args)
            return .people
        case "name":
            let id = try takeId(&args)
            guard args.count >= 2 else { throw CLIError("uso: kuroneko name <id> <voz> <nome>") }
            let voice = args.removeFirst()
            return .name(meetingId: id, voice: voice, person: args.joined(separator: " "))
        case "note":
            guard !args.isEmpty else { throw CLIError("uso: kuroneko note add|rm …") }
            switch args.removeFirst() {
            case "add":
                let id = try takeId(&args)
                let at = try takeOption("--at", from: &args).flatMap(ClockTime.parse)
                guard let at else { throw CLIError("informe o momento da nota com --at 03:21") }
                let text = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw CLIError("a nota está vazia") }
                return .noteAdd(meetingId: id, atMs: at, text: text)
            case "rm":
                return .noteRemove(noteId: try takeId(&args))
            default:
                throw CLIError("uso: kuroneko note add|rm …")
            }
        case "summarize":
            return .summarize(meetingId: try takeId(&args))
        case "doc":
            guard !args.isEmpty else { throw CLIError("uso: kuroneko doc set|rm <id> <tipo>") }
            let action = args.removeFirst()
            let id = try takeId(&args)
            guard args.count == 1, let kind = args.first, !kind.isEmpty else {
                throw CLIError("uso: kuroneko doc set|rm <id> <tipo>")
            }
            switch action {
            case "set": return .documentSet(meetingId: id, kind: kind)
            case "rm": return .documentRemove(meetingId: id, kind: kind)
            default: throw CLIError("uso: kuroneko doc set|rm <id> <tipo>")
            }
        case "link":
            guard !args.isEmpty else { throw CLIError("uso: kuroneko link add|rm …") }
            switch args.removeFirst() {
            case "add":
                let id = try takeId(&args)
                guard !args.isEmpty else { throw CLIError("uso: kuroneko link add <id> <url> [título]") }
                let text = args.removeFirst()
                guard let url = LinkLabel.normalize(text) else { throw CLIError("link inválido: \(text)") }
                let title = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return .linkAdd(meetingId: id, url: url, title: title.isEmpty ? nil : title)
            case "rm":
                return .linkRemove(linkId: try takeId(&args))
            default:
                throw CLIError("uso: kuroneko link add|rm …")
            }
        case "play":
            let id = try takeId(&args)
            let at = try takeOption("--at", from: &args)
            try expectNoMore(args)
            guard let from = at == nil ? 0 : at.flatMap(ClockTime.parse) else {
                throw CLIError("tempo inválido: \(at ?? "")")
            }
            return .play(meetingId: id, fromMs: from)
        default:
            throw CLIError("comando desconhecido: \(verb)\n\n\(usage)")
        }
    }

    private static func takeId(_ args: inout [String]) throws -> Int64 {
        guard !args.isEmpty else { throw CLIError("informe o id") }
        let text = args.removeFirst()
        guard let id = Int64(text), id > 0 else { throw CLIError("id inválido: \(text)") }
        return id
    }

    private static func takeOption(_ name: String, from args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw CLIError("\(name) precisa de um valor") }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }

    private static func expectNoMore(_ args: [String]) throws {
        guard args.isEmpty else { throw CLIError("argumento inesperado: \(args[0])") }
    }
}

public struct CLIError: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Which voice of a meeting a person typed: "c1" (the JSON key), "2" or
/// "Pessoa 2" (the label shown everywhere, numbered from 1).
public enum VoiceRef {
    public static func cluster(from text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("c"), let cluster = Int(text.dropFirst()), cluster >= 0 {
            return cluster
        }
        let number = text.lowercased().hasPrefix("pessoa") ? String(text.dropFirst("pessoa".count)) : text
        guard let label = Int(number.trimmingCharacters(in: .whitespaces)), label >= 1 else { return nil }
        return label - 1
    }
}
