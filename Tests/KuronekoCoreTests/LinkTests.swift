import Foundation
import Testing
@testable import KuronekoCore

@Suite struct LinkTests {
    @Test func labelsWellKnownLinks() {
        #expect(LinkLabel.label(for: "https://github.com/acme/app/pull/482") == "PR #482")
        #expect(LinkLabel.label(for: "https://github.com/acme/app/pull/482/files") == "PR #482")
        #expect(LinkLabel.label(for: "https://gitlab.com/acme/app/-/merge_requests/12") == "MR !12")
        #expect(LinkLabel.label(for: "https://github.com/acme/app/issues/7") == "Issue #7")
        #expect(LinkLabel.label(for: "https://acme.atlassian.net/browse/ABC-123") == "ABC-123")
        #expect(LinkLabel.label(for: "https://acme.atlassian.net/jira/software/projects/ABC/boards/1?selectedIssue=ABC-77") == "ABC-77")
        #expect(LinkLabel.label(for: "https://linear.app/acme/issue/ENG-42/fix-login") == "ENG-42")
    }

    @Test func otherLinksShowHostAndLastPart() {
        #expect(LinkLabel.label(for: "https://www.notion.so/acme/Doc-do-release") == "notion.so/Doc-do-release")
        #expect(LinkLabel.label(for: "https://example.com") == "example.com")
        #expect(LinkLabel.label(for: "https://example.com/a%20b") == "example.com/a b")
        #expect(LinkLabel.label(for: "https://docs.google.com/document/d/1AbC-9xyz/edit") == "docs.google.com/edit")
        let long = LinkLabel.label(for: "https://example.com/" + String(repeating: "a", count: 60))
        #expect(long.count == "example.com/".count + LinkLabel.maxComponentLength)
        #expect(long.hasSuffix("…"))
        #expect(LinkLabel.label(for: "não é link") == "não é link")
    }

    @Test func normalizesWhatWasTyped() {
        #expect(LinkLabel.normalize(" github.com/acme/app/pull/1 ") == "https://github.com/acme/app/pull/1")
        #expect(LinkLabel.normalize("http://localhost:3000/x") == "http://localhost:3000/x")
        #expect(LinkLabel.normalize("relatório final") == nil)
        #expect(LinkLabel.normalize("") == nil)
        #expect(LinkLabel.normalize("abc") == nil)
    }

    @Test func linksBelongToTheMeeting() throws {
        let db = try AppDatabase.inMemory()
        let planning = try db.startMeeting(title: "Planning").id!
        let daily = try db.startMeeting(title: "Daily").id!
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let pr = try db.addLink(meetingId: planning, url: "https://github.com/acme/app/pull/482", at: start)
        let doc = try db.addLink(meetingId: planning, url: "https://notion.so/x/Release", title: " Doc do release ", at: start.addingTimeInterval(1))
        try db.addLink(meetingId: daily, url: "https://example.com", title: "", at: start)

        #expect(try db.links(meetingId: planning).map(\.label) == ["PR #482", "Doc do release"])
        #expect(try db.linksByMeeting()[daily]?.first?.title == nil)
        #expect(try db.export(meetingId: planning)?.links.map(\.label) == ["PR #482", "Doc do release"])
        #expect(try db.meetingList().first { $0.id == planning }?.links.map(\.id) == [pr.id!, doc.id!])

        try db.deleteLink(pr.id!)
        #expect(try db.link(id: pr.id!) == nil)
        try db.deleteMeeting(planning)
        #expect(try db.links(meetingId: planning).isEmpty)
        #expect(try db.links(meetingId: daily).count == 1)
    }

    @Test func parsesLinkCommands() throws {
        #expect(try CLICommand.parse(["link", "add", "4", "github.com/acme/app/pull/482", "login", "novo"])
            == .linkAdd(meetingId: 4, url: "https://github.com/acme/app/pull/482", title: "login novo"))
        #expect(try CLICommand.parse(["link", "add", "4", "https://example.com"]) == .linkAdd(meetingId: 4, url: "https://example.com", title: nil))
        #expect(try CLICommand.parse(["link", "rm", "7"]) == .linkRemove(linkId: 7))
        #expect(throws: CLIError.self) { try CLICommand.parse(["link", "add", "4"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["link", "add", "4", "não", "é"]) }
    }
}
