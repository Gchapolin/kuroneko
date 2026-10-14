import AppKit
import KeyboardShortcuts
import KuronekoCore
import SwiftUI

struct MenuContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let meeting = state.activeMeeting {
            Text(meeting.title)
            Text(recordingStatus)
            if state.startedAutomatically {
                Text("Encerra sozinha quando você sair da chamada")
            }
            Button("Nova nota…") {
                QuickNoteController.shared.show(state: state)
            }
            .globalKeyboardShortcut(.quickNote)
            Button("Encerrar reunião") {
                state.endActiveMeeting()
            }
        } else {
            Button("Iniciar reunião") {
                state.startMeeting()
            }
        }

        if let current = state.processing.current {
            Divider()
            Text("Transcrevendo “\(current.title)”… \(Int(current.progress * 100))%")
        }

        if state.hasVoicesToName, !state.isMeetingActive {
            Divider()
            Button("Dizer quem falou…") {
                state.showVoicePromptNow()
            }
        }

        if let error = state.lastError {
            Divider()
            Text(error)
        }

        Divider()
        Button("Abrir reuniões…") {
            openWindow(id: WindowID.meetings)
            NSApp.activate()
        }
        .keyboardShortcut("o")
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
