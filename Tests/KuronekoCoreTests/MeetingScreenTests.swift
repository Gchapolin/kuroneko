import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SummaryOverviewTests {
    @Test func readsTheResumoAndOtherSections() {
        let summary = """
            ## Resumo
            O time revisou o escopo do **release 3.4** [00:30].
            O cache fica para o 3.5 [12:04–12:31].

            Lucía mostrou o teste de carga.

            ## Decisões
            - O cache de sessões fica para o 3.5 [12:04]

            ## Pendências
            - [ ] Abrir o card do cache — Bruno [12:31]

            ## Minhas notas
            - cobrar data do QA [10:41]

            ## Pontos em aberto
            - Data do QA ainda indefinida — Marta [10:52]
              - depende do ambiente
            - Nenhum outro.
            """

        let overview = SummaryOverview.parse(summary)

        #expect(overview.intro == [
            "O time revisou o escopo do **release 3.4**. O cache fica para o 3.5.",
            "Lucía mostrou o teste de carga.",
        ])
        #expect(overview.sections.map(\.title) == ["Pontos em aberto"])
        #expect(overview.sections.first?.items.map(\.text) == ["Data do QA ainda indefinida"])
        #expect(overview.sections.first?.items.first?.owner == "Marta")
        #expect(overview.sections.first?.items.first?.startMs == 652_000)
    }

    @Test func textBeforeAnyHeadingIsTheResumo() {
        let summary = """
            # Planejamento do release

            Falamos do release.
            - ponto um [01:00]

            **Pendências:**
            - [ ] Subir o QA

            Riscos
            Nenhum risco novo [02:00]
            """

        let overview = SummaryOverview.parse(summary)

        #expect(overview.intro == ["Falamos do release.", "• ponto um"])
        #expect(overview.sections.isEmpty)
        #expect(SummaryOverview.parse("## Pendências\n- [ ] Subir o QA").isEmpty)
    }

    @Test func otherHeadingsMakeSections() {
        let overview = SummaryOverview.parse("Intro.\n\n### Riscos\n- Atraso do QA [05:00]\n### Vazia\n")

        #expect(overview.intro == ["Intro."])
        #expect(overview.sections == [
            SummaryOverview.Section(title: "Riscos", items: [SummaryItem(kind: "other", text: "Atraso do QA", startMs: 300_000, line: 3)]),
        ])
    }

    @Test func tasksOfOneMeeting() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Planning").id!
        let other = try db.startMeeting(title: "Daily").id!
        try db.setDocument(meetingId: meeting, kind: "summary", body: """
            ## Pendências
            - [ ] Abrir o card — Bruno [12:31]
            - [x] Mandar o relatório [01:00]
            - Sem hora
            """, source: "claude")
        try db.addNote(meetingId: meeting, tMs: 300_000, text: "cobrar o QA #acao")
        try db.addNote(meetingId: meeting, tMs: 400_000, text: "só uma nota")
        try db.addNote(meetingId: other, tMs: 1000, text: "de outra reunião #acao")

        let tasks = try db.tasks(meetingId: meeting)

        #expect(tasks.map(\.text) == ["Mandar o relatório", "cobrar o QA", "Abrir o card", "Sem hora"])
        #expect(tasks.map(\.done) == [true, false, false, false])
        #expect(tasks.map(\.source) == ["summary", "note", "summary", "summary"])
        #expect(try db.tasks(meetingId: 999).isEmpty)
    }
}

@Suite struct TimelineNavigationTests {
    private func segment(_ start: Int, _ end: Int, _ cluster: Int?, _ text: String) -> Segment {
        Segment(meetingId: 1, tStartMs: start, tEndMs: end, channel: cluster == nil ? .mic : .system, diarCluster: cluster, text: text)
    }

    private var entries: [TimelineEntry] {
        Timeline.entries(
            segments: [
                segment(0, 2000, 0, "Ação no cadastro"),
                segment(2500, 4000, 0, "e a migração"),
                segment(5000, 6000, nil, "acao de novo"),
                segment(20000, 22000, 1, "Otra cosa"),
            ],
            notes: [Note(id: 9, meetingId: 1, tMs: 3000, text: "cobrar a ação #acao")]
        )
    }

    @Test func findsIgnoringCaseAndAccents() {
        let text = "Ação, acao e AÇÃO"

        let found = TextFind.ranges(of: " acao ", in: text).map { String(text[$0]) }

        #expect(found == ["Ação", "acao", "AÇÃO"])
        #expect(TextFind.ranges(of: "  ", in: text).isEmpty)
        #expect(TextFind.ranges(of: "xyz", in: text).isEmpty)
    }

    @Test func matchesFollowTheMeeting() {
        let matches = Timeline.matches(of: "ação", in: entries)

        #expect(Timeline.text(of: entries[0]) == "Ação no cadastro e a migração")
        // "migração" holds one too; the note is entry 1, between the blocks.
        #expect(matches == [
            Timeline.Match(entryIndex: 0, occurrence: 0),
            Timeline.Match(entryIndex: 0, occurrence: 1),
            Timeline.Match(entryIndex: 1, occurrence: 0),
            Timeline.Match(entryIndex: 1, occurrence: 1),
            Timeline.Match(entryIndex: 2, occurrence: 0),
        ])
    }

    @Test func speechHeardAtAMoment() {
        // c0 0–4000, note 3000, me 5000–6000, c1 20000–22000
        let entries = entries

        #expect(Timeline.speechIndex(atMs: 0, in: entries) == 0)
        #expect(Timeline.speechIndex(atMs: 3500, in: entries) == 0)
        #expect(Timeline.speechIndex(atMs: 5500, in: entries) == 2)
        #expect(Timeline.speechIndex(atMs: 8500, in: entries) == 2)
        #expect(Timeline.speechIndex(atMs: 12000, in: entries) == nil)
        #expect(Timeline.speechIndex(atMs: 21000, in: entries) == 3)
        #expect(Timeline.speechIndex(atMs: 1000, in: []) == nil)
        let late = Timeline.entries(segments: [segment(5000, 6000, 0, "oi")], notes: [])
        #expect(Timeline.speechIndex(atMs: 1000, in: late) == nil)
    }

    @Test func nextLiveBatch() {
        #expect(LiveProgress.untilNextBatchMs(elapsedMs: 0) == 122_000)
        #expect(LiveProgress.untilNextBatchMs(elapsedMs: 100_000) == 22_000)
        #expect(LiveProgress.untilNextBatchMs(elapsedMs: 122_000) == 120_000)
        #expect(LiveProgress.minutesUntilNextBatch(elapsedMs: 0) == 3)
        #expect(LiveProgress.minutesUntilNextBatch(elapsedMs: 100_000) == 1)
        #expect(LiveProgress.minutesUntilNextBatch(elapsedMs: 150_000) == 2)
        #expect(LiveProgress.transcribedUntilMs([segment(0, 2000, 0, "a"), segment(500, 9000, nil, "b")]) == 9000)
        #expect(LiveProgress.transcribedUntilMs([]) == 0)
    }
}
