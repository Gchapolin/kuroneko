import AppKit

/// Keeps every Kuroneko window (menu, panels, popovers, the meetings window)
/// out of screen sharing and screen recordings: notes and names are
/// personal, and presenting the whole screen in a call must not show them.
/// New windows are covered without opting in. The menu bar icon is the one
/// exception: macOS 26 draws it into the menu bar and ignores the flag.
@MainActor
enum CaptureShield {
    private static var isOn: () -> Bool = { true }
    private static var observers: [NSObjectProtocol] = []

    static func start(isOn: @escaping () -> Bool) {
        self.isOn = isOn
        let center = NotificationCenter.default
        // Windows appear in response to events, and the app updates its
        // windows after every event: SwiftUI windows and popovers are
        // caught there.
        observers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sweep() }
        })
        // Any window turning visible or taking focus, event or not.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sweep() }
            })
        }
        // A menu runs its own event loop, without those updates.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sweep() }
            RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                MainActor.assumeIsolated { sweep() }
            }
        })
        sweep()
    }

    /// For windows Kuroneko shows itself, before they reach the screen.
    static func protect(_ window: NSWindow) {
        window.sharingType = sharingType
    }

    static func sweep() {
        let type = sharingType
        for window in NSApp.windows where window.sharingType != type {
            window.sharingType = type
        }
    }

    private static var sharingType: NSWindow.SharingType {
        isOn() ? .none : .readOnly
    }
}
