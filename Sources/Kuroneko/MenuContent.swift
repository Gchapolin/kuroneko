import AppKit
import KuronekoCore
import os
import SwiftUI

struct MenuContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let facts = MenuFacts.shared.read(state)
        let voices = state.hasVoicesToName && !state.isMeetingActive

        if !state.meetingsWithNews.isEmpty || voices {
            Section("Novidades") {
                ForEach(state.meetingsWithNews, id: \.id) { meeting in
                    Button {
                        if let id = meeting.id { showWindow(.meeting(id)) }
                    } label: {
                        // The second text is the item's subtitle.
                        Text("Resumo pronto: \(meeting.title)")
                        let subtitle = facts.newsSubtitle(meeting)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                        }
                    }
                }
                if voices {
                    Button("Dizer quem falou…") {
                        state.showVoicePromptNow()
                    }
                }
            }
            // The section brings its own separators.
        }

        if let meeting = state.activeMeeting {
            Text(meeting.title)
            Text(recordingStatus)
            if state.startedAutomatically {
                Text("Encerra sozinha quando você sair da chamada")
            }
            newNote
            Button("Encerrar reunião") {
                state.endActiveMeeting()
            }
        } else {
            Button("Iniciar reunião") {
                state.startMeeting()
            }
            newNote
        }

        if let current = state.processing.current {
            Divider()
            Text("Transcrevendo “\(current.title)”… \(Int(current.progress * 100))%")
        }

        if let error = state.lastError {
            Divider()
            Text(error)
        }

        Divider()
        Button("Abrir reuniões…") {
            showWindow(nil)
        }
        .keyboardShortcut("o")
        Button(facts.openTasks.isEmpty ? "Pendências abertas" : "Pendências abertas · \(facts.openTasks.count)") {
            showWindow(.tasks)
        }
        Button("Ajustes…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()
        Button("Sair") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var newNote: some View {
        Button("Nova nota…") {
            QuickNoteController.shared.show(state: state)
        }
        // Shows ⌘⌘ (Command twice) as the hint; no key types "⌘", so it never
        // fires itself. The note shortcut (⌃⌥⌘N by default) is global,
        // registered in AppDelegate, and works with the menu open too.
        .keyboardShortcut(KeyEquivalent("⌘"), modifiers: .command)
    }

    private func showWindow(_ request: Navigator.Request?) {
        if let request { Navigator.shared.go(to: request) }
        openWindow(id: WindowID.meetings)
        NSApp.activate()
    }

    private var recordingStatus: String {
        guard state.isRecording else { return "Sem gravação de áudio" }
        let system = switch state.systemSource {
        case .chrome: "Chrome"
        case .global: "áudio do sistema"
        case .none: "sem áudio do sistema"
        }
        return state.isMicRecording ? "Gravando: mic + \(system)" : "Gravando: \(system) (sem mic)"
    }
}

/// What the menu counts, read from the database only when the data changed:
/// the menu is rebuilt on every change of the app state, transcription
/// progress included.
@MainActor
private final class MenuFacts {
    static let shared = MenuFacts()

    private struct Key: Equatable {
        var dataVersion: Int
        var news: [Int64?]
    }

    private(set) var openTasks: [TaskItem] = []
    private var key: Key?
    private var decisions: [Int64: Int] = [:]
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MenuContent")

    func read(_ state: AppState) -> MenuFacts {
        let key = Key(dataVersion: state.dataVersion, news: state.meetingsWithNews.map(\.id))
        guard key != self.key else { return self }
        self.key = key
        decisions = [:]
        do {
            openTasks = try state.db.openTasks()
            for meeting in state.meetingsWithNews {
                guard let id = meeting.id else { continue }
                decisions[id] = try state.db.summaryItems(meetingId: id).count(where: { $0.kind == "decision" })
            }
        } catch {
            logger.error("Falha ao contar as pendências do menu: \(String(describing: error))")
        }
        return self
    }

    /// "3 pendências · 2 decisões · 1h de reunião".
    func newsSubtitle(_ meeting: Meeting) -> String {
        guard let id = meeting.id else { return "" }
        return NewsText.summaryReady(
            openTasks: openTasks.count(where: { $0.meetingId == id }),
            decisions: decisions[id] ?? 0,
            durationMs: meeting.durationMs
        )
    }
}
