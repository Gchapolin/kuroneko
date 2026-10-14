import Foundation
import Testing
@testable import KuronekoCore

@Suite struct AutoRecordPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    @Test func startsOnlyAfterMicHeldLongEnough() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)

        #expect(policy.observe(inCall: true, meetingActive: false, at: at(0)) == nil)
        #expect(policy.observe(inCall: true, meetingActive: false, at: at(4)) == nil)
        #expect(policy.observe(inCall: true, meetingActive: false, at: at(5)) == .start)
        #expect(policy.ownsActiveMeeting)
    }

    @Test func briefMicGrabDoesNotStart() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)

        _ = policy.observe(inCall: true, meetingActive: false, at: at(0))
        _ = policy.observe(inCall: false, meetingActive: false, at: at(3))
        #expect(policy.observe(inCall: true, meetingActive: false, at: at(6)) == nil)
        #expect(policy.observe(inCall: true, meetingActive: false, at: at(11)) == .start)
    }

    @Test func stopsAfterMicReleasedLongEnough() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)
        _ = policy.observe(inCall: true, meetingActive: false, at: at(0))
        _ = policy.observe(inCall: true, meetingActive: false, at: at(5))

        #expect(policy.observe(inCall: false, meetingActive: true, at: at(100)) == nil)
        #expect(policy.observe(inCall: false, meetingActive: true, at: at(114)) == nil)
        #expect(policy.observe(inCall: false, meetingActive: true, at: at(115)) == .stop)
        #expect(!policy.ownsActiveMeeting)
    }

    @Test func shortReleaseDoesNotSplitMeeting() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)
        _ = policy.observe(inCall: true, meetingActive: false, at: at(0))
        _ = policy.observe(inCall: true, meetingActive: false, at: at(5))

        _ = policy.observe(inCall: false, meetingActive: true, at: at(100))
        _ = policy.observe(inCall: true, meetingActive: true, at: at(110))
        #expect(policy.observe(inCall: false, meetingActive: true, at: at(111)) == nil)
        #expect(policy.observe(inCall: false, meetingActive: true, at: at(125)) == nil)
        #expect(policy.observe(inCall: false, meetingActive: true, at: at(126)) == .stop)
    }

    @Test func neverStopsManualMeeting() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)

        #expect(policy.observe(inCall: false, meetingActive: true, at: at(0)) == nil)
        #expect(policy.observe(inCall: false, meetingActive: true, at: at(60)) == nil)
    }

    @Test func doesNotStartWhileManualMeetingActive() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)

        _ = policy.observe(inCall: true, meetingActive: true, at: at(0))
        #expect(policy.observe(inCall: true, meetingActive: true, at: at(30)) == nil)
        #expect(!policy.ownsActiveMeeting)
    }

    @Test func userEndingMeetingSuppressesUntilMicReleased() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)
        _ = policy.observe(inCall: true, meetingActive: false, at: at(0))
        _ = policy.observe(inCall: true, meetingActive: false, at: at(5))

        policy.userEndedMeeting()
        #expect(policy.observe(inCall: true, meetingActive: false, at: at(60)) == nil)

        _ = policy.observe(inCall: false, meetingActive: false, at: at(61))
        _ = policy.observe(inCall: true, meetingActive: false, at: at(70))
        #expect(policy.observe(inCall: true, meetingActive: false, at: at(75)) == .start)
    }

    @Test func meetingEndedElsewhereDropsOwnership() {
        var policy = AutoRecordPolicy(startAfter: 5, stopAfter: 15)
        _ = policy.observe(inCall: true, meetingActive: false, at: at(0))
        _ = policy.observe(inCall: true, meetingActive: false, at: at(5))

        _ = policy.observe(inCall: false, meetingActive: false, at: at(10))
        #expect(!policy.ownsActiveMeeting)
    }
}
