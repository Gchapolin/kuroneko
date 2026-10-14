import Foundation

/// The meetings list by day: today, yesterday and the other days of this
/// week by name, then whole weeks ("Semana passada", "28 de set. – 4 de out.").
public enum DayGrouping {
    public struct Group<Item> {
        public var title: String
        /// False for a whole week: each item then shows its own day.
        public var isSingleDay: Bool
        public var items: [Item]
    }

    private enum Key: Equatable {
        case day(Date)
        case week(Date)

        var isDay: Bool {
            if case .day = self { true } else { false }
        }
    }

    /// Newest first; items on the same moment keep their order.
    public static func group<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group<Item>] {
        let sorted = items.enumerated()
            .sorted { lhs, rhs in
                let left = date(lhs.element), right = date(rhs.element)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        var groups: [Group<Item>] = []
        var currentKey: Key?
        for item in sorted {
            let (key, title) = bucket(for: date(item), now: now, calendar: calendar)
            if key != currentKey {
                groups.append(Group(title: title, isSingleDay: key.isDay, items: []))
                currentKey = key
            }
            groups[groups.count - 1].items.append(item)
        }
        return groups
    }

    private static func bucket(for date: Date, now: Date, calendar: Calendar) -> (Key, String) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let dayText = DayText.formatter("EEEdMMM", calendar).string(from: date)
        if day == today { return (.day(day), "Hoje · \(dayText)") }
        if day == yesterday { return (.day(day), "Ontem · \(dayText)") }
        if day >= thisWeek, day < today {
            let weekday = DayText.formatter("EEEE", calendar).string(from: date)
            return (.day(day), "\(weekday.capitalizedFirst) · \(DayText.formatter("dMMM", calendar).string(from: date))")
        }
        let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? day
        return (.week(week), WeekGrouping.title(forWeekStarting: week, now: now, calendar: calendar))
    }
}

extension DayGrouping.Group: Equatable where Item: Equatable {}
extension DayGrouping.Group: Sendable where Item: Sendable {}

/// Dates and times as the lists write them, always in Portuguese.
public enum DayText {
    /// "10:45 · 1h" inside a day; "sex., 9 de out. · 15:00 · 1h20" when the
    /// day is not in the heading. No duration while still recording.
    public static func cardLine(
        startedAt: Date,
        durationMs: Int?,
        showsDay: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var parts: [String] = []
        if showsDay { parts.append(day(startedAt, now: now, calendar: calendar)) }
        parts.append(time(startedAt, calendar: calendar))
        if let durationMs { parts.append(DurationText.short(ms: durationMs)) }
        return parts.joined(separator: " · ")
    }

    /// "hoje, 14:00", "ontem, 10:45", or the day: "sex., 9 de out.".
    public static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day == today { return "hoje, \(time(date, calendar: calendar))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "ontem, \(time(date, calendar: calendar))"
        }
        return self.day(date, now: now, calendar: calendar)
    }

    /// "qua., 14 de out.", with the year when it is not this year.
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(sameYear ? "EEEdMMM" : "EEEdMMMy", calendar).string(from: date)
    }

    /// "14:05".
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HHmm", calendar).string(from: date)
    }

    static func formatter(_ template: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

public enum DurationText {
    /// "32 min", "1h", "1h20"; never less than a minute.
    public static func short(ms: Int) -> String {
        let minutes = max(1, ms / 60_000)
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(String(format: "%02d", rest))"
    }
}

public enum CountText {
    /// "1 nota", "3 notas".
    public static func of(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
