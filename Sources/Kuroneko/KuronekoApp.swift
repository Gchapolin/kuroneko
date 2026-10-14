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
            Image(systemName: menuIcon)
        }

        Window("Reuniões", id: WindowID.meetings) {
            MeetingsView(state: state)
        }
        .defaultSize(width: 520, height: 820)

        Settings {
            SettingsView(state: state)
        }
    }

    private var menuIcon: String {
        if state.isMeetingActive { return "record.circle.fill" }
        if state.processing.current != nil { return "waveform" }
        return "cat"
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
        AppState.shared.onVoicePrompt { meetingId in
            VoicePromptController.shared.update(meetingId: meetingId, state: AppState.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the recorders so the WAV headers are finalized before exit.
        AppState.shared.endActiveMeeting()
    }
}
