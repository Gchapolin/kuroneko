import Foundation

/// Decides when a meeting starts and ends on its own, from periodic samples
/// of whether a call looks active. Debounced both ways: a tab opened by
/// accident must not create a meeting, and a brief glitch (a reload, a
/// failed Apple Event) must not split one.
public struct AutoRecordPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case start
        case stop
    }

    public var startAfter: TimeInterval
    public var stopAfter: TimeInterval

    /// Whether the active meeting was started by this policy. Meetings the
    /// user started by hand are never stopped automatically.
    public private(set) var ownsActiveMeeting = false

    private var inUseSince: Date?
    private var releasedSince: Date?
    /// Set when the user ends a meeting while the call is still on, so the
    /// same call does not immediately start a new meeting.
    private var suppressedUntilRelease = false

    public init(startAfter: TimeInterval = 5, stopAfter: TimeInterval = 15) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
    }

    public mutating func observe(inCall: Bool, meetingActive: Bool, at now: Date) -> Action? {
        if inCall {
            releasedSince = nil
            inUseSince = inUseSince ?? now
        } else {
            inUseSince = nil
            releasedSince = releasedSince ?? now
            suppressedUntilRelease = false
        }

        if !meetingActive {
            ownsActiveMeeting = false
            if let inUseSince, !suppressedUntilRelease, now.timeIntervalSince(inUseSince) >= startAfter {
                ownsActiveMeeting = true
                return .start
            }
            return nil
        }

        if ownsActiveMeeting, let releasedSince, now.timeIntervalSince(releasedSince) >= stopAfter {
            ownsActiveMeeting = false
            return .stop
        }
        return nil
    }

    /// The user ended the active meeting by hand.
    public mutating func userEndedMeeting() {
        ownsActiveMeeting = false
        suppressedUntilRelease = true
    }
}
