import AVFoundation
import Foundation
import KuronekoCore

/// `kuroneko`: reads and changes the meetings the app recorded, for editors,
/// scripts and Claude. JSON on stdout, errors on stderr.
@main
struct KuronekoCommand {
    static func main() async {
        do {
            let command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
            if command == .help {
                print(CLICommand.usage)
                return
            }
            let storage = MeetingStorage.standard()
            let db = try AppDatabase.open(storage)
            try await run(command, db: db)
        } catch let error as CLIError {
            fail(error.description, code: 2)
        } catch {
            fail("\(error)", code: 1)
        }
    }

    static func run(_ command: CLICommand, db: AppDatabase) async throws {
        switch command {
        case .help:
            print(CLICommand.usage)
        case .meetings:
            try output(db.meetingList())
        case .meeting(let id):
            try output(try export(id, db: db))
        case .transcript(let id):
            print(TranscriptText.render(try export(id, db: db)), terminator: "")
        case .search(let query):
            try output(try searchResults(query, db: db))
        case .people:
            try output(db.persons().map { PersonJSON(id: $0.id, name: $0.name) })
        case .name(let meetingId, let voice, let person):
            guard let cluster = VoiceRef.cluster(from: voice) else { throw CLIError("voz inválida: \(voice)") }
            guard try db.speakers(meetingId: meetingId).contains(where: { $0.diarCluster == cluster }) else {
                throw CLIError("a reunião \(meetingId) não tem a voz \(SpeakerLabel.label(cluster: cluster))")
            }
            try db.assignSpeaker(meetingId: meetingId, diarCluster: cluster, personName: person)
            changed()
            try output(try export(meetingId, db: db).voices)
        case .noteAdd(let meetingId, let atMs, let text):
            _ = try export(meetingId, db: db)
            let note = try db.addNote(meetingId: meetingId, tMs: atMs, text: text)
            changed()
            try output(try export(meetingId, db: db).timeline.first { $0.noteId == note.id })
        case .noteRemove(let noteId):
            guard try db.note(id: noteId) != nil else { throw CLIError("nota \(noteId) não existe") }
            try db.deleteNote(noteId)
            changed()
            try output(["removed": noteId])
        case .summarize(let meetingId):
            let meeting = try export(meetingId, db: db)
            guard meeting.timeline.contains(where: { $0.type == "speech" }) else {
                throw CLIError("a reunião \(meetingId) ainda não tem transcrição")
            }
            let body = try Claude.run(
                prompt: SummaryPrompt.instructions,
                input: TranscriptText.render(meeting, includeDocuments: false)
            )
            let document = try db.setDocument(meetingId: meetingId, kind: "summary", body: body, source: "claude")
            changed()
            try output(MeetingExport.Document(document))
        case .documentSet(let meetingId, let kind):
            _ = try export(meetingId, db: db)
            let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError("texto vazio no stdin") }
            let document = try db.setDocument(meetingId: meetingId, kind: kind, body: body, source: "manual")
            changed()
            try output(MeetingExport.Document(document))
        case .documentRemove(let meetingId, let kind):
            try db.deleteDocument(meetingId: meetingId, kind: kind)
            changed()
            try output(["removed": kind])
        case .linkAdd(let meetingId, let url, let title):
            _ = try export(meetingId, db: db)
            let link = try db.addLink(meetingId: meetingId, url: url, title: title)
            changed()
            try output(MeetingExport.Link(link))
        case .linkRemove(let linkId):
            guard try db.link(id: linkId) != nil else { throw CLIError("link \(linkId) não existe") }
            try db.deleteLink(linkId)
            changed()
            try output(["removed": linkId])
        case .tasks:
            try output(db.openTasks())
        case .taskDone(let ref, let done):
            let task = try db.setTaskDone(ref, done)
            changed()
            try output(task)
        case .play(let meetingId, let fromMs):
            try Playback.play(try export(meetingId, db: db), fromMs: fromMs)
        }
    }

    private struct PersonJSON: Encodable {
        var id: Int64?
        var name: String
    }

    private struct SearchResult: Encodable {
        var meetingId: Int64
        var meetingTitle: String
        var startMs: Int
        var type: String
        var name: String?
        var text: String
    }

    private static func export(_ id: Int64, db: AppDatabase) throws -> MeetingExport {
        guard let meeting = try db.export(meetingId: id) else { throw CLIError("reunião \(id) não existe") }
        return meeting
    }

    private static func searchResults(_ query: String, db: AppDatabase) throws -> [SearchResult] {
        let titles = Dictionary(uniqueKeysWithValues: try db.meetings().compactMap { meeting in meeting.id.map { ($0, meeting.title) } })
        let persons = Dictionary(uniqueKeysWithValues: try db.persons().compactMap { person in person.id.map { ($0, person.name) } })
        return try db.search(query).map { hit in
            var result = SearchResult(meetingId: hit.meetingId, meetingTitle: titles[hit.meetingId] ?? "", startMs: hit.tMs, type: "note", text: hit.text)
            if case .speech(let channel, let cluster, let personId) = hit.kind {
                let key = channel == .mic ? "me" : "c\(cluster ?? 0)"
                result.type = "speech"
                result.name = SpeakerLabel.name(key: key, personId: personId, persons: persons)
            }
            return result
        }
    }

    /// The app reloads what it shows.
    private static func changed() {
        ExternalChange.post()
    }

    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = isatty(STDOUT_FILENO) != 0 ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("kuroneko: \(message)\n".utf8))
        exit(code)
    }
}

/// Runs `claude -p` (Claude Code, with the user's own account): the
/// instructions as the prompt, the transcript on stdin.
enum Claude {
    static func run(prompt: String, input: String) throws -> String {
        let process = Process()
        if let path = ProcessInfo.processInfo.environment["KURONEKO_CLAUDE"] {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-p", prompt]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "-p", prompt]
        }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CLIError("não foi possível rodar o claude: \(error.localizedDescription)")
        }
        // Written from another thread: a large transcript would otherwise
        // fill the pipe while claude is still starting up.
        let writer = Thread {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("o claude falhou (\(process.terminationStatus))\(detail.isEmpty ? "" : ": \(detail)")")
        }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CLIError("o claude não devolveu nada") }
        return text
    }
}

/// Plays both channels of a meeting together until the end or until the
/// process is stopped (Ctrl-C, or the editor killing it), printing the
/// position as JSON lines so a client can follow along.
enum Playback {
    static func play(_ meeting: MeetingExport, fromMs: Int) throws {
        let players = [meeting.audio.system, meeting.audio.mic]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap { try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: $0)) }
        guard let first = players.first else { throw CLIError("a reunião \(meeting.id) não tem áudio") }
        let start = first.deviceCurrentTime + 0.05
        for player in players {
            player.prepareToPlay()
            player.currentTime = min(Double(fromMs) / 1000, player.duration)
            player.play(atTime: start)
        }
        repeat {
            report(Int(first.currentTime * 1000), done: false)
            Thread.sleep(forTimeInterval: 0.5)
        } while players.contains(where: \.isPlaying)
        report(Int(first.duration * 1000), done: true)
    }

    private static func report(_ positionMs: Int, done: Bool) {
        FileHandle.standardOutput.write(Data("{\"positionMs\":\(positionMs),\"done\":\(done)}\n".utf8))
    }
}
