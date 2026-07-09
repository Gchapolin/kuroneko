import AppKit
import KuronekoCore
import SwiftUI

struct MenuContent: View {
    let state: AppState

    var body: some View {
        if let meeting = state.activeMeeting {
            Text(meeting.title)
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
        Button("Sair") {
            NSApp.terminate(nil)
        }
    }
}
