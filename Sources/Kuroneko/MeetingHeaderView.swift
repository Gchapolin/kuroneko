import AppKit
import KuronekoCore
import SwiftUI

/// Saying who a voice is, from a chip of the header or a name in the
/// transcript: one popover at a time, anchored where it was asked.
@MainActor
struct VoiceNaming {
    let state: AppState
    let meetingId: Int64
    let data: MeetingScreenData
    let canPlay: Bool
    let target: Binding<NamingTarget?>
    let playSample: (Int) -> Void

    func open(cluster: Int, anchor: String) {
        target.wrappedValue = NamingTarget(cluster: cluster, anchor: anchor)
    }

    func isPresented(_ anchor: String) -> Binding<Bool> {
        let target = target
        return Binding(
            get: { target.wrappedValue?.anchor == anchor },
            set: { if !$0 { target.wrappedValue = nil } }
        )
    }

    func popover(cluster: Int) -> some View {
        NameVoicePopover(
            candidates: data.candidates[cluster] ?? [],
            current: data.personName(cluster: cluster),
            onPlaySample: canPlay && data.samples[cluster] != nil ? { playSample(cluster) } : nil
        ) { chosen in
            state.nameSpeaker(meetingId: meetingId, diarCluster: cluster, as: chosen)
            target.wrappedValue = nil
        }
    }
}

/// Title, when, who and links of a meeting.
struct MeetingHeaderView: View {
    let state: AppState
    let data: MeetingScreenData
    let naming: VoiceNaming
    var focus: FocusState<MeetingField?>.Binding

    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var addingLink = false
    @State private var linkDraft = ""
    @State private var linkInvalid = false

