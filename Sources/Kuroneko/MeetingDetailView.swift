import KuronekoCore
import SwiftUI

private struct NamingTarget: Equatable {
    var cluster: Int
    /// Which control opened it: the voice row or one transcript block.
    var anchor: String
}

struct MeetingDetailView: View {
    let state: AppState
    let meetingId: Int64
    let focusMs: Int?
    var playOnOpen = false

    @State private var meeting: Meeting?
    @State private var entries: [TimelineEntry] = []
    @State private var speakers: [MeetingSpeaker] = []
    @State private var persons: [Int64: String] = [:]
    @State private var candidates: [Int: [PendingVoice.Candidate]] = [:]
    @State private var samples: [Int: VoiceSample] = [:]
    @State private var hasMicSpeech = false
    @State private var title = ""
    @State private var newNote = ""
    /// When the user started typing the note during a recording.
    @State private var noteStartedAt: Date?
    @State private var noteContexts: [Int64: NoteContext] = [:]
    @State private var documents: [MeetingDocument] = []
    @State private var naming: NamingTarget?
    @State private var player = MeetingPlayer()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let meeting {
                    header(meeting)
                    ForEach(documents, id: \.kind) { document in
                        let title = document.kind == "summary" ? "Resumo" : document.kind.capitalized
                        Section(title) {
                            DocumentText(markdown: document.body, title: title)
                            Text([document.source == "claude" ? "Gerado pelo Claude" : "Editado", Format.day(document.updatedAt)].joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !speakers.isEmpty || hasMicSpeech {
                        Section("Vozes") {
                            if hasMicSpeech {
                                SpeakerRow(name: "Você", color: SpeakerStyle.color(for: "me"), detail: "seu microfone")
                            }
                            ForEach(speakers, id: \.diarCluster) { speaker in
                                speakerRow(speaker)
                            }
                        }
                    }
                    Section("Transcrição") {
                        if entries.isEmpty {
                            Text(emptyText(meeting)).foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    Section("Nova nota") {
                        HStack(alignment: .firstTextBaseline) {
                            TextField(noteFieldLabel(meeting), text: $newNote, axis: .vertical)
                                .onSubmit(addNote)
                                .onChange(of: newNote) { old, new in
                                    if old.isEmpty, !new.isEmpty { noteStartedAt = Date() }
                                }
                            Button("Salvar", action: addNote).disabled(newNote.isEmpty)
                        }
                    }
                }
            }
            .onChange(of: entries) {
                guard let focusMs, let target = entries.last(where: { $0.startMs <= focusMs }) ?? entries.first else { return }
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
        .navigationTitle(meeting?.title ?? "")
        .toolbar {
            if player.hasAudio {
                ToolbarItem {
                    Button {
                        player.toggle()
                    } label: {
                        Label(player.isPlaying ? "Pausar" : "Ouvir", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
            }
            ToolbarItem {
                Menu {
                    Button("Transcrever de novo") { state.retranscribe(meetingId) }
                        .disabled(meeting?.audioSystemPath == nil && meeting?.audioMicPath == nil)
                    Divider()
                    Button("Apagar reunião e áudio", role: .destructive) { state.deleteMeeting(meetingId) }
                } label: {
                    Label("Mais", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: state.dataVersion) { reload() }
        .onDisappear { player.stop() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(_ meeting: Meeting) -> some View {
        Section {
            TextField("Título", text: $title)
                .font(.title3.bold())
                .textFieldStyle(.plain)
                .onSubmit { state.renameMeeting(meetingId, to: title) }
            Text([Format.day(meeting.startedAt), Format.duration(meeting)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !meeting.tags.isEmpty {
                Text(meeting.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch meeting.status {
            case .failed:
                Label("A transcrição falhou: \(meeting.statusDetail ?? "erro desconhecido")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .recorded, .processing:
                HStack {
                    StatusBadge(meeting: meeting, state: state)
                    if let current = state.processing.current, current.meetingId == meetingId {
                        ProgressView(value: current.progress).frame(maxWidth: 160)
                    }
                }
            case .recording, .done:
                EmptyView()
            }
        }
    }

    private func speakerRow(_ speaker: MeetingSpeaker) -> some View {
        let key = "c\(speaker.diarCluster)"
        let name = speaker.personId.flatMap { persons[$0] }
        let detail = [Format.clock(ms: speaker.speechMs) + " de fala", speaker.lang].compactMap { $0 }.joined(separator: " · ")
        let anchor = "voice-\(speaker.diarCluster)"
        return SpeakerRow(
            name: name ?? "Pessoa \(speaker.diarCluster + 1)",
            color: SpeakerStyle.color(for: key),
            detail: detail,
            action: name == nil ? "Quem é?" : "Corrigir",
            onAction: { naming = NamingTarget(cluster: speaker.diarCluster, anchor: anchor) },
            onPlay: player.hasAudio && samples[speaker.diarCluster] != nil ? { playSample(of: speaker.diarCluster) } : nil
        )
        .popover(isPresented: presenting(anchor)) {
            namePopover(cluster: speaker.diarCluster, current: name)
        }
    }

    private func presenting(_ anchor: String) -> Binding<Bool> {
        Binding(
            get: { naming?.anchor == anchor },
            set: { if !$0 { naming = nil } }
        )
    }

    private func namePopover(cluster: Int, current: String?) -> some View {
        NameSpeakerView(candidates: candidates[cluster] ?? [], current: current) { chosen in
            state.nameSpeaker(meetingId: meetingId, diarCluster: cluster, as: chosen)
            naming = nil
        }
    }

    /// A few seconds of the voice, to hear who it is before naming it.
    private func playSample(of cluster: Int) {
        guard let sample = samples[cluster] else { return }
        player.play(fromMs: sample.startMs, stopAfterMs: sample.durationMs)
    }

    @ViewBuilder
    private func row(_ entry: TimelineEntry) -> some View {
        switch entry {
        case .speech(let block):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    speakerLabel(block, anchor: entry.id)
                    Button(Format.clock(ms: block.startMs)) { player.play(fromMs: block.startMs) }
                        .buttonStyle(.link)
                        .font(.caption.monospacedDigit())
                        .disabled(!player.hasAudio)
                }
                Text(text(of: block)).textSelection(.enabled)
            }
            .padding(.vertical, 2)
        case .note(let note, _):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.text).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(noteTime(note)).font(.caption).foregroundStyle(.secondary)
                        if let context = note.id.flatMap({ noteContexts[$0] }), player.hasAudio {
                            Button {
                                player.play(fromMs: context.playFromMs)
                            } label: {
                                Label("Ouvir o assunto", systemImage: "play.fill")
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Toca a partir de \(Format.clock(ms: context.playFromMs)), quando o assunto começou")
                        }
                    }
                    if let context = note.id.flatMap({ noteContexts[$0] }) {
                        subject(context)
                    }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    if let id = note.id { state.deleteNote(id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Apagar nota")
            }
            .padding(8)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Helpers

    /// "Sua nota às 14:32 · 03:21": the clock time to remember it by, the
    /// recording time to find it in the transcript.
    private func noteTime(_ note: Note) -> String {
        guard let meeting else { return Format.clock(ms: note.tMs) }
        return "Sua nota às \(Format.time(meeting.date(atOffsetMs: note.tMs))) · \(Format.clock(ms: note.tMs))"
    }

    /// Who was talking when the note was taken and the end of what they said.
    private func subject(_ context: NoteContext) -> some View {
        let speaker = Text(name(of: context.block)).bold().foregroundStyle(SpeakerStyle.color(for: context.block.speakerKey))
        return Text("\(speaker) em \(Format.clock(ms: context.block.startMs)): “\(context.excerpt())”")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
    }

    /// The speaker's name on a transcript block; for a voice of the call it
    /// is also the quickest way to say who that voice is.
    @ViewBuilder
    private func speakerLabel(_ block: SpeechBlock, anchor: String) -> some View {
        let label = Text(name(of: block)).font(.subheadline.bold()).foregroundStyle(SpeakerStyle.color(for: block.speakerKey))
        if block.speakerKey != "me", let cluster = block.segments.first?.diarCluster {
            let known = block.segments.first?.personId.flatMap { persons[$0] }
            Button {
                naming = NamingTarget(cluster: cluster, anchor: anchor)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(known == nil ? "Dizer quem é essa voz" : "Corrigir o nome dessa voz")
            .popover(isPresented: presenting(anchor)) {
                namePopover(cluster: cluster, current: known)
            }
        } else {
            label
        }
    }

    private func name(of block: SpeechBlock) -> String {
        if block.speakerKey == "me" { return "Você" }
        if let personId = block.segments.first?.personId, let name = persons[personId] { return name }
        return "Pessoa \((block.segments.first?.diarCluster ?? 0) + 1)"
    }

    /// Low-confidence passages are dimmed so they can be double-checked by
    /// ear before being trusted.
    private func text(of block: SpeechBlock) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in block.segments.enumerated() {
            var piece = AttributedString((index == 0 ? "" : " ") + segment.text)
            if (segment.confidence ?? 1) < 0.5 {
                piece.foregroundColor = .secondary
            }
            result += piece
        }
        return result
    }

    private func emptyText(_ meeting: Meeting) -> String {
        switch meeting.status {
        case .recording: "Gravando. A transcrição aparece aqui aos poucos, uns 2 minutos atrás da conversa."
        case .recorded, .processing: "Transcrição em andamento."
        case .failed: "Sem transcrição."
        case .done: "Ninguém falou nesta gravação."
        }
    }

    private func noteFieldLabel(_ meeting: Meeting) -> String {
        if meeting.status == .recording { return "Anotar agora…" }
        return player.positionMs > 0 ? "Anotar em \(Format.clock(ms: player.positionMs))…" : "Anotar no fim da reunião…"
    }

    private func addNote() {
        guard let meeting else { return }
        let tMs: Int
        if meeting.status == .recording {
            tMs = meeting.audioOffsetMs(at: noteStartedAt ?? Date())
        } else if player.positionMs > 0 {
            tMs = player.positionMs
        } else {
            tMs = meeting.audioOffsetMs(at: meeting.endedAt ?? Date())
        }
        state.addNote(newNote, meetingId: meetingId, atMs: tMs)
        newNote = ""
        noteStartedAt = nil
    }

    private func reload() {
        let db = state.db
        guard let loaded = try? db.meeting(id: meetingId) else {
            meeting = nil
            return
        }
        if meeting?.audioMicPath != loaded.audioMicPath || meeting?.audioSystemPath != loaded.audioSystemPath {
            player.load(loaded)
        }
        if meeting?.title != loaded.title {
            title = loaded.title
        }
        meeting = loaded
        let segments = (try? db.segments(meetingId: meetingId)) ?? []
        hasMicSpeech = segments.contains { $0.channel == .mic }
        documents = (try? db.documents(meetingId: meetingId)) ?? []
        let notes = (try? db.notes(meetingId: meetingId)) ?? []
        entries = Timeline.entries(segments: segments, notes: notes)
        noteContexts = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
            guard let id = note.id, let context = Timeline.context(forNoteAtMs: note.tMs, segments: segments) else { return nil }
            return (id, context)
        })
        speakers = (try? db.speakers(meetingId: meetingId)) ?? []
        let people = (try? db.persons()) ?? []
        persons = Dictionary(uniqueKeysWithValues: people.compactMap { person in person.id.map { ($0, person.name) } })
        let voiceprints = (try? db.voiceprints()) ?? []
        candidates = Dictionary(uniqueKeysWithValues: speakers.map { speaker in
            (speaker.diarCluster, VoiceReview.candidates(for: speaker.embedding, persons: people, voiceprints: voiceprints))
        })
        samples = Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
            VoiceReview.sample(cluster: speaker.diarCluster, segments: segments).map { (speaker.diarCluster, $0) }
        })
    }
}

/// A summary or other Markdown text, line by line: SwiftUI's Text renders
/// inline Markdown but drops headings and list structure.
private struct DocumentText: View {
    let markdown: String
    /// The section's title; a first heading repeating it is skipped.
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                line
            }
        }
        .textSelection(.enabled)
    }

    private var lines: [Text] {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let first = lines.first, first.hasPrefix("#"),
           first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame {
            lines.removeFirst()
        }
        return lines.map { raw in
            let line = String(raw)
            if line.hasPrefix("#") {
                return Text(inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))).font(.headline)
            }
            if line.hasPrefix("- [ ] ") {
                return Text("☐ \(inline(String(line.dropFirst(6))))")
            }
            if line.hasPrefix("- [x] ") {
                return Text("☑ \(inline(String(line.dropFirst(6))))")
            }
            if line.hasPrefix("- ") {
                return Text("• \(inline(String(line.dropFirst(2))))")
            }
            return Text(inline(line))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct SpeakerRow: View {
    let name: String
    let color: Color
    let detail: String
    var action: String?
    var onAction: () -> Void = {}
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Ouvir um trecho dessa voz")
            }
            if let action {
                Button(action, action: onAction)
            }
        }
    }
}

private struct NameSpeakerView: View {
    let candidates: [PendingVoice.Candidate]
    let current: String?
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current == nil ? "Quem é essa voz?" : "Corrigir nome").font(.headline)
            VoiceNamer(candidates: candidates, current: current, onChoose: onChoose)
            Text("Vozes mais parecidas primeiro. Nas próximas reuniões essa voz é reconhecida sozinha.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }
}
