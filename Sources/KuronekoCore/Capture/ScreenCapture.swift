import CoreGraphics
import Foundation

/// Prints of the screen for notes, taken by macOS's own `screencapture`:
/// the window of the app that was in front, a whole display, or an area the
/// user drags. Kuroneko's own windows stay out (`CaptureShield`). Needs the
/// Screen Recording permission.
public enum ScreenCapture {
    public enum Target: Equatable, Sendable {
        /// A window by its CoreGraphics number, without the shadow.
        case window(CGWindowID)
        /// A display in `screencapture` numbering: 1 is the main one.
        case display(Int)
        /// A rectangle the user drags; Esc cancels.
        case area
    }

    /// A window on screen, as `CGWindowListCopyWindowInfo` describes it.
    public struct Window: Equatable, Sendable {
        public var id: CGWindowID
        public var pid: pid_t
        public var appName: String?
        /// Only readable with the Screen Recording permission.
        public var title: String?
        public var bounds: CGRect
        /// 0 for ordinary windows; menus, the Dock and overlays sit higher.
        public var layer: Int
        public var alpha: Double

        public init(id: CGWindowID, pid: pid_t, appName: String? = nil, title: String? = nil, bounds: CGRect, layer: Int = 0, alpha: Double = 1) {
            self.id = id
            self.pid = pid
            self.appName = appName
            self.title = title
            self.bounds = bounds
            self.layer = layer
            self.alpha = alpha
        }

        init?(info: [String: Any]) {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            self.init(
                id: id,
                pid: pid,
                appName: info[kCGWindowOwnerName as String] as? String,
                title: info[kCGWindowName as String] as? String,
                bounds: bounds,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }

    public static var defaultFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-prints", isDirectory: true)
    }

    public static func arguments(for target: Target, output: URL) -> [String] {
        switch target {
        case .window(let id): ["-x", "-o", "-l", String(id), "-t", "png", output.path]
        case .display(let number): ["-x", "-D", String(number), "-t", "png", output.path]
        case .area: ["-x", "-i", "-s", "-t", "png", output.path]
        }
    }

    /// The PNG it took, to attach to a note (`AppDatabase.addNote` moves it
    /// into the meeting); nil when the user cancelled the area selection.
    public static func capture(_ target: Target, into folder: URL = defaultFolder) async throws -> URL? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments(for: target, output: output)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            if target == .area { return nil }
            throw ScreenCaptureError.noImage(status: status)
        }
        return output
    }

    // MARK: - What to capture

    /// Windows on screen, front to back.
    public static func windows() -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return (list ?? []).compactMap(Window.init(info:))
    }

    /// The app's frontmost ordinary window: what the user was looking at
    /// before the note opened.
    public static func frontWindow(pid: pid_t, in windows: [Window] = windows()) -> Window? {
        windows.first { window in
            window.pid == pid && window.layer == 0 && window.alpha > 0
                && window.bounds.width >= 50 && window.bounds.height >= 50
        }
    }

    /// The display under the mouse pointer, in `screencapture` numbering.
    public static func displayUnderMouse() -> Int {
        let location = CGEvent(source: nil)?.location ?? .zero
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return 1 }
        return displayNumber(of: display, among: activeDisplays())
    }

    /// `screencapture -D` counts displays in the order of the active display
    /// list, which starts with the main one.
    static func displayNumber(of display: CGDirectDisplayID, among displays: [CGDirectDisplayID]) -> Int {
        (displays.firstIndex(of: display) ?? 0) + 1
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    // MARK: - Permission

    public static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks once (macOS shows its dialog the first time, then only Settings
    /// can grant it); true when already granted.
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

public enum ScreenCaptureError: Error, Equatable, CustomStringConvertible {
    case noImage(status: Int32)

    public var description: String {
        switch self {
        case .noImage(let status): "o screencapture não gerou a imagem (\(status))"
        }
    }
}
