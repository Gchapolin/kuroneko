import Foundation
import Testing
@testable import KuronekoCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    calendar.firstWeekday = 1
    return calendar
}()

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = calendar.timeZone
    return formatter.date(from: text)!
}

@Suite struct DayGroupingTests {
    @Test func todayYesterdayWeekdaysThenWeeks() {
        let now = date("2026-10-14T15:00:00-03:00")
        let meetings = [
            Meeting(id: 1, startedAt: date("2026-10-01T10:00:00-03:00"), title: "a"),
            Meeting(id: 2, startedAt: date("2026-10-13T09:30:00-03:00"), title: "b"),
            Meeting(id: 3, startedAt: date("2026-10-14T10:45:00-03:00"), title: "c"),
            Meeting(id: 4, startedAt: date("2026-10-09T15:00:00-03:00"), title: "d"),
            Meeting(id: 5, startedAt: date("2026-10-13T16:00:00-03:00"), title: "e"),
            Meeting(id: 6, startedAt: date("2026-10-12T11:00:00-03:00"), title: "f"),
            Meeting(id: 7, startedAt: date("2026-10-11T20:00:00-03:00"), title: "g"),
            Meeting(id: 8, startedAt: date("2026-10-05T08:00:00-03:00"), title: "h"),
        ]

        let groups = DayGrouping.group(meetings, date: \.startedAt, now: now, calendar: calendar)

        #expect(groups.map(\.title) == [
            "Hoje · qua., 14 de out.",
            "Ontem · ter., 13 de out.",
            "Segunda-feira · 12 de out.",
            "Domingo · 11 de out.",
            "Semana passada",
            "27 de set. – 3 de out.",
        ])
        #expect(groups.map { $0.items.map(\.id!) } == [[3], [5, 2], [6], [7], [4, 8], [1]])
        #expect(groups.map(\.isSingleDay) == [true, true, true, true, false, false])
    }

    @Test func yesterdayCanBeInLastWeek() {
        let sunday = date("2026-10-11T09:00:00-03:00")
        let meetings = [
            Meeting(id: 1, startedAt: date("2026-10-10T10:00:00-03:00"), title: "sábado"),
            Meeting(id: 2, startedAt: date("2026-10-09T10:00:00-03:00"), title: "sexta"),
        ]

        let groups = DayGrouping.group(meetings, date: \.startedAt, now: sunday, calendar: calendar)

        #expect(groups.map(\.title) == ["Ontem · sáb., 10 de out.", "Semana passada"])
        #expect(groups.map { $0.items.map(\.id!) } == [[1], [2]])
    }

    @Test func sameMomentKeepsTheGivenOrder() {
        let now = date("2026-10-14T15:00:00-03:00")
        let at = date("2026-10-14T10:00:00-03:00")
        let meetings = [Meeting(id: 1, startedAt: at, title: "a"), Meeting(id: 2, startedAt: at, title: "b")]

        let groups = DayGrouping.group(meetings, date: \.startedAt, now: now, calendar: calendar)

        #expect(groups.first?.items.map(\.id!) == [1, 2])
    }
}

@Suite struct ListTextTests {
    private let now = date("2026-10-14T15:00:00-03:00")

