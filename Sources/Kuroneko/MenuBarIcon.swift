import AppKit

/// The cat of the menu bar with a dot beside its head: something new is
/// waiting (a summary written by itself). A template image, so the menu bar
/// draws the cat and the dot in its own color, legible on light and dark
/// menu bars alike.
@MainActor
enum MenuBarIcon {
    static let catWithNews = makeCatWithDot()

    private static func makeCatWithDot() -> NSImage {
        // The size the menu bar gives Image(systemName: "cat"), so the cat
        // does not change size when the dot appears.
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        guard let cat = NSImage(systemSymbolName: "cat", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return NSImage(systemSymbolName: "cat", accessibilityDescription: "Kuroneko: novidades") ?? NSImage()
        }
        let diameter: CGFloat = 5.5, gap: CGFloat = 1.25
        let size = NSSize(width: cat.size.width + 4, height: cat.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            // A thin gap between the dot and the ear keeps both readable.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: rect)
            clip.appendOval(in: dot.insetBy(dx: -gap, dy: -gap))
            clip.windingRule = .evenOdd
            clip.addClip()
            cat.draw(in: NSRect(origin: .zero, size: cat.size))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kuroneko: novidades"
        return image
    }
}
