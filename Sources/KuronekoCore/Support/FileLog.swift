import Foundation

/// Append-only diagnostic log in Application Support, readable without the
/// unified log (os_log entries are not accessible from sandboxed tooling).
public final class FileLog: @unchecked Sendable {
    public static let shared = FileLog(url: defaultURL)

    /// Tests run the real pipeline too: they log to a temporary file, never
    /// into the user's.
    static var defaultURL: URL {
        if ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName) {
            return FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-tests.log")
        }
        return MeetingStorage.standard().root.appendingPathComponent("kuroneko.log")
    }

    public let url: URL
    private let queue = DispatchQueue(label: "com.gandarfh.kuroneko.filelog")
    private let formatter: ISO8601DateFormatter

    public init(url: URL) {
        self.url = url
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func append(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [url] in
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                // Diagnostics must never take the app down.
            }
        }
    }

    /// Blocks until every append issued so far reached disk.
    public func flush() {
        queue.sync {}
    }
}