    private var meeting: Meeting { data.meeting }
    private var meetingId: Int64 { meeting.id ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            when
            status
            if !data.voices.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(data.voices) { voice in
                        chip(voice)
                    }
                }
                .padding(.top, 2)
            }
            links
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focus.wrappedValue) { old, new in
            // Clicking elsewhere keeps the new title, like a rename in the Finder.
            if old == .title, new != .title, editingTitle { commitTitle() }
            if old == .link, new != .link, linkDraft.isEmpty { addingLink = false }
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if editingTitle {
            TextField("Título da reunião", text: $titleDraft, axis: .vertical)
                .font(.system(size: 20, weight: .bold))
                .textFieldStyle(.plain)
                .focused(focus, equals: .title)
                .onAppear { focus.wrappedValue = .title }
                .onSubmit(commitTitle)
                .onExitCommand {
                    editingTitle = false
                    focus.wrappedValue = nil
                }
                .accessibilityLabel("Título da reunião")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meeting.title)
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button {
                    titleDraft = meeting.title
                    editingTitle = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Renomear a reunião")
                .accessibilityLabel("Renomear a reunião")
            }
        }
    }

    private func commitTitle() {
        editingTitle = false
        let new = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !new.isEmpty, new != meeting.title {
            state.renameMeeting(meetingId, to: new)
        }
        if focus.wrappedValue == .title { focus.wrappedValue = nil }
    }

    // MARK: - When

    @ViewBuilder
    private var when: some View {
        if data.isRecording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let live = state.activeMeeting?.id == meetingId ? state.activeMeeting ?? meeting : meeting
                let elapsed = Format.clock(ms: live.audioOffsetMs(at: context.date))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("\(Text("Gravando · \(elapsed)").foregroundStyle(MeetingStyle.recording).bold()) · começou às \(Format.time(meeting.startedAt))\(sources)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        } else {
            Text(Self.dateLine(meeting))
                .font(.callout)
                .foregroundStyle(.secondary)
            if !meeting.tags.isEmpty {
                Text(meeting.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// " · mic + Chrome": what is being recorded, when it is this meeting.
    private var sources: String {
        guard state.activeMeeting?.id == meetingId, state.isRecording else { return "" }
        let system = switch state.systemSource {
        case .chrome: "Chrome"
        case .global: "áudio do sistema"
        case .none: "sem áudio do sistema"
        }
        return state.isMicRecording ? " · mic + \(system)" : " · \(system), sem mic"
    }

    /// "qua., 14 de out. · 10:45–11:45 · 1h".
    static func dateLine(_ meeting: Meeting) -> String {
        let day = meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard let end = meeting.endedAt else { return "\(day) · \(Format.time(meeting.startedAt))" }
        let minutes = max(1, Int((end.timeIntervalSince(meeting.startedAt) / 60).rounded()))
        let length = minutes < 60
            ? "\(minutes) min"
            : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
        return "\(day) · \(Format.time(meeting.startedAt))–\(Format.time(end)) · \(length)"
    }

    @ViewBuilder
    private var status: some View {
        switch meeting.status {
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("A transcrição falhou: \(meeting.statusDetail ?? "erro desconhecido")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Transcrever de novo") { state.retranscribe(meetingId) }
                    .disabled(meeting.audioSystemPath == nil && meeting.audioMicPath == nil)
            }
            .font(.callout)
        case .recorded, .processing:
            HStack(spacing: 8) {
                StatusBadge(meeting: meeting, state: state)
                if let current = state.processing.current, current.meetingId == meetingId {
                    ProgressView(value: current.progress).frame(maxWidth: 160)
                }
            }
        case .recording, .done:
            EmptyView()
        }
    }

    // MARK: - People

    @ViewBuilder
    private func chip(_ voice: MeetingScreenData.Voice) -> some View {
        let label = HStack(spacing: 6) {
            Circle().fill(SpeakerStyle.color(for: voice.key)).frame(width: 8, height: 8)
            Text(voice.name == nil && voice.cluster != nil ? "\(voice.label) · quem é?" : voice.label)
                .lineLimit(1)
        }
        if let cluster = voice.cluster {
            let anchor = "chip-\(cluster)"
            Button {
                naming.open(cluster: cluster, anchor: anchor)
            } label: {
                label
            }
            .buttonStyle(MeetingChipStyle(dashed: voice.name == nil))
            .help(voice.name == nil ? "Dizer quem é essa voz" : "Corrigir o nome dessa voz")
            .popover(isPresented: naming.isPresented(anchor), arrowEdge: .bottom) {
                naming.popover(cluster: cluster)
            }
        } else {
            // The user's own voice, from the mic: nothing to name.
            label
                .modifier(MeetingChip())
                .help("Seu microfone")
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var links: some View {
        FlowLayout(spacing: 6) {
            ForEach(data.links) { link in
                linkChip(link)
            }
            if addingLink {
                TextField("Colar o link", text: $linkDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(width: 230)
                    .focused(focus, equals: .link)
                    .onAppear { focus.wrappedValue = .link }
                    .onSubmit(addLink)
                    .onExitCommand(perform: cancelLink)
                    .onChange(of: linkDraft) { linkInvalid = false }
                    .accessibilityLabel("Novo link")
            } else {
                Button("+ Link") {
                    addingLink = true
                }
                .buttonStyle(MeetingChipStyle(dashed: true, rounded: true))
                .help("Guardar um link desta reunião: PR, card, documento")
            }
        }
        if linkInvalid {
            Text("Isso não parece um link.")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func linkChip(_ link: MeetingLink) -> some View {
        Button {
            open(link)
        } label: {
            Label(link.label, systemImage: "link")
                .labelStyle(LinkChipLabelStyle())
                .lineLimit(1)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(MeetingChipStyle(fill: Color.accentColor.opacity(0.1), rounded: true))
        .help(link.url)
        .contextMenu {
            Button("Abrir") { open(link) }
            Button("Copiar o link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url, forType: .string)
            }
            Divider()
            Button("Remover o link", role: .destructive) {
                if let id = link.id { state.deleteLink(id) }
            }
        }
    }

    private func open(_ link: MeetingLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func addLink() {
        guard !linkDraft.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancelLink()
            return
        }
        if state.addLink(linkDraft, meetingId: meetingId) {
            linkDraft = ""
            addingLink = false
            focus.wrappedValue = nil
        } else {
            linkInvalid = true
        }
    }

    private func cancelLink() {
        linkDraft = ""
        linkInvalid = false
        addingLink = false
        focus.wrappedValue = nil
    }
}

private struct LinkChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}
