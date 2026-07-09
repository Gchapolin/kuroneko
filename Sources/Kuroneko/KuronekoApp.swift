import AppKit
import KuronekoCore
import SwiftUI

@main
struct KuronekoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.live()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.isMeetingActive ? "record.circle.fill" : "cat")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only mode even when launched as a bare binary (swift run),
        // where the Info.plist LSUIElement key is not present.
        NSApp.setActivationPolicy(.accessory)
    }
}
