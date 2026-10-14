import Foundation
import Testing
@testable import KuronekoCore

@Suite struct TaskListTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    private let summary = """
        ## Pendências
        - [ ] Abrir o card do cache de sessões — Bruno [12:31]
        - [ ] Mandar o relatório do teste de carga — Lucía [31:10]
        - [ ] Revisar o PR do login — Você [44:52]
        - [ ] Atualizar o board — bruno
        - [ ] Ver com alguém
        """

    /// Planning (with a summary) on Friday, then a daily today with a #acao note.
    private func tasks() throws -> (db: AppDatabase, tasks: [TaskItem]) {
        let db = try AppDatabase.inMemory()
        let planning = try db.startMeeting(title: "Planejamento do release", at: Date(timeIntervalSince1970: 1_800_000_000)).id!
        try db.setDocument(meetingId: planning, kind: "summary", body: summary, source: "claude")
        let daily = try db.startMeeting(title: "Daily do time", at: Date(timeIntervalSince1970: 1_800_400_000)).id!
        try db.addNote(meetingId: daily, tMs: 662_000, text: "subir o ambiente de QA hoje #acao")
        return (db, try db.openTasks())
    }

    @Test func filtersByOwner() throws {
        let tasks = try tasks().tasks

        #expect(tasks.filter(TaskFilter.all.matches).count == 6)
        #expect(tasks.filter(TaskFilter.mine.matches).map(\.text) == ["subir o ambiente de QA hoje", "Revisar o PR do login"])
        #expect(tasks.filter(TaskFilter.owner("Bruno").matches).map(\.text) == ["Abrir o card do cache de sessões", "Atualizar o board"])
        #expect(TaskFilter.owners(in: tasks) == ["Bruno", "Lucía"])
    }

    @Test func groupsByMeetingNewestFirst() throws {
        let groups = TaskGroup.byMeeting(try tasks().tasks)

        #expect(groups.map(\.meetingTitle) == ["Daily do time", "Planejamento do release"])
        #expect(groups.map(\.tasks.count) == [1, 5])
    }

    @Test func searchIgnoresCaseAndAccents() throws {
        let tasks = try tasks().tasks

        #expect(tasks.filter { $0.matches("lucia") }.map(\.text) == ["Mandar o relatório do teste de carga"])
        #expect(tasks.filter { $0.matches("relatorio CARGA") }.count == 1)
        #expect(tasks.filter { $0.matches("daily qa") }.map(\.text) == ["subir o ambiente de QA hoje"])
        #expect(tasks.filter { $0.matches("") }.count == 6)
    }

    @Test func ageCountsWholeDaysSinceTheMeeting() throws {
        let task = try tasks().tasks.last!
        let start = task.meetingStartedAt

        #expect(task.openText(now: start.addingTimeInterval(3600), calendar: calendar) == nil)
        #expect(task.openText(now: calendar.date(byAdding: .day, value: 1, to: start)!, calendar: calendar) == "aberta há 1 dia")
        let fiveDays = calendar.date(byAdding: .day, value: 5, to: start)!
        #expect(task.openText(now: fiveDays, calendar: calendar) == "aberta há 5 dias")
        #expect(!task.isLate(now: calendar.date(byAdding: .day, value: 2, to: start)!, calendar: calendar))
        #expect(task.isLate(now: fiveDays, calendar: calendar))
    }

    @Test func doneTasksAreNeverLate() throws {
        let (db, tasks) = try tasks()
        let note = tasks.first { $0.source == "note" }!
        let done = try db.setTaskDone(TaskRef(note.ref)!, true)

        #expect(!done.isLate(now: note.meetingStartedAt.addingTimeInterval(30 * 86400), calendar: calendar))
    }
}
