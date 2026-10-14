import AppKit
import SwiftUI

/// Colors of the meetings window, for light and dark mode.
enum ListPalette {
    static let background = Color(light: 0xF5F5F7, dark: 0x1C1C1E)
    static let card = Color(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let cardBorder = Color(light: 0xE2E2E6, dark: 0x3A3A3E)
    static let cardHoverBorder = Color(light: 0xC8C8CE, dark: 0x505055)
    /// Lines inside a card.
    static let rule = Color(light: 0xEDEDF0, dark: 0x363639)
    /// Pendências open for too long.
    static let late = Color(light: 0xA31D15, dark: 0xFF8A80)
    static let recording = Tint(
        background: Color(light: 0xFDECEA, dark: 0x3A1F1D),
        foreground: Color(light: 0x6B2A24, dark: 0xF2BBB4),
        border: Color(light: 0xF4C7C2, dark: 0x6B302B)
    )
    static let recordingAccent = Color(light: 0xA31D15, dark: 0xFF8A80)
    static let recordingDot = Color(light: 0xC4251C, dark: 0xFF5F57)
}

/// Background and text of a chip; a dashed border marks something to do.
struct Tint {
    var background: Color
    var foreground: Color
    var border: Color?
    var dashed = false

    static let blue = Tint(background: Color(light: 0xEEF3FD, dark: 0x1D3252), foreground: Color(light: 0x0A4FB0, dark: 0x9CC3FA))
    static let green = Tint(background: Color(light: 0xE9F5EC, dark: 0x1C3A25), foreground: Color(light: 0x1A6B32, dark: 0x8FD9A4))
    static let yellow = Tint(background: Color(light: 0xFFF4D1, dark: 0x3B3214), foreground: Color(light: 0x6B5300, dark: 0xEBD27E))
    static let orange = Tint(background: Color(light: 0xFDEBDD, dark: 0x3D2716), foreground: Color(light: 0x8A3B00, dark: 0xF7B98A))
    static let pink = Tint(
        background: .clear,
        foreground: Color(light: 0x8A1A45, dark: 0xF4A3C4),
        border: Color(light: 0xC2185B, dark: 0xE0679A),
        dashed: true
    )

    /// For a `MeetingBadge.kind`.
    static func badge(_ kind: String) -> Tint {
        switch kind {
        case "summary": .blue
        case "tasks": .green
        case "notes": .yellow
        case "voices": .pink
        default: .orange
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// A small rounded label: badges of a card, owners of pendências.
struct Chip: View {
    let text: String
    let tint: Tint

    var body: some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .foregroundStyle(tint.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.background, in: Capsule())
            .overlay {
                if let border = tint.border {
                    Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: tint.dashed ? [3, 2] : []))
                }
            }
    }
}

/// "Novo": the meeting has something the user hasn't seen.
struct NewMark: View {
    var body: some View {
        Text("Novo")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
            .accessibilityLabel("Novidade")
    }
}

/// White (or dark gray) rounded card on the gray window, with a border that
/// darkens under the pointer.
struct CardStyle: ViewModifier {
    var highlighted = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .background(ListPalette.card, in: shape)
            .overlay {
                shape.strokeBorder(
                    highlighted ? Color.accentColor : hovering ? ListPalette.cardHoverBorder : ListPalette.cardBorder,
                    lineWidth: highlighted ? 2 : 1
                )
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View {
        modifier(CardStyle(highlighted: highlighted))
    }
}

/// Lays its views out in rows, wrapping to the next row when the width runs
/// out. Unlike `FlowLayout`, a view wider than a row (a long link title) is
/// offered the row's width instead of overflowing the card.
struct WrappingLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
