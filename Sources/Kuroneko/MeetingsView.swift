import KuronekoCore
import os
import SwiftUI

/// The meetings window: meetings as cards by day, or every open pendência,
/// with the search of each in the toolbar.
struct MeetingsView: View {
    let state: AppState

    enum Tab: Hashable {
        case meetings
        case tasks
    }

    enum Route: Hashable {
        /// `play` starts the audio at `focusMs` as the meeting opens.
        case meeting(Int64, focusMs: Int?, play: Bool)
    }

    @State private var path: [Route] = []
    @State private var tab: Tab = .meetings
    @State private var query = ""
    @State private var data = ListData()
    @State private var groups: [DayGrouping.Group<MeetingListItem>] = []
    @State private var hits: [SearchHit] = []
    @State private var showSilent = false
    @State private var edit: CardEdit?
    private let navigator = Navigator.shared
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MeetingsView")

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch tab {
                case .meetings:
                    meetingsList
                case .tasks:
                    TasksView(state: state, open: data.openTasks, done: data.doneTasks, query: query) { path.append($0) }
                }
            }
            .navigationTitle("Reuniões")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("Ver", selection: $tab) {
                        Text("Reuniões").tag(Tab.meetings)
                        Text(data.openTasks.isEmpty ? "Pendências" : "Pendências · \(data.openTasks.count)").tag(Tab.tasks)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .searchable(
                text: $query,
                placement: .toolbar,
                prompt: Text(tab == .meetings ? "Buscar em falas e notas" : "Buscar pendências")
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .meeting(let id, let focusMs, let play):
                    MeetingDetailView(state: state, meetingId: id, focusMs: focusMs, playOnOpen: play)
                }
            }
        }
        // The tabs take the title's place; a meeting shows its own title.
        .toolbar(removing: path.isEmpty ? .title : nil)
        .task(id: state.dataVersion) { reload() }
        .onChange(of: query) { search() }
        .onChange(of: tab) { search() }
        .onChange(of: showSilent) { regroup() }
        .onAppear { follow(navigator.take()) }
        .onChange(of: navigator.request) { follow(navigator.take()) }
    }

    // MARK: - Reuniões

    private var meetingsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if query.isEmpty {
                    if let active = state.activeMeeting, let id = active.id {
                        RecordingBanner(meeting: active, transcribedUntilMs: data.transcribedUntilMs) { open(id) }
                    }
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.items, id: \.id) { item in
                                MeetingCard(
                                    item: item,
                                    meeting: data.meetings[item.id],
                                    showsDay: !group.isSingleDay,
                                    isSilent: data.silent.contains(item.id),
                                    state: state,
                                    edit: $edit
                                ) { open(item.id) }
                            }
                        } header: {
                            Text(group.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                                .padding(.horizontal, 4)
                        }
                    }
                    if hiddenCount > 0 {
                        silentFooter
                    }
                } else {
                    ForEach(hits) { hit in
                        SearchHitCard(hit: hit, meetingTitle: data.meetings[hit.meetingId]?.title ?? "", who: who(hit)) {
                            path.append(.meeting(hit.meetingId, focusMs: hit.tMs, play: false))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(ListPalette.background)
        .overlay {
            if !query.isEmpty, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if query.isEmpty, data.items.isEmpty, state.activeMeeting == nil {
                ContentUnavailableView(
                    "Nenhuma reunião ainda",
                    systemImage: "cat",
                    description: Text("Entre numa chamada do Meet no Chrome e o Kuroneko grava sozinho.")
                )
            }
        }
    }

    private var silentFooter: some View {
        HStack(spacing: 4) {
            if showSilent {
                Button("Esconder as gravações sem fala") { showSilent = false }
                    .buttonStyle(.link)
            } else {
                Text(CountText.of(hiddenCount, "gravação sem fala escondida", "gravações sem fala escondidas"))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Button("Mostrar") { showSilent = true }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// Finished meetings with nothing in them, apart from the one recording.
    private var hiddenCount: Int {
        data.items.count(where: { data.silent.contains($0.id) && $0.id != state.activeMeeting?.id })
    }

    // MARK: - Navigation

    private func open(_ meetingId: Int64) {
        edit = nil
        path.append(.meeting(meetingId, focusMs: nil, play: false))
    }

    /// A request from outside the window, such as the menu.
    private func follow(_ request: Navigator.Request?) {
        switch request {
        case .meeting(let id):
            tab = .meetings
            path = [.meeting(id, focusMs: nil, play: false)]
        case .tasks:
            path = []
            tab = .tasks
        case nil:
            break
        }
    }

    // MARK: - Data

    private func reload() {
        let db = state.db
        do {
            var data = ListData()
            data.items = try db.meetingList()
            data.meetings = Dictionary(uniqueKeysWithValues: try db.meetings().compactMap { meeting in meeting.id.map { ($0, meeting) } })
            data.silent = try db.silentMeetingIds()
            data.persons = Dictionary(uniqueKeysWithValues: try db.persons().compactMap { person in person.id.map { ($0, person.name) } })
            data.openTasks = try db.openTasks()
            let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
            data.doneTasks = try db.doneTasks(since: weekStart)
            if let id = state.activeMeeting?.id {
                data.transcribedUntilMs = try db.transcribedUntilMs(meetingId: id)
            }
            self.data = data
        } catch {
            logger.error("Falha ao carregar as reuniões: \(String(describing: error))")
        }
        regroup()
        search()
    }

    private func regroup() {
        let activeId = state.activeMeeting?.id
        let visible = data.items.filter { item in
            item.id != activeId && (showSilent || !data.silent.contains(item.id))
        }
        groups = DayGrouping.group(visible, date: \.startedAt)
    }

    private func search() {
        guard !query.isEmpty, tab == .meetings else {
            hits = []
            return
        }
        do {
            hits = try state.db.search(query)
        } catch {
            logger.error("Falha na busca: \(String(describing: error))")
            hits = []
        }
    }

    private func who(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .note: "Sua nota"
        case .speech(.mic, _, _): "Você"
        case .speech(_, let cluster, let personId):
            personId.flatMap { data.persons[$0] } ?? SpeakerLabel.label(cluster: cluster ?? 0)
        }
    }
}

/// What the window shows, read again whenever stored data changes.
private struct ListData {
    var items: [MeetingListItem] = []
    var meetings: [Int64: Meeting] = [:]
    var silent: Set<Int64> = []
    var persons: [Int64: String] = [:]
    var openTasks: [TaskItem] = []
    var doneTasks: [TaskItem] = []
    /// Of the meeting being recorded.
    var transcribedUntilMs: Int?
}

/// The call being recorded, above everything else.
private struct RecordingBanner: View {
    let meeting: Meeting
    let transcribedUntilMs: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Circle()
                    .fill(ListPalette.recordingDot)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(status(at: context.date))
                            .font(.callout)
                            .foregroundStyle(ListPalette.recording.foreground)
                    }
                }
                Spacer(minLength: 8)
                Text("Abrir")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ListPalette.recordingAccent)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ListPalette.recording.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(ListPalette.recording.border ?? .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gravando \(meeting.title). Abrir")
    }

    /// "Gravando desde 14:00 · 12 min · texto até 10:10".
    private func status(at now: Date) -> String {
        let elapsedMs = Int(now.timeIntervalSince(meeting.startedAt) * 1000)
        let text = transcribedUntilMs.map { "texto até \(Format.clock(ms: $0))" } ?? "sem texto ainda"
        return "Gravando desde \(DayText.time(meeting.startedAt)) · \(DurationText.short(ms: elapsedMs)) · \(text)"
    }
}

/// Something said or noted that matches the search; opens the meeting there.
private struct SearchHitCard: View {
    let hit: SearchHit
    let meetingTitle: String
    let who: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: hit.kind == .note ? "note.text" : "text.bubble")
                        .foregroundStyle(.secondary)
                    Text(who).font(.callout.bold())
                    Text("·").foregroundStyle(.secondary)
                    Text(Format.clock(ms: hit.tMs))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(hit.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meetingTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .card()
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    let meeting: Meeting
    let state: AppState

    var body: some View {
        switch meeting.status {
        case .recording:
            Label("Gravando", systemImage: "record.circle.fill").foregroundStyle(.red).font(.caption)
        case .recorded:
            Text("Na fila").font(.caption).foregroundStyle(.secondary)
        case .processing:
            if let current = state.processing.current, current.meetingId == meeting.id {
                Text("Transcrevendo \(Int(current.progress * 100))%").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Na fila").font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Label("Falhou", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        case .done:
            EmptyView()
        }
    }
}
