import Foundation

/// Which pendências the list shows: every one, the user's ("você"), or one
/// person's.
public enum TaskFilter: Hashable, Sendable {
    case all
    case mine
    case owner(String)

    public func matches(_ task: TaskItem) -> Bool {
        switch self {
        case .all: true
        case .mine: task.isMine
        case .owner(let name): !task.isMine && task.owner.map { TaskItem.sameName($0, name) } == true
        }
    }

    /// The other people with pendências, each once, in alphabetical order.
    public static func owners(in tasks: [TaskItem]) -> [String] {
        var owners: [String] = []
        for task in tasks where !task.isMine {
            guard let owner = task.owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty,
                  !owners.contains(where: { TaskItem.sameName($0, owner) }) else { continue }
            owners.append(owner)
        }
        return owners.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Pendências of one meeting, as the list shows them.
public struct TaskGroup: Equatable, Sendable, Identifiable {
    public var meetingId: Int64
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var tasks: [TaskItem]

    public var id: Int64 { meetingId }

    /// In the order the tasks come (`openTasks` puts the newest meeting first).
    public static func byMeeting(_ tasks: [TaskItem]) -> [TaskGroup] {
        var groups: [TaskGroup] = []
        var index: [Int64: Int] = [:]
        for task in tasks {
            if let at = index[task.meetingId] {
                groups[at].tasks.append(task)
            } else {
                index[task.meetingId] = groups.count
                groups.append(TaskGroup(
                    meetingId: task.meetingId,
                    meetingTitle: task.meetingTitle,
                    meetingStartedAt: task.meetingStartedAt,
                    tasks: [task]
                ))
            }
        }
        return groups
    }
}

extension TaskItem {
    /// From this many days open, a pendência is shown as late.
    public static let lateAfterDays = 3

    /// The user's own: a #acao note, or a summary line for "você".
    public var isMine: Bool {
        owner.map { Self.sameName($0, "você") } ?? false
    }

    /// Whole days since the meeting it came from.
    public func openDays(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: meetingStartedAt), to = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    /// "aberta há 5 dias"; nil on the day of the meeting.
    public func openText(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let days = openDays(now: now, calendar: calendar)
        return days > 0 ? "aberta há \(CountText.of(days, "dia", "dias"))" : nil
    }

    public func isLate(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        !done && openDays(now: now, calendar: calendar) >= Self.lateAfterDays
    }

    /// Every word of the query in the text, the owner or the meeting title,
    /// ignoring case and accents.
    public func matches(_ query: String) -> Bool {
        let haystack = [text, owner ?? "", meetingTitle].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedStandardContains($0) }
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces)
            .compare(rhs.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
