import AppKit
import KuronekoCore
import SwiftUI

/// A black kitten typing in a small floating card for as long as a call is
/// being recorded. The frames are rendered from scripts/typing-cat; the card
/// never takes the keyboard and remembers where it was dragged to.
@MainActor
final class TypingCatController {
    static let shared = TypingCatController()

    private var panel: NSPanel?

    func update(visible: Bool) {
        if visible { show() } else { close() }
    }

    private func show() {
        guard panel == nil else { return }
        let frames = TypingCatView.loadFrames()
        guard !frames.isEmpty else {
            FileLog.shared.append("gato: frames não encontrados no bundle")
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: TypingCatView.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: TypingCatView(frames: frames))
        if !panel.setFrameUsingName("TypingCat"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - TypingCatView.size.width - 16, y: screen.minY + 16))
        }
        panel.setFrameAutosaveName("TypingCat")
        CaptureShield.protect(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func close() {
        panel?.contentViewController = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct TypingCatView: View {
    let frames: [NSImage]

    static let size = CGSize(width: 240, height: 160)
    private static let loop = { (count: Int) in SpriteLoop(frameCount: count, fps: 15) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let index = Self.loop(frames.count).frame(at: context.date.timeIntervalSinceReferenceDate)
            Image(nsImage: frames[index])
                .resizable()
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityLabel("Gatinho preto digitando: a reunião está sendo gravada")
    }

    static func loadFrames() -> [NSImage] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: "TypingCat") ?? []
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(NSImage.init(contentsOf:))
    }
}
