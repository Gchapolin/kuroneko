import AppKit
import KuronekoCore
import SwiftUI

/// A small floating field to jot a note during a call without leaving the
/// call: it takes the keyboard without activating Kuroneko, and the note is
/// stamped with the current moment of the recording.
@MainActor
final class QuickNoteController {
    static let shared = QuickNoteController()

    private var panel: QuickNotePanel?

    func toggle(state: AppState) {
        if panel?.isVisible == true {
            close()
        } else {
            show(state: state)
        }
    }

    func show(state: AppState) {
        close()
        let panel = QuickNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickNoteView(state: state, startedAt: Date()) { [weak self] in
            self?.close()
        })
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - 210, y: screen.maxY - 180))
        }
        CaptureShield.protect(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class QuickNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickNoteView: View {
    let state: AppState
    /// The note belongs to the moment the shortcut was pressed, not to the
    /// moment it was finished typing.
    let startedAt: Date
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meeting = state.activeMeeting {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text(meeting.title).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text("às \(Format.time(startedAt)) · \(Format.clock(ms: meeting.audioOffsetMs(at: startedAt)))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("A nota fica neste momento da reunião, mesmo que você demore para escrever")
                }
                .font(.caption)
                TextField("Anotar… #acao · @Nome = quem está falando", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit {
                        state.addNoteToActiveMeeting(text, at: startedAt)
                        close()
                    }
            } else {
                Text("Nenhuma reunião gravando agora.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }
}
