import KuronekoCore
import SwiftUI

struct MeetingsView: View {
    let state: AppState

    enum Route: Hashable {
        case meeting(Int64, focusMs: Int?)
    }

    @State private var path: [Route] = []
    @State private var query = ""
    @State private var groups: [WeekGrouping.Group] = []
    @State private var titles: [Int64: String] = [:]
    @State private var people: [Int64: [String]] = [:]
    @State private var persons: [Int64: String] = [:]
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.meetings) { meeting in
                                NavigationLink(value: Route.meeting(meeting.id!, focusMs: nil)) {
                                    MeetingRow(meeting: meeting, people: people[meeting.id!] ?? [], state: state)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(hits) { hit in
                        NavigationLink(value: Route.meeting(hit.meetingId, focusMs: hit.tMs)) {
                            SearchHitRow(hit: hit, meetingTitle: titles[hit.meetingId] ?? "", who: who(hit))
                        }
                    }
                }
            }
            .overlay {
                if query.isEmpty, groups.isEmpty {
                    ContentUnavailableView(
                        "Nenhuma reunião ainda",
                        systemImage: "cat",
                        description: Text("Entre numa chamada do Meet no Chrome e o Kuroneko grava sozinho.")
                    )
                } else if !query.isEmpty, hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Buscar em falas e notas")
            .navigationTitle("Reuniões")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .meeting(let id, let focusMs):
                    MeetingDetailView(state: state, meetingId: id, focusMs: focusMs)
                }
            }
        }
        .task(id: state.dataVersion) { reload() }
        .onChange(of: query) { search() }
    }

    private func who(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .note: "Sua nota"
        case .speech(.mic, _, _): "Você"
        case .speech(_, let cluster, let personId):
            personId.flatMap { persons[$0] } ?? "Pessoa \((cluster ?? 0) + 1)"
        }
    }

    private func reload() {
        let meetings = (try? state.db.meetings()) ?? []
        groups = WeekGrouping.group(meetings)
        titles = Dictionary(uniqueKeysWithValues: meetings.compactMap { meeting in meeting.id.map { ($0, meeting.title) } })
        people = (try? state.db.peopleByMeeting()) ?? [:]
        persons = Dictionary(uniqueKeysWithValues: ((try? state.db.persons()) ?? []).compactMap { person in
            person.id.map { ($0, person.name) }
        })
        search()
    }

    private func search() {
        hits = query.isEmpty ? [] : (try? state.db.search(query)) ?? []
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let people: [String]
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(meeting: meeting, state: state)
            }
            Text([Format.day(meeting.startedAt), Format.duration(meeting)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !people.isEmpty {
                Text(people.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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

private struct SearchHitRow: View {
    let hit: SearchHit
    let meetingTitle: String
    let who: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: hit.kind == .note ? "note.text" : "text.bubble")
                    .foregroundStyle(.secondary)
                Text(who).font(.caption.bold())
                Text("·").foregroundStyle(.secondary)
                Text(Format.clock(ms: hit.tMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(hit.text).lineLimit(3)
            Text(meetingTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
