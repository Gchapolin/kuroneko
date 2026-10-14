import AppKit
import KuronekoCore
import Observation
import os

/// ⌘⌘ from anywhere opens the quick note: a listen-only event tap feeds the
/// `DoubleTapDetector` with modifier changes, keys and clicks. Seeing what
/// is typed in other apps needs the Input Monitoring permission; without it
/// there is no tap, and ⌃⌥⌘N (KeyboardShortcuts) still works.
@MainActor
@Observable
final class CommandDoubleTap {
    static let shared = CommandDoubleTap()

    /// The tap is running: the permission is granted and ⌘⌘ works.
    private(set) var isListening = false

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var detector = DoubleTapDetector()
    @ObservationIgnored private var onDoubleTap: () -> Void = {}
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var loggedFailure = false
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "CommandDoubleTap")

    private static let askedKey = "askedInputMonitoring"
    private static let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    func start(onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
        // macOS shows its prompt only once; afterwards the permission is
        // given in System Settings (the button in Ajustes › Nota rápida).
        if !CGPreflightListenEventAccess(), !UserDefaults.standard.bool(forKey: Self.askedKey) {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            CGRequestListenEventAccess()
        }
        listen()
    }

    func stop() {
        waiting?.cancel()
        waiting = nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        isListening = false
    }

    /// macOS's prompt if it never showed, otherwise the Input Monitoring
    /// list in System Settings; the tap starts as soon as it is granted.
    func requestPermission() {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        if CGRequestListenEventAccess() {
            listen()
        } else {
            NSWorkspace.shared.open(Self.privacyPane)
        }
    }

    private func listen() {
        guard tap == nil else { return }
        guard CGPreflightListenEventAccess(), let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: DoubleTapDetector.eventMask,
            callback: commandTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if CGPreflightListenEventAccess(), !loggedFailure {
                loggedFailure = true
                logger.error("Permissão de Monitoramento de Entrada concedida, mas o event tap não foi criado")
                FileLog.shared.append("nota: ⌘⌘ sem event tap, mesmo com a permissão")
            }
            waitForPermission()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Common modes: it keeps listening while a menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        isListening = true
        FileLog.shared.append("nota: ⌘⌘ escutando")
    }

    /// The permission is given in System Settings, outside the app: look
    /// again every few seconds until the tap can start.
    private func waitForPermission() {
        guard waiting == nil else { return }
        waiting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if CGPreflightListenEventAccess() {
                    waiting = nil
                    listen()
                    return
                }
            }
        }
    }

    fileprivate func handle(_ type: CGEventType, flags: CGEventFlags, at time: TimeInterval) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a tap off when it lags or on some user input;
            // turn it back on.
            FileLog.shared.append("nota: ⌘⌘ desligado pelo macOS (\(type.rawValue)), religando")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            if detector.handle(type, flags: flags, at: time) {
                onDoubleTap()
            }
        }
    }
}

/// Called on the main run loop, where the tap's source was added. Being
/// listen-only, the tap never holds up the event it is shown.
private func commandTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    // NSEvent's timestamp is in seconds (see `DoubleTapDetector`); the
    // "tap disabled" notices are not real events.
    let isEvent = type != .tapDisabledByTimeout && type != .tapDisabledByUserInput
    let time = (isEvent ? NSEvent(cgEvent: event)?.timestamp : nil) ?? ProcessInfo.processInfo.systemUptime
    let monitor = Unmanaged<CommandDoubleTap>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handle(type, flags: flags, at: time)
    }
    return Unmanaged.passUnretained(event)
}