    @Test func cardLineShowsTheDayOnlyWhenTheHeadingDoesNot() {
        let start = date("2026-10-09T15:00:00-03:00")

        #expect(DayText.cardLine(startedAt: start, durationMs: 80 * 60_000, showsDay: false, now: now, calendar: calendar) == "15:00 · 1h20")
        #expect(DayText.cardLine(startedAt: start, durationMs: 80 * 60_000, showsDay: true, now: now, calendar: calendar)
            == "sex., 9 de out. · 15:00 · 1h20")
        #expect(DayText.cardLine(startedAt: start, durationMs: nil, showsDay: false, now: now, calendar: calendar) == "15:00")
    }

    @Test func relativeDays() {
        #expect(DayText.relative(date("2026-10-14T14:00:00-03:00"), now: now, calendar: calendar) == "hoje, 14:00")
        #expect(DayText.relative(date("2026-10-13T10:45:00-03:00"), now: now, calendar: calendar) == "ontem, 10:45")
        #expect(DayText.relative(date("2026-10-09T10:45:00-03:00"), now: now, calendar: calendar) == "sex., 9 de out.")
        #expect(DayText.relative(date("2025-10-09T10:45:00-03:00"), now: now, calendar: calendar) == "qui., 9 de out. de 2025")
    }

    @Test func durations() {
        #expect(DurationText.short(ms: 0) == "1 min")
        #expect(DurationText.short(ms: 32 * 60_000 + 59_000) == "32 min")
        #expect(DurationText.short(ms: 60 * 60_000) == "1h")
        #expect(DurationText.short(ms: 80 * 60_000) == "1h20")
        #expect(DurationText.short(ms: 125 * 60_000) == "2h05")
    }

    @Test func counts() {
        #expect(CountText.of(1, "nota", "notas") == "1 nota")
        #expect(CountText.of(0, "nota", "notas") == "0 notas")
        #expect(CountText.of(3, "decisão", "decisões") == "3 decisões")
    }

    @Test func peopleLine() {
        #expect(PeopleText.line([]) == "")
        #expect(PeopleText.line(["Ana", "Bruno", "Paulo"]) == "Ana, Bruno, Paulo")
        #expect(PeopleText.line(["Ana", "Bruno", "Lucía", "Marta", "Paulo", "Rui"]) == "Ana, Bruno, Lucía, Marta e mais 2")
    }

    @Test func badgesInOrder() {
        var item = MeetingListItem(
            id: 1, title: "Planejamento", week: "Esta semana", startedAt: now, endedAt: nil, durationMs: nil,
            status: "done", tags: [], people: [], noteCount: 2, documents: ["summary"], links: [],
            attachmentCount: 1, openTaskCount: 3, newsAt: nil, unnamedVoiceCount: 2
        )

        #expect(MeetingBadge.badges(for: item) == [
            MeetingBadge(kind: "summary", text: "Resumo"),
            MeetingBadge(kind: "tasks", text: "3 pendências"),
            MeetingBadge(kind: "notes", text: "2 notas · 1 print"),
            MeetingBadge(kind: "voices", text: "2 vozes sem nome"),
        ])

        item.documents = []
        item.openTaskCount = 1
        item.noteCount = 1
        item.attachmentCount = 0
        item.unnamedVoiceCount = 1
        #expect(MeetingBadge.badges(for: item).map(\.text) == ["1 pendência", "1 nota", "1 voz sem nome"])

        item.openTaskCount = 0
        item.noteCount = 0
        item.unnamedVoiceCount = 0
        #expect(MeetingBadge.badges(for: item).isEmpty)
    }

    @Test func newsSubtitle() {
        #expect(NewsText.summaryReady(openTasks: 3, decisions: 2, durationMs: 60 * 60_000) == "3 pendências · 2 decisões · 1h de reunião")
        #expect(NewsText.summaryReady(openTasks: 1, decisions: 0, durationMs: 14 * 60_000) == "1 pendência · 14 min de reunião")
        #expect(NewsText.summaryReady(openTasks: 0, decisions: 1, durationMs: nil) == "1 decisão")
    }
}

@Suite struct MeetingListQueryTests {
    @Test func silentMeetingsAreFinishedWithNothingInThem() throws {
        let db = try AppDatabase.inMemory()
        func finished(_ title: String) throws -> Int64 {
            let id = try db.startMeeting(title: title).id!
            try db.endMeeting(id)
            return id
        }
        let empty = try finished("Entrei sem querer")
        let spoken = try finished("Daily")
        try db.addSegment(meetingId: spoken, tStartMs: 0, tEndMs: 1000, channel: .system, text: "bom dia")
        let noted = try finished("Só nota")
        try db.addNote(meetingId: noted, tMs: 0, text: "lembrar disso")
        let linked = try finished("Só link")
        try db.addLink(meetingId: linked, url: "https://example.com")
        let summarized = try finished("Só resumo")
        try db.setDocument(meetingId: summarized, kind: "summary", body: "nada", source: "manual")
        try db.startMeeting(title: "Gravando")
        let queued = try finished("Na fila")
        try db.setStatus(.recorded, meetingId: queued)

        #expect(try db.silentMeetingIds() == [empty])
    }

    @Test func transcriptReachesTheEndOfTheLastSegment() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.startMeeting(title: "Daily").id!

        #expect(try db.transcribedUntilMs(meetingId: id) == nil)

        try db.addSegment(meetingId: id, tStartMs: 5000, tEndMs: 9000, channel: .system, text: "depois")
        try db.addSegment(meetingId: id, tStartMs: 1000, tEndMs: 4000, channel: .mic, text: "antes")
        #expect(try db.transcribedUntilMs(meetingId: id) == 9000)
    }
}
