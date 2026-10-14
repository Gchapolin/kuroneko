import AppKit
import KuronekoCore
import SwiftUI

struct MenuContent: View {
    let state: AppState

    var body: some View {
        if let meeting = state.activeMeeting {
            Text(meeting.title)
            Text(recordingStatus)
            if state.startedAutomatically {
                Text("Encerra sozinha quando você sair da chamada")
            }
            Button("Encerrar reunião") {
                state.endActiveMeeting()
            }
        } else {
            Menu("Iniciar reunião") {
                ForEach(MeetingKind.allCases, id: \.self) { kind in
                    Button(kind.label) {
                        state.startMeeting(kind: kind)
                    }
                }
            }
        }

        if let error = state.lastError {
            Divider()
            Text(error)
        }

        Divider()
        Toggle("Gravar chamadas do Meet automaticamente", isOn: Binding(
            get: { state.autoRecord },
            set: { state.setAutoRecord($0) }
        ))
        Toggle("Abrir ao iniciar sessão", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Divider()
        Button("Sair") {
            NSApp.terminate(nil)
        }
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
