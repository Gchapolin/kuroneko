import AppKit
import KeyboardShortcuts
import KuronekoCore
import SwiftUI

@main
struct KuronekoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            menuIcon
        }

        Window("Reuniões", id: WindowID.meetings) {
            MeetingsView(state: state)
        }
        .defaultSize(width: 520, height: 820)

        Settings {
            SettingsView(state: state)
        }
    }

    private var menuIcon: Image {
        if state.isMeetingActive { return Image(systemName: "record.circle.fill") }
        if state.processing.current != nil { return Image(systemName: "waveform") }
        // A dot beside the cat: a summary is ready (see "Novidades").
        if state.hasNews { return Image(nsImage: MenuBarIcon.catWithNews) }
        return Image(systemName: "cat")
    }
}

enum WindowID {
    static let meetings = "meetings"
}

extension KeyboardShortcuts.Name {
    /// ⌃⌥⌘N by default; never an ⌥+digit chord (taken by AeroSpace).
    static let quickNote = Self("quickNote", default: .init(.n, modifiers: [.control, .option, .command]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only mode even when launched as a bare binary (swift run),
        // where the Info.plist LSUIElement key is not present.
        NSApp.setActivationPolicy(.accessory)
        CaptureShield.start { AppState.shared.hiddenFromScreenCapture }
        KeyboardShortcuts.onKeyUp(for: .quickNote) {
            QuickNoteController.shared.toggle(state: AppState.shared)
        }
        AppState.shared.start()
        CommandDoubleTap.shared.start {
            QuickNoteController.shared.toggle(state: AppState.shared)
        }
        AppState.shared.onTypingCat { visible in
            TypingCatController.shared.update(visible: visible) { AppState.shared.isSomeoneSpeaking() }
        }
        AppState.shared.onVoicePrompt { meetingId in
            VoicePromptController.shared.update(meetingId: meetingId, state: AppState.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CommandDoubleTap.shared.stop()
        // Stop the recorders so the WAV headers are finalized before exit.
        AppState.shared.endActiveMeeting()
    }
}
