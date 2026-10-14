import AppKit
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
            Image(systemName: state.isMeetingActive ? "record.circle.fill" : "cat")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only mode even when launched as a bare binary (swift run),
        // where the Info.plist LSUIElement key is not present.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the recorders so the WAV headers are finalized before exit.
        AppState.shared.endActiveMeeting()
    }
}
