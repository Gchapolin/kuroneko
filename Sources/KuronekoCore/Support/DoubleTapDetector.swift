import CoreGraphics
import Foundation

/// Recognizes Command pressed and released twice quickly, alone — the
/// shortcut of the quick note (the Claude app takes a double Option). Fed
/// with what an event tap sees: modifier changes and key presses, with
/// their times in seconds (`CGEvent.timestamp` is in nanoseconds). Nothing
/// fires when Command is part of a shortcut (⌘C, ⌘Tab), is held, or is
/// pressed with another modifier.
public struct DoubleTapDetector: Sendable {
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
}
