import AppKit
import KuronekoCore
import Observation
import SwiftUI

/// A black kitten at a keyboard, floating on the screen for as long as a
/// call is being recorded: it rests while the call is quiet and types while
/// someone talks. The frames are rendered from scripts/typing-cat; the panel
/// is transparent, never takes the keyboard and remembers where it was
/// dragged to.
@MainActor
final class TypingCatController {
    static let shared = TypingCatController()
    static let size = CGSize(width: 240, height: 160)

    private var panel: NSPanel?
    private var player: CatPlayer?

    func update(visible: Bool, isSpeaking: @escaping () -> Bool) {
        if visible { show(isSpeaking: isSpeaking) } else { close() }
    }

    private func show(isSpeaking: @escaping () -> Bool) {
        guard panel == nil else { return }
        guard let player = CatPlayer(isSpeaking: isSpeaking) else {
            FileLog.shared.append("gato: frames não encontrados no bundle")
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = DraggableHostingView(rootView: TypingCatView(player: player))
        if !panel.setFrameUsingName("TypingCat"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - 16, y: screen.minY + 16))
        }
        panel.setFrameAutosaveName("TypingCat")
        CaptureShield.protect(panel)
        player.start()
        panel.orderFrontRegardless()
        self.panel = panel
        self.player = player
    }

    private func close() {
        player?.stop()
        player = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The cat is the handle: dragging it anywhere moves the panel (the
/// transparent rest lets clicks through). The autosaved frame keeps the spot.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Steps the animation at the rate the frames were rendered at.
@MainActor
@Observable
final class CatPlayer {
    private static let fps: Double = 15

    private let idle: [NSImage]
    private let typing: [NSImage]
    @ObservationIgnored private let isSpeaking: () -> Bool
    @ObservationIgnored private var animation: CatAnimation
    @ObservationIgnored private var timer: Timer?
    private(set) var image: NSImage

    init?(isSpeaking: @escaping () -> Bool) {
        idle = Self.frames(named: "idle")
        typing = Self.frames(named: "typing")
        guard let first = idle.first, !typing.isEmpty else { return nil }
        self.isSpeaking = isSpeaking
        animation = CatAnimation(idleCount: idle.count, typingCount: typing.count)
        image = first
    }

    func start() {
        let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        animation.advance(speaking: isSpeaking())
        image = (animation.clip == .idle ? idle : typing)[animation.frame]
    }

    private static func frames(named prefix: String) -> [NSImage] {
        (Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: "TypingCat") ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(NSImage.init(contentsOf:))
    }
}

struct TypingCatView: View {
    let player: CatPlayer

    var body: some View {
        Image(nsImage: player.image)
            .resizable()
            .frame(width: TypingCatController.size.width, height: TypingCatController.size.height)
            .accessibilityLabel("Gatinho preto no teclado: a reunião está sendo gravada")
    }
}
