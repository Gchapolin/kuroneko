import KuronekoCore
import SwiftUI

/// Every open pendência — summary lines and #acao notes — by meeting, newest
/// first, with the ones checked off this week at the end.
struct TasksView: View {
    let state: AppState
    let open: [TaskItem]
    let done: [TaskItem]
    /// The search of the toolbar.
    let query: String
    let go: (MeetingsView.Route) -> Void

    @State private var filter: TaskFilter = .all
    @State private var showDone = false

    var body: some View {
        let found = open.filter { $0.matches(query) }
        let owners = TaskFilter.owners(in: open)
        // A person whose pendências were all done has no chip left.
        let active: TaskFilter = switch filter {
        case .owner(let name) where !owners.contains(name): .all
        default: filter
        }
        let groups = TaskGroup.byMeeting(found.filter(active.matches))
        let doneFound = done.filter { $0.matches(query) && active.matches($0) }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !open.isEmpty {
                    WrappingLayout {
                        FilterChip(title: "Todas · \(found.count)", selected: active == .all) { filter = .all }
                        FilterChip(title: "Minhas · \(found.count(where: TaskFilter.mine.matches))", selected: active == .mine) {
                            filter = .mine
                        }
                        ForEach(owners, id: \.self) { owner in
                            FilterChip(title: owner, selected: active == .owner(owner)) { filter = .owner(owner) }
                        }
                    }
                }
                ForEach(groups) { group in
                    TaskGroupCard(group: group, state: state, go: go)
                }
                if groups.isEmpty, !open.isEmpty || !doneFound.isEmpty {
                    Text(query.isEmpty ? "Nenhuma pendência aberta." : "Nenhuma pendência aberta com “\(query)”.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                if !doneFound.isEmpty {
                    doneSection(doneFound)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(ListPalette.background)
        .overlay {
            if open.isEmpty, doneFound.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Nenhuma pendência aberta",
                        systemImage: "checkmark.circle",
                        description: Text("As pendências dos resumos e as notas com #acao aparecem aqui.")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func doneSection(_ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showDone.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showDone ? 90 : 0))
                    Text("Feitas nesta semana · \(tasks.count)")
                }
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .accessibilityValue(showDone ? "aberto" : "fechado")

            if showDone {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { ListPalette.rule.frame(height: 1) }
                        TaskRow(task: task, showsMeeting: true, state: state, go: go)
                    }
                }
                .card()
            }
        }
    }
}

/// The pendências of one meeting under its title.
private struct TaskGroupCard: View {
    let group: TaskGroup
    let state: AppState
    let go: (MeetingsView.Route) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                go(.meeting(group.meetingId, focusMs: nil, play: false))
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.meetingTitle)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DayText.relative(group.meetingStartedAt))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text("Abrir")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir \(group.meetingTitle)")

            ForEach(group.tasks) { task in
                ListPalette.rule.frame(height: 1)
                TaskRow(task: task, showsMeeting: false, state: state, go: go)
            }
        }
        .card()
    }
}

/// Checkbox, text, who and how long it is open, and the moment it was said.
private struct TaskRow: View {
    let task: TaskItem
    /// Outside its meeting's card (the ones done this week).
    let showsMeeting: Bool
    let state: AppState
    let go: (MeetingsView.Route) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: Binding(get: { task.done }, set: { setDone($0) })) {
                Text(task.text)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(task.done ? "Reabrir" : "Marcar como feita")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.text)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(task.isLate() ? ListPalette.late : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let startMs = task.startMs {
                Button {
                    go(.meeting(task.meetingId, focusMs: startMs, play: true))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text(Format.clock(ms: startMs)).monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ouvir esse momento")
                .accessibilityLabel("Ouvir esse momento, \(Format.clock(ms: startMs))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// "Bruno", "sua nota #acao", "Ana · aberta há 5 dias"; done ones say
    /// which meeting they came from.
    private var detail: String? {
        var parts: [String] = []
        if showsMeeting { parts.append(task.meetingTitle) }
        if task.source == "note" {
            parts.append("sua nota #\(TaskItem.noteTag)")
        } else if let owner = task.owner {
            parts.append(owner)
        }
        if !task.done, let open = task.openText() { parts.append(open) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func setDone(_ done: Bool) {
        guard let ref = TaskRef(task.ref) else { return }
        state.setTaskDone(ref, done)
    }
}

/// "Todas · 6", "Minhas · 2", "Ana": which pendências to show.
private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(selected ? ListPalette.card : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(selected ? Color.primary : ListPalette.card, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? Color.primary : ListPalette.cardBorder) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
