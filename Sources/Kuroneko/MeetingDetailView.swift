import KuronekoCore
import SwiftUI

/// One meeting: what was decided and is left to do at the top, the
/// transcript below in the same scroll, and the player and the note field
/// fixed at the bottom. During the call it shows the transcript arriving in
/// batches and takes notes at the current moment.
struct MeetingDetailView: View {
    let state: AppState
    let meetingId: Int64
    let focusMs: Int?
    let playOnOpen: Bool

    init(state: AppState, meetingId: Int64, focusMs: Int?, playOnOpen: Bool = false) {
        self.state = state
        self.meetingId = meetingId
        self.focusMs = focusMs
        self.playOnOpen = playOnOpen
    }

    @State private var data: MeetingScreenData?
    @State private var loaded = false
    @State private var player = MeetingPlayer()
    @State private var naming: NamingTarget?
    @FocusState private var focus: MeetingField?
    @State private var keys = MeetingKeyMonitor()

    /// The block being heard, and whether the transcript keeps it in view.
    @State private var playingId: String?
    @State private var following = true
    @State private var scrollRequest: ScrollRequest?

    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var matches: [Timeline.Match] = []
    @State private var matchIndex = 0

    @State private var confirmingDelete = false
    @State private var didFocusOnOpen = false
    @Environment(\.dismiss) private var dismiss

    /// The block being heard sits a little above the middle.
    private static let followAnchor = UnitPoint(x: 0.5, y: 0.35)

