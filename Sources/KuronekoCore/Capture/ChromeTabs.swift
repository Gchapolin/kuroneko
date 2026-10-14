import Foundation

public struct BrowserTab: Equatable, Sendable {
    public var url: String
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public enum MeetDetector {
    /// Meeting rooms live at a code path like /abc-defg-hij; the landing
    /// page and the other Meet pages are not calls.
    public static func isMeetRoom(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              components.host == "meet.google.com" else { return false }
        return components.path.wholeMatch(of: /\/[a-z]{3}-[a-z]{4}-[a-z]{3}/) != nil
    }

    public static func meetTab(in tabs: [BrowserTab]) -> BrowserTab? {
        tabs.first { isMeetRoom($0.url) }
    }

    /// Meet titles its tab "Meet: <event or room code>".
    public static func meetingTitle(fromTabTitle title: String) -> String? {
        var cleaned = title
        for prefix in ["Meet: ", "Meet - ", "Meet – "] where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "Meet" ? nil : cleaned
    }
}

public enum ChromeTabsError: Error, Equatable {
    /// The user denied (or has not yet granted) Automation access to Chrome.
    case notPermitted
    case script(Int, String)
}

/// Lists Chrome's open tabs through Apple Events. Requires the Automation
/// permission ("Kuroneko wants to control Google Chrome") the first time.
/// Not thread-safe (NSAppleScript); keep it on one actor.
public final class ChromeTabReader {
    // `is running` must be checked first: addressing the app directly would
    // launch Chrome when it is closed.
    private static let source = """
        if application id "com.google.Chrome" is running then
            tell application id "com.google.Chrome"
                return {URL of every tab of every window, title of every tab of every window}
            end tell
        end if
        return {{}, {}}
        """

    private let script: NSAppleScript

    public init() {
        script = NSAppleScript(source: Self.source)!
    }

    public func readTabs() throws -> [BrowserTab] {
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            // errAEEventNotPermitted
            if code == -1743 { throw ChromeTabsError.notPermitted }
            throw ChromeTabsError.script(code, errorInfo[NSAppleScript.errorMessage] as? String ?? "")
        }
        return Self.tabs(from: result)
    }

    /// The script returns {urls, titles}, each a list per window of lists
    /// per tab; both are flattened in the same order and zipped.
    static func tabs(from descriptor: NSAppleEventDescriptor) -> [BrowserTab] {
        guard descriptor.numberOfItems == 2,
              let urls = descriptor.atIndex(1),
              let titles = descriptor.atIndex(2) else { return [] }
        return zip(flatten(urls), flatten(titles)).map { BrowserTab(url: $0, title: $1) }
    }

    private static func flatten(_ descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.descriptorType == typeAEList else {
            return [descriptor.stringValue ?? ""]
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).flatMap { index in
            descriptor.atIndex(index).map(flatten) ?? []
        }
    }
}
