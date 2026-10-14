import KuronekoCore
import SwiftUI

/// Says who a voice is in one click: known people closest voice first (the
/// likely ones highlighted), or a new name.
struct VoiceNamer: View {
    let candidates: [PendingVoice.Candidate]
    var current: String?
    let onChoose: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let shown = visibleCandidates
            if !shown.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(shown, id: \.personId) { candidate in
                        chip(candidate)
                    }
                }
            }
            HStack {
                TextField(candidates.isEmpty ? "Nome" : "Outro nome", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Salvar", action: submit)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { text = current ?? "" }
    }

    /// Typing filters the known people, so the field doubles as search.
    private var visibleCandidates: [PendingVoice.Candidate] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || typed == current {
            return Array(candidates.prefix(4))
        }
        return Array(candidates.filter { $0.name.localizedCaseInsensitiveContains(typed) }.prefix(8))
    }

    private func chip(_ candidate: PendingVoice.Candidate) -> some View {
        Button {
            onChoose(candidate.name)
        } label: {
            HStack(spacing: 4) {
                Text(candidate.name).lineLimit(1)
                if let similarity = candidate.similarity {
                    Text("\(Int((max(0, similarity) * 100).rounded()))%")
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
        }
        .buttonStyle(ChipStyle(highlighted: candidate.isLikely))
        .help(candidate.similarity == nil ? "Ainda sem voz gravada" : "Quão parecida é a voz")
    }

    private func submit() {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onChoose(name)
    }
}

/// The likely person stands out even in a window without focus, where the
/// system button styles turn gray.
private struct ChipStyle: ButtonStyle {
    let highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill = highlighted ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08)
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(fill.opacity(configuration.isPressed ? 1.6 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(highlighted ? Color.accentColor : .clear))
            .contentShape(Capsule())
    }
}

/// Lays children left to right, wrapping to a new line when the width runs
/// out (the windows are narrow).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }
}
