import AppKit
import KuronekoCore
import os
import SwiftUI

/// The bottom of a meeting, always in view: the player (after the call)
/// and the field to write a note, with prints, at the moment being heard.
struct MeetingBottomBar: View {
    let state: AppState
    let meeting: Meeting
    let player: MeetingPlayer
    let marks: [Int]
    var focus: FocusState<MeetingField?>.Binding
    /// The user started playing: the transcript follows the audio again.
    let onUserPlay: () -> Void

    @State private var draft = ""
    @State private var prints: [DraftPrint] = []
    @State private var anchor: NoteAnchor?
    @State private var problem: CaptureProblem?
    @State private var capturing = false
    private let previousApp = PreviousApp.shared

    private var isRecording: Bool { meeting.status == .recording }
    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !prints.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isRecording, player.hasAudio {
                Scrubber(player: player, marks: marks)
                Transport(player: player, onUserPlay: onUserPlay)
            }
            ForEach(prints) { print in
                printChip(print)
            }
            if let problem {
                problemView(problem)
            }
            HStack(alignment: .bottom, spacing: 8) {
                field
                printMenu
                saveButton
            }
            if isRecording {
                Text("De qualquer lugar: ⌘⌘ abre a nota rápida")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isRecording ? 12 : 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeetingStyle.bar)
    }

    // MARK: - Note

    private var field: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(MeetingStyle.content, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focus.wrappedValue == .note ? Color.accentColor : MeetingStyle.border, lineWidth: focus.wrappedValue == .note ? 2 : 1)
            )
            .focused(focus, equals: .note)
            .onSubmit(save)
            .onChange(of: draft) { old, new in
                // The note belongs to the moment the user started writing it.
                if old.isEmpty, !new.isEmpty, anchor == nil { anchor = currentAnchor() }
                if new.isEmpty, prints.isEmpty { anchor = nil }
            }
            .accessibilityLabel(placeholder)
    }

    private var placeholder: String {
        if isRecording { return "Anotar agora… #acao · @Nome = quem está falando" }
        if player.hasPosition { return "Anotar em \(Format.clock(ms: player.positionSecond * 1000))…" }
        return "Anotar no fim da reunião…"
    }

    @ViewBuilder
    private var saveButton: some View {
        let button = Button(saveLabel, action: save)
            .disabled(!hasDraft)
            .help("Salvar a nota (↩)")
            .controlSize(.large)
        if hasDraft {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// "Salvar em 10:55" when the note goes to a moment of the player.
    private var saveLabel: String {
        if isRecording { return "Salvar" }
        switch anchor {
        case .ms(let ms): return "Salvar em \(Format.clock(ms: ms))"
        case .date, .end: return "Salvar"
        case nil: return player.hasPosition ? "Salvar em \(Format.clock(ms: player.positionSecond * 1000))" : "Salvar"
        }
    }

    private func currentAnchor() -> NoteAnchor {
        if isRecording { return .date(Date()) }
        return player.hasPosition ? .ms(player.positionMs) : .end
    }

    private func save() {
        guard hasDraft, let id = meeting.id else { return }
        // The meeting being recorded as the app knows it now: its audio
        // may have started after this screen last read it.
        let meeting = state.activeMeeting?.id == id ? state.activeMeeting ?? meeting : meeting
        let tMs = switch anchor ?? currentAnchor() {
        case .date(let date): meeting.audioOffsetMs(at: date)
        case .ms(let ms): ms
        case .end: meeting.audioOffsetMs(at: meeting.endedAt ?? Date())
        }
        state.addNote(draft, meetingId: id, atMs: tMs, attachments: prints.map(\.url))
        draft = ""
        prints = []
        anchor = nil
        problem = nil
    }

    // MARK: - Prints

    private var printMenu: some View {
        Menu {
            Button("Escolher área") { capture(.area, label: "Print da seleção") }
            Button("Tela inteira") { capture(.display(ScreenCapture.displayUnderMouse()), label: "Print da tela") }
            if let app = previousApp.app {
                Divider()
                Button("Janela do \(app.name)") { captureWindow(of: app) }
            }
        } label: {
            Image(systemName: "camera")
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
        .disabled(capturing)
        .help("Anexar um print à nota (o Kuroneko não aparece nele)")
        .accessibilityLabel("Anexar print")
    }

    private func captureWindow(of app: PreviousApp.App) {
        guard let window = ScreenCapture.frontWindow(pid: app.pid) else {
            problem = .message("A janela do \(app.name) não está mais na tela.")
            return
        }
        capture(.window(window.id), label: "Print da janela · \(app.name)")
    }

    private func capture(_ target: ScreenCapture.Target, label: String) {
        guard ScreenCapture.hasPermission || ScreenCapture.requestPermission() else {
            problem = .permission
            return
        }
        // The moment the print was asked for, not when the area was chosen.
        let moment = anchor ?? currentAnchor()
        capturing = true
        Task {
            defer { capturing = false }
            do {
                // Kuroneko stays out of its own prints even with the shield
                // off for screen sharing; the sweep puts the setting back.
                for window in NSApp.windows {
                    window.sharingType = .none
                }
                defer { CaptureShield.sweep() }
                guard let url = try await ScreenCapture.capture(target) else { return }
                let size = await Task.detached(priority: .utility) { Thumbnails.pixelSize(of: url) }.value
                prints.append(DraftPrint(url: url, label: [label, size].compactMap { $0 }.joined(separator: " · ")))
                if anchor == nil { anchor = moment }
                problem = nil
            } catch {
                Self.logger.error("Falha ao tirar o print: \(String(describing: error))")
                problem = .message("Não deu para tirar o print: \(error)")
            }
        }
    }

    private func printChip(_ print: DraftPrint) -> some View {
        HStack(spacing: 8) {
            PrintThumbnail(url: print.url, width: 40, height: 26)
            Text(print.label)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                remove(print)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Tirar o print da nota")
            .accessibilityLabel("Tirar o print da nota")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(MeetingStyle.noteChipFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(MeetingStyle.noteBorder))
    }

    private func remove(_ print: DraftPrint) {
        prints.removeAll { $0.id == print.id }
        if prints.isEmpty, draft.isEmpty { anchor = nil }
        do {
            try FileManager.default.removeItem(at: print.url)
        } catch {
            Self.logger.error("Falha ao apagar o print descartado: \(String(describing: error))")
        }
    }

    @ViewBuilder
    private func problemView(_ problem: CaptureProblem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            switch problem {
            case .permission:
                Text("Para tirar prints, permita o Kuroneko em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Abrir") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            case .message(let text):
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                self.problem = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Fechar o aviso")
        }
        .font(.callout)
    }

    private static let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MeetingScreen")
}

/// Where a note being written goes in the meeting.
private enum NoteAnchor: Equatable {
    /// During the call: when the user started writing.
    case date(Date)
    /// A moment of the player.
    case ms(Int)
    /// After the call, without having listened: the end of the meeting.
    case end
}

private enum CaptureProblem: Equatable {
    case permission
    case message(String)
}

private struct DraftPrint: Identifiable, Equatable {
    var url: URL
    /// "Print da seleção · 1280 × 720".
    var label: String
    var id: URL { url }
}

// MARK: - Player

/// The meeting as a line: where it is, the notes in yellow; a click or a
/// drag goes there.
private struct Scrubber: View {
    let player: MeetingPlayer
    let marks: [Int]
    @State private var dragMs: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let position = dragMs ?? player.positionMs
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, width * fraction(position)), height: 4)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, ms in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MeetingStyle.mark)
                        .frame(width: 3, height: 14)
                        .offset(x: width * fraction(ms) - 1.5)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.3)))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction(position) - 6)
            }
            .frame(width: width, height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragMs = ms(at: value.location.x, width: width) }
                    .onEnded { value in
                        player.seek(toMs: ms(at: value.location.x, width: width))
                        dragMs = nil
                    }
            )
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Posição")
        .accessibilityValue("\(Format.clock(ms: player.positionMs)) de \(Format.clock(ms: player.durationMs))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(by: MeetingPlayer.skipMs)
            case .decrement: player.skip(by: -MeetingPlayer.skipMs)
            @unknown default: break
            }
        }
    }

    private func fraction(_ ms: Int) -> CGFloat {
        guard player.durationMs > 0 else { return 0 }
        return min(1, max(0, CGFloat(ms) / CGFloat(player.durationMs)))
    }

    private func ms(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int(min(1, max(0, x / width)) * CGFloat(player.durationMs))
    }
}

