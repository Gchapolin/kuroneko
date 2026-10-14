import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SummarizerTests {
    private func transcribed(_ db: AppDatabase) throws -> Int64 {
        let id = try db.startMeeting(title: "Planning").id!
        try db.endMeeting(id)
        try db.saveTranscript(
            meetingId: id,
            speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 5000)],
            segments: [Segment(meetingId: id, tStartMs: 60_000, tEndMs: 65_000, channel: .system, diarCluster: 0, text: "migrar o banco até sexta")]
        )
        return id
    }

    @Test func savesClaudesSummaryAndMarksNews() throws {
        let db = try AppDatabase.inMemory()
        let id = try transcribed(db)
        let seen = Locked<[String]>([])
        let summarizer = Summarizer(db: db) { prompt, input in
            seen.value = [prompt, input]
            return "## Resumo\nMigração até sexta."
        }

        #expect(try summarizer.needsSummary(meetingId: id))
        let document = try summarizer.summarize(meetingId: id, markingNews: true)

        #expect(document.kind == "summary")
        #expect(document.source == "claude")
        #expect(seen.value.first == SummaryPrompt.instructions)
        #expect(seen.value.last?.contains("[01:00] Pessoa 1: migrar o banco até sexta") == true)
        #expect(try !summarizer.needsSummary(meetingId: id))
        #expect(try db.meetingsWithNews().map(\.id) == [id])
    }

    @Test func onRequestItIsNotNews() throws {
        let db = try AppDatabase.inMemory()
        let id = try transcribed(db)

        try Summarizer(db: db) { _, _ in "resumo" }.summarize(meetingId: id)

        #expect(try db.meetingsWithNews().isEmpty)
    }

    @Test func nothingToSummarizeWithoutSpeech() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.startMeeting(title: "Vazia").id!
        let summarizer = Summarizer(db: db) { _, _ in Issue.record("claude não devia rodar"); return "" }

        #expect(try !summarizer.needsSummary(meetingId: id))
        #expect(throws: SummaryError.noTranscript(id)) { try summarizer.summarize(meetingId: id) }
        #expect(throws: SummaryError.noMeeting(99)) { try summarizer.summarize(meetingId: 99) }
    }

    @Test func aFailedRunSavesNothing() throws {
        let db = try AppDatabase.inMemory()
        let id = try transcribed(db)

        #expect(throws: ClaudeError.emptyOutput) {
            try Summarizer(db: db) { _, _ in throw ClaudeError.emptyOutput }.summarize(meetingId: id, markingNews: true)
        }
        #expect(try db.documents(meetingId: id).isEmpty)
        #expect(try db.meetingsWithNews().isEmpty)
    }
}

@Suite struct NewsTests {
    @Test func newsUntilSeen() throws {
        let db = try AppDatabase.inMemory()
        let old = try db.startMeeting(title: "Antiga").id!
        let new = try db.startMeeting(title: "Nova").id!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try db.markNews(meetingId: new, at: now)
        try db.markNews(meetingId: old, at: now.addingTimeInterval(60))

        #expect(try db.meetingsWithNews().map(\.id) == [old, new])
        #expect(try db.meetingList().first { $0.id == new }?.newsAt == now)
        try db.markSeen(meetingId: old)
        #expect(try db.meetingsWithNews().map(\.id) == [new])
        try db.deleteMeeting(new)
        #expect(try db.meetingsWithNews().isEmpty)
    }
}

@Suite struct ClaudeCLITests {
    /// A stand-in for claude: a shell script in a fresh folder.
    private func script(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func passesThePromptAndTheInputOnStdin() throws {
        let claude = try script(#"echo "prompt=$1 $2"; tr a-z A-Z"#)
        defer { try? FileManager.default.removeItem(at: claude.deletingLastPathComponent()) }

        let text = try ClaudeCLI.run(executable: claude, environment: [:], prompt: "resuma", input: "olá mundo\n", timeout: 10)

        #expect(text == "prompt=-p resuma\nOLá MUNDO")
    }

    @Test func reportsFailuresAndTimeouts() throws {
        let failing = try script("echo 'sem login' >&2; exit 3")
        let silent = try script("cat > /dev/null")
        let slow = try script("sleep 30")
        defer {
            for url in [failing, silent, slow] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        #expect(throws: ClaudeError.failed(status: 3, detail: "sem login")) {
            try ClaudeCLI.run(executable: failing, environment: [:], prompt: "x", input: "y", timeout: 10)
        }
        #expect(throws: ClaudeError.emptyOutput) {
            try ClaudeCLI.run(executable: silent, environment: [:], prompt: "x", input: "y", timeout: 10)
        }
        let start = Date()
        #expect(throws: ClaudeError.timedOut(1)) {
            try ClaudeCLI.run(executable: slow, environment: [:], prompt: "x", input: "y", timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func findsClaudeLikeTheUsersShell() throws {
        let claude = try script("true")
        let folder = claude.deletingLastPathComponent().path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let home = "/nonexistent-home"

        let (overridden, _) = try ClaudeCLI.locate(environment: ["KURONEKO_CLAUDE": "/opt/claude", "PATH": folder], home: home, knownDirectories: []) { _ in nil }
        #expect(overridden.path == "/opt/claude")

        let (inPath, environment) = try ClaudeCLI.locate(environment: ["PATH": "/usr/bin:\(folder)"], home: home, knownDirectories: []) { _ in
            Issue.record("o shell não devia ser consultado")
            return nil
        }
        #expect(inPath.path == claude.path)
        #expect(environment["PATH"] == "/usr/bin:\(folder)")

        // From Finder: only the login shell knows where claude is.
        let asked = Locked<[Bool]>([])
        let (fromShell, shellEnvironment) = try ClaudeCLI.locate(environment: ["PATH": "/usr/bin:/bin"], home: home, knownDirectories: []) { interactive in
            asked.value.append(interactive)
            return interactive ? "\(folder):/usr/bin" : "/usr/bin"
        }
        #expect(fromShell.path == claude.path)
        #expect(asked.value == [false, true])
        #expect(shellEnvironment["PATH"]?.hasPrefix("\(folder):/usr/bin:") == true)

        #expect(throws: ClaudeError.notFound) {
            try ClaudeCLI.locate(environment: ["PATH": "/nonexistent"], home: home, knownDirectories: []) { _ in nil }
        }
    }
}

/// A value tests can change from a @Sendable closure.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
