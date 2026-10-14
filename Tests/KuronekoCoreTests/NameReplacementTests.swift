import Foundation
import Testing
@testable import KuronekoCore

@Suite struct NameReplacementTests {
    @Test func replacesWholeWordsOnly() {
        let text = "Pessoa 1 abre o card. Pessoa 10 revisa. A Pessoa 1, depois."

        #expect(NameReplacement.replace("Pessoa 1", with: "Ana", in: text) == "Ana abre o card. Pessoa 10 revisa. A Ana, depois.")
        #expect(NameReplacement.replace("Ana", with: "Mariana", in: "Ana e Mariana") == "Mariana e Mariana")
        #expect(NameReplacement.replace("Ana", with: "Bia", in: "Mariana") == "Mariana")
    }

    @Test func aNameWithSymbolsIsTakenLiterally() {
        #expect(NameReplacement.replace("Pessoa 2", with: "J. (João) $1", in: "- [ ] revisar — Pessoa 2 [03:10]")
            == "- [ ] revisar — J. (João) $1 [03:10]")
    }

    @Test func namingAVoiceUpdatesTheSummary() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Daily").id)
        try db.appendTranscript(meetingId: id, speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 5000)], segments: [])
        try db.setDocument(meetingId: id, kind: "summary", body: "## Pendências\n- [ ] Abrir o card — Pessoa 1 [12:31]", source: "claude")

        try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: "Bruno")
        #expect(try db.documents(meetingId: id).first?.body == "## Pendências\n- [ ] Abrir o card — Bruno [12:31]")

        // A correction renames them again.
        try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: "Bruna")
        #expect(try db.documents(meetingId: id).first?.body == "## Pendências\n- [ ] Abrir o card — Bruna [12:31]")
    }
}
