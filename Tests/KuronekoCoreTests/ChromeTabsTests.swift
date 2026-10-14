import Foundation
import Testing
@testable import KuronekoCore

@Suite struct MeetDetectorTests {
    @Test func recognizesMeetingRooms() {
        #expect(MeetDetector.isMeetRoom("https://meet.google.com/abc-defg-hij"))
        #expect(MeetDetector.isMeetRoom("https://meet.google.com/abc-defg-hij?authuser=0&pli=1"))
    }

    @Test func rejectsOtherMeetPagesAndSites() {
        #expect(!MeetDetector.isMeetRoom("https://meet.google.com/"))
        #expect(!MeetDetector.isMeetRoom("https://meet.google.com/landing"))
        #expect(!MeetDetector.isMeetRoom("https://meet.google.com/new"))
        #expect(!MeetDetector.isMeetRoom("https://example.com/abc-defg-hij"))
        #expect(!MeetDetector.isMeetRoom("https://www.youtube.com/watch?v=abc"))
        #expect(!MeetDetector.isMeetRoom(""))
    }

    @Test func findsTheMeetTabAmongOthers() {
        let tabs = [
            BrowserTab(url: "https://github.com", title: "GitHub"),
            BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - Daily"),
        ]
        #expect(MeetDetector.meetTab(in: tabs)?.title == "Meet - Daily")
        #expect(MeetDetector.meetTab(in: [tabs[0]]) == nil)
    }

    @Test func extractsMeetingTitleFromTabTitle() {
        #expect(MeetDetector.meetingTitle(fromTabTitle: "Meet: jos-cgmb-hzr") == "jos-cgmb-hzr")
        #expect(MeetDetector.meetingTitle(fromTabTitle: "Meet - Daily Squad") == "Daily Squad")
        #expect(MeetDetector.meetingTitle(fromTabTitle: "Meet – abc-defg-hij") == "abc-defg-hij")
        #expect(MeetDetector.meetingTitle(fromTabTitle: "Meet") == nil)
        #expect(MeetDetector.meetingTitle(fromTabTitle: "") == nil)
    }
}

@Suite struct ChromeTabReaderTests {
    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        for (offset, item) in items.enumerated() {
            descriptor.insert(item, at: offset + 1)
        }
        return descriptor
    }

    private func strings(_ values: [String]) -> NSAppleEventDescriptor {
        list(values.map { NSAppleEventDescriptor(string: $0) })
    }

    @Test func zipsUrlsAndTitlesAcrossWindows() {
        let result = list([
            list([strings(["https://a.com", "https://b.com"]), strings(["https://c.com"])]),
            list([strings(["A", "B"]), strings(["C"])]),
        ])

        #expect(ChromeTabReader.tabs(from: result) == [
            BrowserTab(url: "https://a.com", title: "A"),
            BrowserTab(url: "https://b.com", title: "B"),
            BrowserTab(url: "https://c.com", title: "C"),
        ])
    }

    @Test func noWindowsMeansNoTabs() {
        #expect(ChromeTabReader.tabs(from: list([list([]), list([])])).isEmpty)
    }
}
