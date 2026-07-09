import Foundation
import KuronekoCore
import Observation
import os

@MainActor
@Observable
final class AppState {
    private(set) var activeMeeting: Meeting?
    private(set) var lastError: String?

    let db: AppDatabase
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "AppState")

    init(db: AppDatabase) {
        self.db = db
        activeMeeting = try? db.activeMeeting()
    }

    static func live() -> AppState {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Kuroneko/kuroneko.sqlite")
        do {
            return AppState(db: try AppDatabase.open(at: url))
        } catch {
            fatalError("Não foi possível abrir o banco em \(url.path): \(error)")
        }
    }

    var isMeetingActive: Bool {
        activeMeeting != nil
    }

    func startMeeting(kind: MeetingKind) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        do {
            activeMeeting = try db.startMeeting(title: "\(kind.label) \(stamp)", kind: kind)
            lastError = nil
        } catch {
            report(error, while: "iniciar reunião")
        }
    }

    func endActiveMeeting() {
        guard let id = activeMeeting?.id else { return }
        do {
            try db.endMeeting(id)
            activeMeeting = nil
            lastError = nil
        } catch {
            report(error, while: "encerrar reunião")
        }
    }

    private func report(_ error: Error, while action: String) {
        logger.error("Falha ao \(action): \(error)")
        lastError = "Falha ao \(action)"
    }
}
