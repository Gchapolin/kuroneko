import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SummaryItemsTests {
    private let summary = """
        ## Resumo
        Falamos do release 3.4 [00:30].

        ## Decisões
        - Adiar o cache de sessões para a 3.5 [12:31]
        - [ ] Login novo entra atrás de flag [1:02:03]

        ## Pendências
        - [ ] Abrir o card do cache de sessões — Bruno [12:31]
        - [x] Mandar o relatório do teste de carga — Lucía [31:10]
          - detalhe: incluir p99
        - Revisar o PR do login [44:52] — você
        * [X] Atualizar o board
        1. [ ] Medir o custo do cluster novo — Paulo [52:05–53:10]

        ## Minhas notas
        - [ ] não é pendência [10:00]
        """

    @Test func readsPendenciasAndDecisoes() {
        let items = SummaryItems.parse(summary)

        #expect(items.map(\.kind) == ["decision", "decision", "task", "task", "task", "task", "task"])
        #expect(items.map(\.text) == [
            "Adiar o cache de sessões para a 3.5",
            "Login novo entra atrás de flag",
            "Abrir o card do cache de sessões",
            "Mandar o relatório do teste de carga",
            "Revisar o PR do login",
            "Atualizar o board",
            "Medir o custo do cluster novo",
        ])
        #expect(items.map(\.owner) == [nil, nil, "Bruno", "Lucía", "você", nil, "Paulo"])
        #expect(items.map(\.startMs) == [751_000, 3_723_000, 751_000, 1_870_000, 2_692_000, nil, 3_125_000])
        #expect(items.map(\.done) == [false, false, false, true, false, true, false])
        #expect(items.map(\.line) == [4, 5, 8, 9, 11, 12, 13])
    }

    @Test func headingsWithoutHashesAndOtherSpellings() {
        let text = """
            **Pendências:**
            - [ ] Subir o QA — Ana

            Decisões
            * Usar Postgres

            Pontos em aberto
            - [ ] nada a ver

            ### Próximos passos
            - [ ] Marcar a retro – Marta [05:00]

            # Decisão final (2)
            - Fechado
            """

        let items = SummaryItems.parse(text)

        #expect(items.map(\.text) == ["Subir o QA", "Usar Postgres", "Marcar a retro", "Fechado"])
        #expect(items.map(\.kind) == ["task", "decision", "task", "decision"])
        #expect(items[2].owner == "Marta")
        #expect(items[2].startMs == 300_000)
    }

    @Test func ignoresEmptyAndPlaceholderBullets() {
        let text = "## Pendências\n- [ ] \n- Nenhuma pendência.\n- Nenhum deploy na sexta [10:00]\nTexto solto.\n"

        #expect(SummaryItems.parse(text).map(\.text) == ["Nenhum deploy na sexta"])
    }

    @Test func togglingRewritesOnlyTheCheckbox() throws {
        let text = "## Pendências\r\n- [ ] Abrir o card — Bruno [12:31]\r\n- Revisar o PR\r\n  * [x] Ver testes\r\n"

        let done = try #require(SummaryItems.setDone(true, line: 1, in: text))
        #expect(done == "## Pendências\r\n- [x] Abrir o card — Bruno [12:31]\r\n- Revisar o PR\r\n  * [x] Ver testes\r\n")
        let added = try #require(SummaryItems.setDone(true, line: 2, in: done))
        #expect(added == "## Pendências\r\n- [x] Abrir o card — Bruno [12:31]\r\n- [x] Revisar o PR\r\n  * [x] Ver testes\r\n")
        let undone = try #require(SummaryItems.setDone(false, line: 3, in: added))
        #expect(undone.hasSuffix("  * [ ] Ver testes\r\n"))
        #expect(SummaryItems.setDone(true, line: 1, in: done) == done)
        #expect(SummaryItems.setDone(true, line: 0, in: text) == nil)
        #expect(SummaryItems.setDone(true, line: 99, in: text) == nil)
        #expect(SummaryItems.parse(added).map(\.done) == [true, true])
    }
}

@Suite struct TaskTests {
    private let summary = """
        ## Resumo
        Release 3.4.

        ## Pendências
        - [ ] Abrir o card do cache — Bruno [12:31]
        - [x] Mandar o relatório — Lucía [31:10]
        """

    private func setUp() throws -> (AppDatabase, planning: Int64, daily: Int64) {
        let db = try AppDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let planning = try db.startMeeting(title: "Planning", at: start).id!
        let daily = try db.startMeeting(title: "Daily", at: start.addingTimeInterval(3600)).id!
        try db.setDocument(meetingId: planning, kind: "summary", body: summary, source: "claude", at: start)
        try db.addNote(meetingId: daily, tMs: 662_000, text: "subir o QA hoje #acao")
        try db.addNote(meetingId: daily, tMs: 700_000, text: "só uma nota")
        return (db, planning, daily)
    }

