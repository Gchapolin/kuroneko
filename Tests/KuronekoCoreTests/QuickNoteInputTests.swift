import CoreGraphics
import Foundation
import Testing
@testable import KuronekoCore

@Suite struct DoubleTapDetectorTests {
    /// Feeds events in order; returns the times at which it fired.
    private func run(_ events: [(TimeInterval, CGEventFlags?)]) -> [TimeInterval] {
        var detector = DoubleTapDetector()
        var fired: [TimeInterval] = []
        for (time, flags) in events {
            if let flags {
                if detector.flagsChanged(flags, at: time) { fired.append(time) }
            } else {
                detector.keyDown(at: time)
            }
        }
        return fired
    }

    private let command: CGEventFlags = .maskCommand
    private let key: CGEventFlags? = nil

    @Test func twoQuickTapsFire() {
        #expect(run([(0, command), (0.08, []), (0.25, command), (0.33, [])]) == [0.33])
    }

    @Test func capsLockAndDeviceBitsDontGetInTheWay() {
        let caps: CGEventFlags = [.maskAlphaShift]
        let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        #expect(run([(0, leftCommand.union(caps)), (0.08, caps), (0.25, leftCommand.union(caps)), (0.33, caps)]) == [0.33])
    }

    @Test func shortcutsNeverFire() {
        // ⌘C ⌘C
        #expect(run([(0, command), (0.05, key), (0.1, []), (0.2, command), (0.25, key), (0.3, [])]).isEmpty)
        // ⌘Tab, then a single tap
        #expect(run([(0, command), (0.1, key), (0.2, []), (0.3, command), (0.35, [])]).isEmpty)
        // a key typed between the taps
        #expect(run([(0, command), (0.08, []), (0.15, key), (0.25, command), (0.33, [])]).isEmpty)
    }

    @Test func aLongHoldDoesntFire() {
        #expect(run([(0, command), (0.8, []), (0.9, command), (0.95, [])]).isEmpty)
        #expect(run([(0, command), (0.08, []), (0.2, command), (0.9, [])]).isEmpty)
    }

    @Test func tapsTooFarApartDontFire() {
        #expect(run([(0, command), (0.08, []), (0.6, command), (0.68, [])]).isEmpty)
        // ...but the late tap can start a new pair.
        #expect(run([(0, command), (0.08, []), (0.6, command), (0.68, []), (0.8, command), (0.88, [])]) == [0.88])
    }

    @Test func anotherModifierCancels() {
        // ⌘ then ⇧
        #expect(run([(0, command), (0.05, [.maskCommand, .maskShift]), (0.08, command), (0.1, []), (0.25, command), (0.33, [])]).isEmpty)
        // ⇧ held through both taps
        let shifted: CGEventFlags = [.maskCommand, .maskShift]
        #expect(run([(0, .maskShift), (0.1, shifted), (0.15, .maskShift), (0.25, shifted), (0.33, .maskShift), (0.4, [])]).isEmpty)
        // ⌥ alone, twice (the Claude app's shortcut)
        #expect(run([(0, .maskAlternate), (0.08, []), (0.25, .maskAlternate), (0.33, [])]).isEmpty)
    }

    @Test func aTripleTapFiresOnce() {
        let events: [(TimeInterval, CGEventFlags?)] = [
            (0, command), (0.08, []), (0.2, command), (0.28, []), (0.4, command), (0.48, []),
        ]
        #expect(run(events) == [0.28])
    }
}

@Suite struct ScreenCaptureTests {
    private let output = URL(fileURLWithPath: "/tmp/kuroneko-prints/a.png")

    @Test func buildsTheArgumentsOfEachKindOfPrint() {
        #expect(ScreenCapture.arguments(for: .window(4242), output: output) == ["-x", "-o", "-l", "4242", "-t", "png", "/tmp/kuroneko-prints/a.png"])
        #expect(ScreenCapture.arguments(for: .display(2), output: output) == ["-x", "-D", "2", "-t", "png", "/tmp/kuroneko-prints/a.png"])
        #expect(ScreenCapture.arguments(for: .area, output: output) == ["-x", "-i", "-s", "-t", "png", "/tmp/kuroneko-prints/a.png"])
    }

    @Test func picksTheFrontmostOrdinaryWindowOfTheApp() {
        let windows = [
            ScreenCapture.Window(id: 1, pid: 10, appName: "Google Chrome", bounds: CGRect(x: 0, y: 0, width: 300, height: 24), layer: 25),
            ScreenCapture.Window(id: 2, pid: 20, appName: "Slack", bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            ScreenCapture.Window(id: 3, pid: 10, appName: "Google Chrome", bounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
            ScreenCapture.Window(id: 4, pid: 10, appName: "Google Chrome", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 0),
            ScreenCapture.Window(id: 5, pid: 10, appName: "Google Chrome", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        ]

        #expect(ScreenCapture.frontWindow(pid: 10, in: windows)?.id == 5)
        #expect(ScreenCapture.frontWindow(pid: 30, in: windows) == nil)
    }

    @Test func readsTheWindowServerDescription() throws {
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 77),
            kCGWindowOwnerPID as String: NSNumber(value: 501),
            kCGWindowOwnerName as String: "Google Chrome",
            kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 1440, height: 900).dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
        ]

        let window = try #require(ScreenCapture.Window(info: info))

        #expect(window == ScreenCapture.Window(id: 77, pid: 501, appName: "Google Chrome", bounds: CGRect(x: 10, y: 20, width: 1440, height: 900)))
        #expect(ScreenCapture.Window(info: [:]) == nil)
    }

    @Test func numbersDisplaysLikeScreencapture() {
        #expect(ScreenCapture.displayNumber(of: 7, among: [3, 7]) == 2)
        #expect(ScreenCapture.displayNumber(of: 3, among: [3, 7]) == 1)
        #expect(ScreenCapture.displayNumber(of: 9, among: [3, 7]) == 1)
    }
}
