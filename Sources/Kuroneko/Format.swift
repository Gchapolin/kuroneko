import Foundation
import KuronekoCore
import SwiftUI

enum Format {
    /// 03:21 or 1:03:21.
    static func clock(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func duration(_ meeting: Meeting) -> String? {
        guard let end = meeting.endedAt else { return nil }
        let minutes = Int(end.timeIntervalSince(meeting.startedAt) / 60)
        return minutes < 60 ? "\(max(1, minutes)) min" : "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }

    /// 14:32.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

enum SpeakerStyle {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red]

    static func color(for key: String) -> Color {
        guard key != "me", let cluster = Int(key.dropFirst()) else { return .secondary }
        return palette[abs(cluster) % palette.count]
    }
}
