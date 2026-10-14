import Foundation
import Testing
@testable import KuronekoCore

@Suite struct FileLogTests {
    @Test func appendsTimestampedLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kuroneko-log-\(UUID().uuidString)/kuroneko.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileLog(url: url)

        log.append("primeira")
        log.append("segunda")
        log.flush()

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("primeira"))
        #expect(lines[1].hasSuffix("segunda"))
        // Every line starts with an ISO8601 timestamp.
        #expect(lines.allSatisfy { $0.contains("T") && $0.contains("Z") })
    }
}
