import CoreGraphics
import Foundation

/// Recognizes Command pressed and released twice quickly, alone — the
/// shortcut of the quick note (the Claude app takes a double Option). Fed
/// with what an event tap sees: modifier changes, key presses and clicks,
/// with their times in seconds (`NSEvent.timestamp`; the raw
/// `CGEvent.timestamp` is in host clock ticks on Apple silicon, not the
/// nanoseconds the docs say). Nothing fires when Command is part of a
/// shortcut (⌘C, ⌘Tab), is held, or is pressed with another modifier.
public struct DoubleTapDetector: Sendable {
    /// What the event tap has to listen to.
    public static let eventTypes: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    public static var eventMask: CGEventMask {
        eventTypes.reduce(0) { $0 | (1 << $1.rawValue) }
    }

    /// Longest press that still counts as a tap.
    public var maxHold: TimeInterval
    /// Longest pause between releasing the first tap and pressing the second.
    public var maxGap: TimeInterval

    /// Caps Lock is a state, not a key being held, so it is left out.
    static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    /// When ⌘ went down alone, while nothing else has happened since.
    private var pressedAt: TimeInterval?
    /// When a clean first tap ended, waiting for the second.
    private var tappedAt: TimeInterval?
    private var held: CGEventFlags = []

    public init(maxHold: TimeInterval = 0.3, maxGap: TimeInterval = 0.35) {
        self.maxHold = maxHold
        self.maxGap = maxGap
    }

    /// The modifier keys changed; true when this completes a double tap.
    public mutating func flagsChanged(_ flags: CGEventFlags, at time: TimeInterval) -> Bool {
        let now = flags.intersection(Self.modifiers)
        defer { held = now }
        if now == .maskCommand, held.isEmpty {
            if let tappedAt, time - tappedAt > maxGap {
                self.tappedAt = nil
            }
            pressedAt = time
            return false
        }
        if now.isEmpty, held == .maskCommand, let pressedAt {
            self.pressedAt = nil
            guard time - pressedAt <= maxHold else {
                tappedAt = nil
                return false
            }
            guard tappedAt != nil else {
                tappedAt = time
                return false
            }
            // A third tap starts over instead of firing again.
            tappedAt = nil
            return true
        }
        // Another modifier joined or left: not ⌘ alone.
        pressedAt = nil
        tappedAt = nil
        return false
    }

    /// A key (or mouse button) went down: whatever ⌘ was doing, it was a
    /// shortcut.
    public mutating func keyDown(at time: TimeInterval) {
        pressedAt = nil
        tappedAt = nil
    }

    /// An event as the tap delivers it; true when it completes a double tap.
    public mutating func handle(_ type: CGEventType, flags: CGEventFlags, at time: TimeInterval) -> Bool {
        switch type {
        case .flagsChanged:
            return flagsChanged(flags, at: time)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            keyDown(at: time)
            return false
        default:
            return false
        }
    }
}