    var body: some View {
        Group {
            if let data {
                screen(data)
            } else if loaded {
                ContentUnavailableView("Reunião não encontrada", systemImage: "questionmark.circle")
            } else {
                Color.clear
            }
        }
        .background(MeetingStyle.content)
        .background(WindowReader { keys.window = $0 })
        // A fixed title: switching it as the page scrolled changed the
        // toolbar, which moved the scroll, which switched it back — the
        // window froze at 100% CPU.
        .navigationTitle(data?.meeting.title ?? "Reuniões")
        .toolbar { toolbar }
        .task(id: state.dataVersion) { reload() }
        .onAppear {
            keys.handle = { key, typing in handle(key, typing: typing) }
            keys.start()
            state.markNewsSeen(meetingId)
            // Back on screen after leaving it, which let go of the audio.
            if let data, !data.isRecording, !player.hasAudio {
                player.load(data.meeting)
            }
        }
        .onDisappear {
            player.stop()
            keys.stop()
        }
        .onChange(of: playingId) { _, id in
            guard following, let id else { return }
            scrollRequest = ScrollRequest(id: id, anchor: Self.followAnchor)
        }
        .confirmationDialog("Apagar esta reunião?", isPresented: $confirmingDelete) {
            Button("Apagar reunião e áudio", role: .destructive) {
                player.stop()
                state.deleteMeeting(meetingId)
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A transcrição, as notas, os prints e o áudio somem do Mac. Não dá para desfazer.")
        }
    }

    // MARK: - Layout

    private func screen(_ data: MeetingScreenData) -> some View {
        VStack(spacing: 0) {
            if findOpen {
                findBar(data)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        MeetingHeaderView(state: state, data: data, naming: naming(data), focus: $focus)
                            .padding(.horizontal, 24)
                            .padding(.top, 18)
                            .padding(.bottom, 18)
                        MeetingOverviewView(state: state, data: data, canPlay: canPlay(data), onPlay: play)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 18)
                        Section {
                            transcript(data)
                        } header: {
                            transcriptHeader(data)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .onScrollPhaseChange { _, phase in
                    // Scrolling away while listening stops following the audio.
                    if phase == .interacting || phase == .tracking, player.isPlaying {
                        following = false
                    }
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(request.id, anchor: request.anchor)
                    }
                }
                .overlay(alignment: .bottom) {
                    if player.isPlaying, !following, playingId != nil {
                        Button {
                            resumeFollowing()
                        } label: {
                            Label("Acompanhar o áudio", systemImage: "waveform")
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                        .padding(.bottom, 10)
                    }
                }
            }
            Divider()
            MeetingBottomBar(
                state: state,
                meeting: data.meeting,
                player: player,
                marks: data.noteMarks,
                focus: $focus,
                onUserPlay: { following = true }
            )
        }
        .background(
            PlayheadWatcher(player: player, entries: data.entries) { playingId = $0 }
        )
    }

    private func transcriptHeader(_ data: MeetingScreenData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            MeetingStyle.sectionTitle("Transcrição")
            Spacer(minLength: 8)
            if data.isRecording {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let minutes = LiveProgress.minutesUntilNextBatch(elapsedMs: data.meeting.audioOffsetMs(at: context.date))
                    Text(data.transcribedUntilMs > 0
                        ? "pronta até \(Format.clock(ms: data.transcribedUntilMs)) · próximo trecho em ~\(minutes) min"
                        : "primeiro trecho em ~\(minutes) min")
                }
            } else if player.isPlaying, following, playingId != nil {
                Text("acompanhando o áudio")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeetingStyle.content)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func transcript(_ data: MeetingScreenData) -> some View {
        // During the call, notes past the transcribed part wait below it.
        let entries = data.isRecording
            ? data.entries.filter { entry in
                if case .note = entry { return entry.startMs <= data.transcribedUntilMs }
                return true
            }
            : data.entries
        let current = currentMatch(data)
        if entries.isEmpty, !data.isRecording {
            Text(emptyText(data.meeting))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
        }
        ForEach(entries) { entry in
            row(entry, data, current: current)
                .padding(.horizontal, 14)
                .padding(.vertical, entry.isNote ? 6 : 2)
                .id(entry.id)
        }
        if data.isRecording {
            LivePlaceholder(
                fromMs: data.transcribedUntilMs,
                notes: data.notes.filter { $0.tMs > data.transcribedUntilMs },
                attachments: data.attachments(of:),
                meta: { noteMeta($0, data.meeting) },
                onDelete: delete
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func row(_ entry: TimelineEntry, _ data: MeetingScreenData, current: (id: String, occurrence: Int)?) -> some View {
        let find = findOpen && !findQuery.isEmpty
            ? FindHighlight(query: findQuery, current: current?.id == entry.id ? current?.occurrence : nil)
            : nil
        switch entry {
        case .speech(let block):
            SpeechRow(
                block: block,
                isCurrent: entry.id == playingId,
                isPlaying: player.isPlaying,
                canPlay: canPlay(data),
                find: find,
                onPlay: { play(block.startMs) }
            ) {
                speakerLabel(block, anchor: entry.id, data)
            }
        case .note(let note, let attachments):
            NoteRow(note: note, attachments: attachments, meta: noteMeta(note, data.meeting), find: find) {
                delete(note)
            }
        }
    }

    /// The speaker's name on a block; for a voice of the call it is also the
    /// quickest way to say who that voice is.
    @ViewBuilder
    private func speakerLabel(_ block: SpeechBlock, anchor: String, _ data: MeetingScreenData) -> some View {
        let label = Text(data.name(of: block))
            .fontWeight(.bold)
            .foregroundStyle(SpeakerStyle.color(for: block.speakerKey))
        if block.speakerKey != "me", let cluster = block.segments.first?.diarCluster {
            let naming = naming(data)
            Button {
                naming.open(cluster: cluster, anchor: anchor)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(data.personName(cluster: cluster) == nil ? "Dizer quem é essa voz" : "Corrigir o nome dessa voz")
            .popover(isPresented: naming.isPresented(anchor)) {
                naming.popover(cluster: cluster)
            }
        } else {
            label
        }
    }

    // MARK: - Find

    private func findBar(_ data: MeetingScreenData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar nesta reunião", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($focus, equals: .find)
                .onAppear { focus = .find }
                .onSubmit { moveMatch(by: 1) }
                .onChange(of: findQuery) { updateMatches(data, reset: true) }
            if !findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(matches.isEmpty ? "nada encontrado" : "\(matchIndex + 1) de \(matches.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button {
                moveMatch(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(matches.isEmpty)
            .help("Anterior (⇧⌘G)")
            .accessibilityLabel("Anterior")
            Button {
                moveMatch(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(matches.isEmpty)
            .help("Próximo (⌘G)")
            .accessibilityLabel("Próximo")
            Button("Fechar", action: closeFind)
                .help("Fechar a busca (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MeetingStyle.bar)
    }

    /// The field takes the keyboard as it appears, or right away when the
    /// bar is already open.
    private func openFind() {
        if findOpen {
            focus = .find
        } else {
            findOpen = true
        }
    }

    private func closeFind() {
        findOpen = false
        findQuery = ""
        matches = []
        matchIndex = 0
        if focus == .find { focus = nil }
    }

    private func updateMatches(_ data: MeetingScreenData, reset: Bool) {
        matches = Timeline.matches(of: findQuery, in: data.entries)
        matchIndex = reset ? 0 : min(matchIndex, max(0, matches.count - 1))
        if reset { scrollToMatch(data) }
    }

    private func moveMatch(by step: Int) {
        guard !matches.isEmpty, let data else { return }
        matchIndex = (matchIndex + step + matches.count) % matches.count
        scrollToMatch(data)
    }

    private func scrollToMatch(_ data: MeetingScreenData) {
        guard matches.indices.contains(matchIndex) else { return }
        let index = matches[matchIndex].entryIndex
        guard data.entries.indices.contains(index) else { return }
        following = false
        scrollRequest = ScrollRequest(id: data.entries[index].id, anchor: .center)
    }

    private func currentMatch(_ data: MeetingScreenData) -> (id: String, occurrence: Int)? {
        guard findOpen, matches.indices.contains(matchIndex) else { return nil }
        let match = matches[matchIndex]
        guard data.entries.indices.contains(match.entryIndex) else { return nil }
        return (data.entries[match.entryIndex].id, match.occurrence)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let data, data.isRecording, state.activeMeeting?.id == meetingId {
            ToolbarItem {
                Button {
                    state.endActiveMeeting()
                } label: {
                    Text("Encerrar").foregroundStyle(MeetingStyle.recording)
                }
                .help("Encerrar a gravação desta reunião")
            }
        } else if let data {
            ToolbarItem {
                Button(action: openFind) {
                    Label("Buscar nesta reunião", systemImage: "magnifyingglass")
                }
                .help("Buscar nesta reunião (⌘F)")
            }
            ToolbarItem {
                Menu {
                    Button("Transcrever de novo") { state.retranscribe(meetingId) }
                        .disabled(data.isRecording || (data.meeting.audioSystemPath == nil && data.meeting.audioMicPath == nil))
                    Divider()
                    Button("Apagar reunião e áudio…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Label("Mais", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Keyboard

    private func handle(_ key: MeetingKey, typing: Bool) -> Bool {
        guard let data else { return false }
        switch key {
        case .togglePlay:
            guard canPlay(data) else { return false }
            if !player.isPlaying { following = true }
            player.toggle()
            return true
        case .skip(let ms):
            guard canPlay(data) else { return false }
            player.skip(by: ms)
            return true
        case .focusNote:
            focus = .note
            return true
        case .find:
            openFind()
            return true
        case .findNext:
            guard findOpen else { return false }
            moveMatch(by: 1)
            return true
        case .findPrevious:
            guard findOpen, !typing || focus == .find else { return false }
            moveMatch(by: -1)
            return true
        case .escape:
            switch focus {
            case .find:
                closeFind()
                return true
            case .note:
                focus = nil
                return true
            case .title, .link:
                // The field puts back what it had.
                return false
            case nil:
                guard findOpen else { return false }
                closeFind()
                return true
            }
        }
    }

    // MARK: - Actions

    private func canPlay(_ data: MeetingScreenData) -> Bool {
        player.hasAudio && !data.isRecording
    }

    private func play(_ ms: Int) {
        following = true
        player.play(fromMs: ms)
    }

    private func resumeFollowing() {
        following = true
        if let playingId {
            scrollRequest = ScrollRequest(id: playingId, anchor: Self.followAnchor)
        }
    }

    private func delete(_ note: Note) {
        if let id = note.id { state.deleteNote(id) }
    }

    private func naming(_ data: MeetingScreenData) -> VoiceNaming {
        VoiceNaming(state: state, meetingId: meetingId, data: data, canPlay: canPlay(data), target: $naming) { cluster in
            // A sample of the voice, without moving the transcript.
            guard let sample = data.samples[cluster] else { return }
            following = false
            player.play(fromMs: sample.startMs, stopAfterMs: sample.durationMs)
        }
    }

    /// "Sua nota às 14:32 · 03:21": the clock time to remember it by, the
    /// recording time to find it in the transcript.
    private func noteMeta(_ note: Note, _ meeting: Meeting) -> String {
        "Sua nota às \(Format.time(meeting.date(atOffsetMs: note.tMs))) · \(Format.clock(ms: note.tMs))"
    }

    private func emptyText(_ meeting: Meeting) -> String {
        switch meeting.status {
        case .recording: "A transcrição aparece aqui aos poucos, uns 2 minutos atrás da conversa."
        case .recorded, .processing: "Transcrição em andamento."
        case .failed: "Sem transcrição."
        case .done: "Ninguém falou nesta gravação."
        }
    }

    // MARK: - Loading

    private func reload() {
        let new = MeetingScreenData.load(db: state.db, meetingId: meetingId)
        loaded = true
        guard let new else {
            data = nil
            return
        }
        let old = data?.meeting
        if old == nil
            || old?.audioMicPath != new.meeting.audioMicPath
            || old?.audioSystemPath != new.meeting.audioSystemPath
            || (old?.status == .recording) != new.isRecording {
            // The audio of a call still being recorded is not played.
            if new.isRecording {
                player.stop()
            } else {
                player.load(new.meeting)
            }
        }
        data = new
        if new.meeting.newsAt != nil {
            state.markNewsSeen(meetingId)
        }
        if findOpen {
            updateMatches(new, reset: false)
        }
        if !didFocusOnOpen {
            didFocusOnOpen = true
            focusOnOpen(new)
        }
    }

    /// Opened from a search hit or a pendência: that moment in view, and
    /// playing when asked.
    private func focusOnOpen(_ data: MeetingScreenData) {
        if playOnOpen, canPlay(data) {
            play(focusMs ?? 0)
        }
        guard let focusMs, let target = data.entries.last(where: { $0.startMs <= focusMs }) ?? data.entries.first else { return }
        Task { @MainActor in
            // Once the transcript is laid out.
            try? await Task.sleep(for: .milliseconds(150))
            scrollRequest = ScrollRequest(id: target.id, anchor: Self.followAnchor)
        }
    }
}

private struct ScrollRequest: Equatable {
    var id: String
    var anchor: UnitPoint
    /// The same block can be asked for twice in a row.
    var token = UUID()
}

/// Watches the player many times a second without redrawing the screen:
/// only a change of the block being heard reaches it.
private struct PlayheadWatcher: View {
    let player: MeetingPlayer
    let entries: [TimelineEntry]
    let onChange: (String?) -> Void

    var body: some View {
        let id = player.hasPosition
            ? Timeline.speechIndex(atMs: player.positionMs, in: entries).map { entries[$0].id }
            : nil
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: id, initial: true) { _, new in onChange(new) }
    }
}

private extension TimelineEntry {
    var isNote: Bool {
        if case .note = self { return true }
        return false
    }
}
