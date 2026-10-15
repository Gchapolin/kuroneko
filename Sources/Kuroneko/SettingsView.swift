import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Gravação") {
                Toggle("Gravar chamadas do Meet automaticamente", isOn: Binding(
                    get: { state.autoRecord },
                    set: { state.setAutoRecord($0) }
                ))
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Toggle("Mostrar o gatinho digitando durante a gravação", isOn: Binding(
                    get: { state.showTypingCat },
                    set: { state.setShowTypingCat($0) }
                ))
            }
            Section("Privacidade") {
                Toggle("Esconder o Kuroneko ao compartilhar ou gravar a tela", isOn: Binding(
                    get: { state.hiddenFromScreenCapture },
                    set: { state.setHiddenFromScreenCapture($0) }
                ))
                Text("Menu, notas, cartões e janelas ficam visíveis só para você, inclusive apresentando a tela inteira no Meet. Desligue para tirar prints do app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Resumo") {
                Toggle("Resumir sozinho com o Claude depois da transcrição", isOn: Binding(
                    get: { state.autoSummarize },
                    set: { state.setAutoSummarize($0) }
                ))
                Text("Usa o Claude Code da sua conta. O texto da reunião sai do Mac só nesse momento; o áudio nunca sai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Nota rápida") {
                LabeledContent("Abrir:") {
                    Text("⌘⌘ (dois toques no Command)")
                }
                commandDoubleTapStatus
                KeyboardShortcuts.Recorder("Outro atalho:", name: .quickNote)
                Text("Funciona em qualquer app durante uma gravação. Na nota, ⌘1, ⌘2 e ⌘3 anexam um print da janela, da tela inteira ou de uma área. Use #tags, como #acao ou #duvida. Digite @Nome enquanto alguém fala para o Kuroneko saber quem é aquela voz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Vocabulário") {
                TextField("Termos separados por vírgula", text: Binding(
                    get: { state.extraVocabulary },
                    set: { state.setExtraVocabulary($0) }
                ), axis: .vertical)
                .lineLimit(3...6)
                Text("Nomes de projetos, clientes e jargões do time, para a transcrição escrever do jeito certo. Os nomes das pessoas que você identificar entram sozinhos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    /// ⌘⌘ needs Input Monitoring to see the keys typed in other apps.
    @ViewBuilder private var commandDoubleTapStatus: some View {
        let hotkey = CommandDoubleTap.shared
        if hotkey.isListening {
            Label {
                Text("Monitoramento de Entrada permitido")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            HStack {
                Label {
                    Text("O ⌘⌘ precisa da permissão de Monitoramento de Entrada.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Permitir…") {
                    hotkey.requestPermission()
                }
            }
        }
    }
}