    @Test func openTasksComeFromSummariesAndAcaoNotes() throws {
        let (db, planning, daily) = try setUp()

        let open = try db.openTasks()

        #expect(open.map(\.text) == ["subir o QA hoje", "Abrir o card do cache"])
        #expect(open.map(\.meetingId) == [daily, planning])
        #expect(open.map(\.owner) == ["você", "Bruno"])
        #expect(open.map(\.startMs) == [662_000, 751_000])
        #expect(open.map(\.source) == ["note", "summary"])
        #expect(open.first?.meetingTitle == "Daily")
        #expect(try db.tasks().count == 3)
        #expect(try db.meetingList().map(\.openTaskCount) == [1, 1])
        let items = try #require(try db.export(meetingId: planning)?.summaryItems)
        #expect(items.map(\.ref) == (try db.tasks().filter { $0.source == "summary" }.map(\.ref)))
    }

    @Test func checkingOffASummaryLineSavesTheSummary() throws {
        let (db, planning, _) = try setUp()
        let task = try #require(try db.openTasks().first { $0.source == "summary" })
        let ref = try #require(TaskRef(task.ref))
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let done = try db.setTaskDone(ref, true, at: now)

        #expect(done.done)
        #expect(done.doneAt == now)
        let body = try #require(try db.documents(meetingId: planning).first?.body)
        #expect(body == summary.replacingOccurrences(of: "- [ ] Abrir", with: "- [x] Abrir"))
        #expect(try db.documents(meetingId: planning).first?.source == "claude")
        #expect(try db.openTasks().map(\.source) == ["note"])
        #expect(try db.doneTasks(since: now).map(\.text) == ["Abrir o card do cache", "Mandar o relatório"])

        try db.setTaskDone(ref, false)
        #expect(try db.documents(meetingId: planning).first?.body == summary)
    }

    @Test func aMovedLineIsStillFound() throws {
        let (db, planning, _) = try setUp()
        let ref = try #require(TaskRef(try db.openTasks().first { $0.source == "summary" }!.ref))
        try db.setDocument(meetingId: planning, kind: "summary", body: "Intro editada\n\n" + summary, source: "manual")

        let done = try db.setTaskDone(ref, true)

        #expect(done.text == "Abrir o card do cache")
        #expect(try db.documents(meetingId: planning).first?.body.contains("- [x] Abrir o card") == true)

        try db.setDocument(meetingId: planning, kind: "summary", body: "## Pendências\n- [ ] Outra coisa", source: "manual")
        #expect(throws: TaskError.self) { try db.setTaskDone(ref, false) }
    }

    @Test func acaoNotesAreDoneThroughResolvedAt() throws {
        let (db, _, _) = try setUp()
        let task = try #require(try db.openTasks().first { $0.source == "note" })
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        try db.setTaskDone(try #require(TaskRef(task.ref)), true, at: now)

        let noteId = try #require(Int64(task.ref.dropFirst("note:".count)))
        #expect(try db.note(id: noteId)?.resolvedAt == now)
        #expect(try db.openTasks().map(\.source) == ["summary"])
        #expect(try db.doneTasks(since: now).map(\.ref) == [task.ref])
        #expect(try db.export(meetingId: task.meetingId)?.timeline.first { $0.noteId == noteId }?.resolvedAt == now)
    }

    @Test func refsRoundTrip() {
        #expect(TaskRef("summary:12:7:9f86d081") == .summary(meetingId: 12, line: 7, fingerprint: "9f86d081"))
        #expect(TaskRef("note:45") == .note(id: 45))
        #expect(TaskRef("note:45")?.description == "note:45")
        #expect(TaskRef("summary:12:7") == nil)
        #expect(TaskRef("45") == nil)
    }

    @Test func parsesTaskCommands() throws {
        #expect(try CLICommand.parse(["tasks"]) == .tasks)
        #expect(try CLICommand.parse(["task", "done", "note:45"]) == .taskDone(.note(id: 45), done: true))
        #expect(try CLICommand.parse(["task", "undo", "summary:1:4:abcd"]) == .taskDone(.summary(meetingId: 1, line: 4, fingerprint: "abcd"), done: false))
        #expect(throws: CLIError.self) { try CLICommand.parse(["task", "done", "45"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["task", "fazer", "note:45"]) }
    }
}