/// −15 s, play or pause, +15 s, where it is and the speed.
private struct Transport: View {
    let player: MeetingPlayer
    let onUserPlay: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                player.skip(by: -MeetingPlayer.skipMs)
            } label: {
                Image(systemName: "gobackward.15").font(.system(size: 17))
            }
            .help("Voltar 15 segundos (←)")
            .accessibilityLabel("Voltar 15 segundos")
            Button {
                if !player.isPlaying { onUserPlay() }
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pausar (espaço)" : "Ouvir (espaço)")
            .accessibilityLabel(player.isPlaying ? "Pausar" : "Ouvir")
            Button {
                player.skip(by: MeetingPlayer.skipMs)
            } label: {
                Image(systemName: "goforward.15").font(.system(size: 17))
            }
            .help("Avançar 15 segundos (→)")
            .accessibilityLabel("Avançar 15 segundos")
            Text("\(Format.clock(ms: player.positionSecond * 1000)) / \(Format.clock(ms: player.durationMs))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(MeetingPlayer.rates, id: \.self) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if rate == player.rate {
                            Label(Self.text(rate), systemImage: "checkmark")
                        } else {
                            Text(Self.text(rate))
                        }
                    }
                }
            } label: {
                Text(Self.text(player.rate)).monospacedDigit()
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Velocidade")
        }
        .buttonStyle(.borderless)
    }

    /// "1×", "1,25×".
    static func text(_ rate: Float) -> String {
        String(format: "%g", rate).replacingOccurrences(of: ".", with: ",") + "×"
    }
}

/// The app the user was in before coming to Kuroneko, whose window a print
/// can take; Kuroneko's own windows never show in prints.
@MainActor
@Observable
final class PreviousApp {
    struct App: Equatable {
        var pid: pid_t
        var name: String
    }

    static let shared = PreviousApp()

    private(set) var app: App?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        app = Self.appBehind()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = running?.processIdentifier
            let name = running?.localizedName
            MainActor.assumeIsolated { self?.activated(pid: pid, name: name) }
        }
    }

    private func activated(pid: pid_t?, name: String?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        app = App(pid: pid, name: name ?? "app")
    }

    /// Before any switch was seen: the app of the frontmost ordinary window
    /// that is not Kuroneko's.
    private static func appBehind() -> App? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let window = ScreenCapture.windows().first(where: { window in
            window.pid != own && window.layer == 0 && window.alpha > 0
                && window.bounds.width >= 50 && window.bounds.height >= 50
        }) else { return nil }
        let name = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? window.appName
        return App(pid: window.pid, name: name ?? "app")
    }
}
