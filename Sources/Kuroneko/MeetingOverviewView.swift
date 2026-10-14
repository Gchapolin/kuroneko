import KuronekoCore
import SwiftUI

/// The top of a meeting, always open: the summary's opening, pendências,
/// decisões and the user's own notes, each with the moment to hear it.
struct MeetingOverviewView: View {
    let state: AppState
    let data: MeetingScreenData
    let canPlay: Bool
    let onPlay: (Int) -> Void

    @State private var editing = false
    @State private var confirmingRegenerate = false

    private var meetingId: Int64 { data.meeting.id ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch data.meeting.status {
            case .recording:
                waiting("Resumo, pendências e decisões aparecem quando a transcrição terminar, uns segundos depois da call. O ícone do gato avisa.")
            case .recorded where data.summary == nil, .processing where data.summary == nil:
                waiting("Transcrevendo a reunião. Resumo, pendências e decisões aparecem quando a transcrição terminar.")
                notes
            default:
                resumo
                tasks
                decisions
                ForEach(Array(data.overview.sections.enumerated()), id: \.offset) { _, section in
                    otherSection(section)
                }
                notes
                footer
                ForEach(data.documents, id: \.kind) { document in
                    VStack(alignment: .leading, spacing: 6) {
                        MeetingStyle.sectionTitle(document.kind.prefix(1).uppercased() + document.kind.dropFirst())
                        DocumentText(markdown: document.body, title: document.kind)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $editing) {
            SummaryEditor(initial: data.summary?.body ?? "") { body in
                state.saveDocument(body, kind: "summary", meetingId: meetingId)
            }
        }
        .confirmationDialog("Gerar o resumo de novo?", isPresented: $confirmingRegenerate) {
            Button("Gerar de novo") { state.summarize(meetingId) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O resumo que você editou será substituído por um novo do Claude.")
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: - Resumo

    @ViewBuilder
    private var resumo: some View {
        if data.summary == nil {
            if state.isSummarizing(meetingId) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Gerando o resumo com o Claude…").foregroundStyle(.secondary)
                }
            } else if let failure = state.summaryFailures[meetingId] {
                failed(failure)
            } else if data.hasSpeech {
                VStack(alignment: .leading, spacing: 6) {
                    MeetingStyle.sectionTitle("Resumo")
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button("Gerar resumo") { state.summarize(meetingId) }
                        Text("O texto da reunião vai para o Claude; o áudio fica no Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if !data.overview.intro.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MeetingStyle.sectionTitle("Resumo")
                ForEach(Array(data.overview.intro.enumerated()), id: \.offset) { _, paragraph in
                    Text(Markdown.inline(paragraph))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Não deu para gerar o resumo", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            Button("Tentar de novo") { state.summarize(meetingId) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let summary = data.summary {
            FlowLayout(spacing: 10) {
                if state.isSummarizing(meetingId) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Gerando o resumo de novo com o Claude…")
                    }
                } else if let failure = state.summaryFailures[meetingId] {
                    Text("Não deu para gerar de novo: \(failure)")
                        .lineLimit(2)
                        .help(failure)
                    Button("Tentar de novo") { state.summarize(meetingId) }
                        .buttonStyle(.link)
                } else {
                    Text(Self.origin(of: summary))
                    Button("Atualizar resumo") {
                        if summary.source == "claude" {
                            state.summarize(meetingId)
                        } else {
                            confirmingRegenerate = true
                        }
                    }
                    .buttonStyle(.link)
                }
                Button("Editar") { editing = true }
                    .buttonStyle(.link)
                    .disabled(state.isSummarizing(meetingId))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// "Resumo gerado pelo Claude às 12:10".
    static func origin(of summary: MeetingDocument) -> String {
        let when = Calendar.current.isDateInToday(summary.updatedAt)
            ? "às \(Format.time(summary.updatedAt))"
            : "em \(summary.updatedAt.formatted(.dateTime.day().month(.abbreviated))) às \(Format.time(summary.updatedAt))"
        return summary.source == "claude" ? "Resumo gerado pelo Claude \(when)" : "Resumo editado \(when)"
    }

    // MARK: - Pendências and decisões

    @ViewBuilder
    private var tasks: some View {
        if !data.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MeetingStyle.sectionTitle("Pendências · \(data.tasks.count)")
                RowsCard(items: data.tasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { task.done },
                            set: { done in
                                if let ref = TaskRef(task.ref) { state.setTaskDone(ref, done) }
                            }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(task.text)
                        itemText(task.text, detail: task.owner, done: task.done)
                        time(task.startMs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var decisions: some View {
        if !data.decisions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MeetingStyle.sectionTitle("Decisões · \(data.decisions.count)")
                RowsCard(items: data.decisions) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        mark("✓", color: MeetingStyle.decision)
                        itemText(item.text, detail: item.owner)
                        time(item.startMs)
                    }
                }
            }
        }
    }

    private func otherSection(_ section: SummaryOverview.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MeetingStyle.sectionTitle("\(section.title) · \(section.items.count)")
            RowsCard(items: section.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    mark("•", color: .secondary)
                    itemText(item.text, detail: item.owner)
                    time(item.startMs)
                }
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private var notes: some View {
        if !data.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MeetingStyle.sectionTitle("Minhas notas · \(data.notes.count)")
                RowsCard(items: data.notes) { note in
                    noteRow(note)
                }
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        let images = data.images(of: note)
        let context = data.context(of: note)
        return HStack(alignment: images.isEmpty ? .firstTextBaseline : .center, spacing: 10) {
            if let first = images.first {
                PrintThumbnail(url: first.url, width: 72, height: 46)
            } else {
                mark("✎", color: MeetingStyle.noteInk)
            }
            VStack(alignment: .leading, spacing: 4) {
                itemText(note.text.isEmpty ? "Print" : note.text, detail: detail(of: note, context: context, prints: images.count))
                if images.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(images.dropFirst()) { image in
                            PrintThumbnail(url: image.url, width: 48, height: 30)
                        }
                    }
                }
            }
            PlayTimeButton(
                ms: note.tMs,
                canPlay: canPlay,
                help: context.map { "Toca a partir de \(Format.clock(ms: $0.playFromMs)), quando o assunto começou" }
            ) { _ in
                onPlay(context?.playFromMs ?? note.tMs)
            }
        }
        .contextMenu {
            Button("Apagar nota", role: .destructive) {
                if let id = note.id { state.deleteNote(id) }
            }
        }
    }

    /// "Marta: o QA só começa na segunda": what was being said.
    private func detail(of note: Note, context: NoteContext?, prints: Int) -> String? {
        if let context {
            return "\(data.name(of: context.block)): \(context.excerpt(maxLength: 90))"
        }
        guard prints > 0 else { return nil }
        return prints == 1 ? "print" : "\(prints) prints"
    }

    // MARK: - Pieces

    private func mark(_ symbol: String, color: Color) -> some View {
        Text(symbol)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .frame(width: 16)
    }

    private func itemText(_ text: String, detail: String?, done: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Markdown.inline(text))
                .strikethrough(done)
                .foregroundStyle(done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func time(_ ms: Int?) -> some View {
        if let ms {
            PlayTimeButton(ms: ms, canPlay: canPlay, onPlay: onPlay)
        }
    }
}

enum Markdown {
    /// Bold, italics, code and links of a line; the rest as written.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The summary as Markdown, to fix what Claude got wrong. Pendências are
/// lines "- [ ] o quê — quem [mm:ss]" under "## Pendências".
private struct SummaryEditor: View {
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(initial: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Editar o resumo").font(.headline)
            Text("Em Markdown. Pendências em “## Pendências”, uma por linha: “- [ ] o quê — quem [mm:ss]”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(MeetingStyle.content, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MeetingStyle.border))
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Salvar (⌘S)")
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 560)
    }
}

/// Another text of the meeting, line by line: SwiftUI's Text renders inline
/// Markdown but drops headings and list structure.
private struct DocumentText: View {
    let markdown: String
    /// The section's title; a first heading repeating it is skipped.
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                line.fixedSize(horizontal: false, vertical: true)
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
        return lines.map { line in
            if line.hasPrefix("#") {
                return Text(Markdown.inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))).font(.headline)
            }
            if line.hasPrefix("- [ ] ") {
                return Text("☐ \(Markdown.inline(String(line.dropFirst(6))))")
            }
            if line.hasPrefix("- [x] ") {
                return Text("☑ \(Markdown.inline(String(line.dropFirst(6))))")
            }
            if line.hasPrefix("- ") {
                return Text("• \(Markdown.inline(String(line.dropFirst(2))))")
            }
            return Text(Markdown.inline(line))
        }
    }
}
