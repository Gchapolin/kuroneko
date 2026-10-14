import KuronekoCore
import SwiftUI

/// A change being typed into one card of the list: its name or a new link.
struct CardEdit: Equatable {
    enum Field: Equatable {
        case title
        case link
    }

    var meetingId: Int64
    var field: Field
    var text: String
    /// The link typed is not a web address.
    var invalid = false
}

/// A meeting of the list: when and how long, title, people, links and what
/// it has (summary, pendências, notes, voices to name). Clicking it opens
/// the meeting; ⋯ renames, adds a link, summarizes, transcribes again or
/// deletes it.
struct MeetingCard: View {
    let item: MeetingListItem
    let meeting: Meeting?
    /// The heading above spans more than a day.
    let showsDay: Bool
    /// Nothing was said or written in it: nothing to summarize.
    let isSilent: Bool
    let state: AppState
    @Binding var edit: CardEdit?
    let open: () -> Void

    @State private var confirmingDelete = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topLine
            if editing(.title) {
                titleField
            } else {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.people.isEmpty {
                Text(PeopleText.line(item.people))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !item.links.isEmpty {
                WrappingLayout {
                    ForEach(item.links, id: \.id) { link in
                        LinkChip(link: link)
                    }
                }
            }
            if editing(.link) {
                linkField
            }
            badges
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .card(highlighted: isEditing)
        // While a field is open, clicks belong to it, not to the card.
        .gesture(TapGesture().onEnded(open), including: isEditing ? .subviews : .all)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Abrir reunião", open)
        .confirmationDialog("Apagar “\(item.title)”?", isPresented: $confirmingDelete) {
            Button("Apagar reunião e áudio", role: .destructive) { state.deleteMeeting(item.id) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A gravação, o texto, as notas e o resumo somem do Mac. Não dá para desfazer.")
        }
    }

    // MARK: - Parts

    private var topLine: some View {
        HStack(spacing: 8) {
            Text(DayText.cardLine(startedAt: item.startedAt, durationMs: item.durationMs, showsDay: showsDay))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if item.newsAt != nil {
                NewMark()
            }
            Spacer(minLength: 4)
            if let meeting {
                StatusBadge(meeting: meeting, state: state)
            }
            actions
        }
    }

    private var actions: some View {
        Menu {
            Button("Renomear") { begin(.title, text: item.title) }
            Button("Adicionar link") { begin(.link, text: "") }
            if state.isSummarizing(item.id) {
                Button("Gerando o resumo…") {}.disabled(true)
            } else {
                Button(hasSummary ? "Gerar resumo de novo" : "Gerar resumo") { state.summarize(item.id) }
                    .disabled(item.status != ProcessingStatus.done.rawValue || isSilent)
            }
            Button("Transcrever de novo") { state.retranscribe(item.id) }
                .disabled(!canTranscribeAgain)
            Divider()
            Button("Apagar reunião e áudio", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ações da reunião")
        .accessibilityLabel("Ações da reunião")
    }

    @ViewBuilder
    private var badges: some View {
        let badges = MeetingBadge.badges(for: item)
        let summarizing = state.isSummarizing(item.id)
        let failure = state.summaryFailures[item.id]
        if !badges.isEmpty || summarizing || failure != nil {
            VStack(alignment: .leading, spacing: 8) {
                ListPalette.rule.frame(height: 1)
                WrappingLayout {
                    ForEach(badges, id: \.kind) { badge in
                        Chip(text: badge.text, tint: Tint.badge(badge.kind))
                    }
                    if summarizing {
                        Chip(text: "Gerando o resumo…", tint: .blue)
                    } else if let failure {
                        Chip(text: "O resumo falhou", tint: .orange).help(failure)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var titleField: some View {
        HStack(spacing: 6) {
            TextField("Nome da reunião", text: editText)
                .textFieldStyle(.roundedBorder)
                .font(.title3.weight(.semibold))
                .focused($fieldFocused)
                .onSubmit(saveTitle)
            Button("Salvar", action: saveTitle)
                .buttonStyle(.borderedProminent)
            Button("Cancelar", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .onAppear(perform: focusField)
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Colar um link (Jira, PR, doc…)", text: editText)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(saveLink)
                Button("+ Link", action: saveLink)
                    .disabled(edit?.text.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                Button("Cancelar", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            if edit?.invalid == true {
                Text("Isso não parece um link.")
                    .font(.callout)
                    .foregroundStyle(ListPalette.late)
            }
        }
        .onAppear(perform: focusField)
    }

    // MARK: - Editing

    private var editText: Binding<String> {
        Binding(
            get: { edit?.text ?? "" },
            set: { text in
                edit?.text = text
                edit?.invalid = false
            }
        )
    }

    private var isEditing: Bool {
        edit?.meetingId == item.id
    }

    private func editing(_ field: CardEdit.Field) -> Bool {
        edit?.meetingId == item.id && edit?.field == field
    }

    private func begin(_ field: CardEdit.Field, text: String) {
        edit = CardEdit(meetingId: item.id, field: field, text: text)
    }

    private func focusField() {
        // After the ⋯ menu has closed and the field is on screen.
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func saveTitle() {
        if let text = edit?.text, text.trimmingCharacters(in: .whitespacesAndNewlines) != item.title {
            state.renameMeeting(item.id, to: text)
        }
        edit = nil
    }

    private func saveLink() {
        guard let text = edit?.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if state.addLink(text, meetingId: item.id) {
            edit = nil
        } else {
            edit?.invalid = true
        }
    }

    private func cancel() {
        edit = nil
    }

    // MARK: - State

    private var hasSummary: Bool {
        item.documents.contains("summary")
    }

    private var canTranscribeAgain: Bool {
        guard let meeting, meeting.audioSystemPath != nil || meeting.audioMicPath != nil else { return false }
        return meeting.status == .done || meeting.status == .failed
    }
}

/// A link of a meeting, opened in the browser.
struct LinkChip: View {
    let link: MeetingExport.Link
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: link.url) { openURL(url) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "link").imageScale(.small)
                Text(link.label).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            .foregroundStyle(Tint.blue.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Tint.blue.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(link.url)
    }
}
