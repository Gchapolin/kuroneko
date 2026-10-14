import Foundation

/// Filesystem layout for everything Kuroneko persists outside SQLite.
public struct MeetingStorage: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> MeetingStorage {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MeetingStorage(root: support.appendingPathComponent("Kuroneko", isDirectory: true))
    }

    public var databaseURL: URL {
        root.appendingPathComponent("kuroneko.sqlite")
    }

    public func meetingDirectory(id: Int64) -> URL {
        root.appendingPathComponent("meetings/\(id)", isDirectory: true)
    }

    /// Last time any audio file of the meeting was written: when the app dies
    /// mid-meeting, that is when the recording really ended.
    public func lastAudioWrite(meetingId: Int64) -> Date? {
        ["mic.wav", "system.wav"]
            .compactMap { name in
                try? meetingDirectory(id: meetingId)
                    .appendingPathComponent(name)
                    .resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
            .max()
    }

    public func screenshotsDirectory(meetingId: Int64) -> URL {
        meetingDirectory(id: meetingId).appendingPathComponent("screenshots", isDirectory: true)
    }
}
