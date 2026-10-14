import AppKit
import KuronekoCore
import SwiftUI

/// What is being looked for with ⌘F, as a row needs it.
struct FindHighlight: Equatable {
    var query: String
    /// The occurrence in this row that is being looked at, if any.
    var current: Int?

    /// Every occurrence highlighted, the current one stronger.
    func apply(to text: inout AttributedString, plain: String) {
        guard !query.isEmpty else { return }
        let count = text.characters.count
        for (index, range) in TextFind.ranges(of: query, in: plain).enumerated() {
            let offset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            guard offset + length <= count else { continue }
            // Indices of the text as it is now: each highlight changes it.
            let characters = text.characters
            let start = characters.index(characters.startIndex, offsetBy: offset)
            let end = characters.index(start, offsetBy: length)
            text[start..<end].backgroundColor = index == current ? MeetingStyle.foundCurrent : MeetingStyle.found
        }
    }
}

/// A block of speech: who, when (a click plays it) and what was said, with
/// the passages the recognizer was unsure of dimmed.
struct SpeechRow<Name: View>: View {
    let block: SpeechBlock
    let isCurrent: Bool
    let isPlaying: Bool
    let canPlay: Bool
    let find: FindHighlight?
    let onPlay: () -> Void
    @ViewBuilder let name: () -> Name

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                name()
                Button(Format.clock(ms: block.startMs), action: onPlay)
                    .buttonStyle(.link)
                    .font(.callout.monospacedDigit())
                    .disabled(!canPlay)
                    .help("Ouvir a partir daqui")
                if isCurrent, isPlaying {
                    Spacer(minLength: 8)
                    Text("TOCANDO")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var text: AttributedString {
        var result = AttributedString()
        for (index, segment) in block.segments.enumerated() {
            var piece = AttributedString((index == 0 ? "" : " ") + segment.text)
            if (segment.confidence ?? 1) < 0.5 {
                piece.foregroundColor = .secondary
            }
            result += piece
        }
        find?.apply(to: &result, plain: Timeline.text(of: .speech(block)))
        return result
    }
}

/// One of the user's notes, in yellow, with its prints.
struct NoteRow: View {
    let note: Note
    let attachments: [NoteAttachment]
    let meta: String
    let find: FindHighlight?
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text")
                .foregroundStyle(MeetingStyle.noteInk)
            VStack(alignment: .leading, spacing: 6) {
                if !note.text.isEmpty {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                let images = attachments.filter { $0.kind == "image" }
                if !images.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(images) { image in
                            PrintThumbnail(url: image.url, width: 220, height: 124)
                        }
                    }
                }
                ForEach(attachments.filter { $0.kind != "image" }) { file in
                    Button {
                        NSWorkspace.shared.open(file.url)
                    } label: {
                        Label(file.url.lastPathComponent, systemImage: "doc")
                    }
                    .buttonStyle(.link)
                }
                Text(meta)
                    .font(.callout)
                    .foregroundStyle(MeetingStyle.noteMeta)
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Apagar nota")
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityLabel("Apagar nota")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeetingStyle.noteFill, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Apagar nota", role: .destructive, action: onDelete)
        }
    }

    private var text: AttributedString {
        var result = AttributedString(note.text)
        find?.apply(to: &result, plain: note.text)
        return result
    }
}

/// During the call, the part of the conversation not transcribed yet,
/// with the notes already taken in it.
struct LivePlaceholder: View {
    let fromMs: Int
    let notes: [Note]
    let attachments: (Note) -> [NoteAttachment]
    let meta: (Note) -> String
    let onDelete: (Note) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fromMs > 0 ? "\(Format.clock(ms: fromMs)) até agora · transcrevendo…" : "Do começo até agora · transcrevendo…")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach([0.92, 0.78, 0.85], id: \.self) { fraction in
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 9)
                        .containerRelativeFrame(.horizontal) { width, _ in width * fraction * 0.9 }
                }
            }
            .accessibilityHidden(true)
            ForEach(notes) { note in
                NoteRow(
                    note: note,
                    attachments: attachments(note),
                    meta: meta(note) + " · o que foi dito aparece aqui quando o trecho chegar",
                    find: nil,
                    onDelete: { onDelete(note) }
                )
                .padding(.top, 4)
                // As in the transcript, so a find can scroll here.
                .id(TimelineEntry.note(note, attachments: []).id)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Line()
                .stroke(MeetingStyle.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(height: 1)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}
