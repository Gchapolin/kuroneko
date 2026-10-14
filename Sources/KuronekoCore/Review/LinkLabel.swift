import Foundation

/// How a link without a title is shown: "PR #482", "ABC-123",
/// "notion.so/Release-3-4".
public enum LinkLabel {
    static let maxComponentLength = 40

    public static func label(for text: String) -> String {
        guard let url = URL(string: text), let rawHost = url.host(), !rawHost.isEmpty else { return text }
        let parts = url.pathComponents.filter { $0 != "/" }
        // Pull requests and issues: github.com/o/r/pull/482,
        // gitlab.com/o/r/-/merge_requests/12.
        for (index, part) in parts.enumerated().dropLast() {
            guard let number = Int(parts[index + 1]) else { continue }
            switch part {
            case "pull", "pulls": return "PR #\(number)"
            case "merge_requests": return "MR !\(number)"
            case "issues": return "Issue #\(number)"
            default: continue
            }
        }
        // Ticket keys in the path or the query: /browse/ABC-123,
        // ?selectedIssue=ABC-123, linear.app/t/issue/ENG-42/slug.
        let address = url.path() + "?" + (url.query() ?? "")
        if let key = address.firstMatch(of: /\b[A-Z][A-Z0-9]+-[0-9]+\b/) {
            return String(key.output)
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard let last = parts.last else { return host }
        let short = last.count > maxComponentLength ? last.prefix(maxComponentLength - 1) + "…" : last
        return "\(host)/\(short)"
    }

    /// What someone pasted or typed, as a URL to store: "github.com/x"
    /// gains https://; nil when it is not a web address.
    public static func normalize(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let full = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: full), let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return full
    }
}
