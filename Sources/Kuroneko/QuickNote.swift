import AppKit
import Carbon.HIToolbox
import ImageIO
import KuronekoCore
import Observation
import os
import SwiftUI

/// The quick note HUD: a floating field to jot a note during a call without
/// leaving it, opened with ⌘⌘ (or ⌃⌥⌘N) from any app. It takes the keyboard
/// without activating Kuroneko, so the app of the call stays in front; the
/// note is stamped with the moment it opened, and ⌘1/⌘2/⌘3 attach prints of
/// that app's window, the screen or an area.
@MainActor
final class QuickNoteController {
    static let shared = QuickNoteController()
    static let width: CGFloat = 540

    private var panel: QuickNotePanel?
    private var model: QuickNoteModel?
    private var keyMonitor: Any?
    private var selectionHint: NSPanel?

    func toggle(state: AppState) {
        if panel != nil {
            close()
        } else {
            show(state: state)
        }
    }

    func show(state: AppState) {
        if let panel, let model {
            // Already open: what was typed and the prints stay.
            if !model.isSelectingArea { panel.makeKeyAndOrderFront(nil) }
            return
        }
        let model = QuickNoteModel(state: state, frontApp: NSWorkspace.shared.frontmostApplication)
        model.setHidden = { [weak self] hidden, selectingArea in
            self?.setHidden(hidden, selectingArea: selectingArea)
        }
        model.close = { [weak self] in self?.close() }
        let panel = QuickNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: QuickNoteView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.layoutIfNeeded()
        place(panel)
        CaptureShield.protect(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.model = model
        startKeyMonitor()
    }

    func close() {
        model?.discard()
        stopKeyMonitor()
        hideSelectionHint()
        panel?.contentViewController = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Centered near the top of the screen the pointer is on.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 80 - size.height))
    }

    /// Out of the way while a print is taken; for an area, a hint says how
    /// the selection works.
    private func setHidden(_ hidden: Bool, selectingArea: Bool) {
        guard let panel else { return }
        if hidden {
            let screen = panel.screen
            panel.orderOut(nil)
            if selectingArea { showSelectionHint(on: screen) }
        } else {
            hideSelectionHint()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func showSelectionHint(on screen: NSScreen?) {
        // With the shield off it would end up in the print.
        guard model?.state.hiddenFromScreenCapture == true, let screen = screen ?? NSScreen.main else { return }
        let hint = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // Above macOS's selection, and transparent to the drag.
        hint.level = .screenSaver
        hint.ignoresMouseEvents = true
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = true
        hint.hidesOnDeactivate = false
        hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: AreaSelectionHint())
        host.sizingOptions = [.preferredContentSize]
        hint.contentViewController = host
        hint.layoutIfNeeded()
        let visible = screen.visibleFrame, size = hint.frame.size
        hint.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 22 - size.height))
        CaptureShield.protect(hint)
        hint.orderFrontRegardless()
        selectionHint = hint
    }

    private func hideSelectionHint() {
        selectionHint?.orderOut(nil)
        selectionHint = nil
    }

    // MARK: - Keyboard

    /// The HUD's shortcuts work while typing: they are caught before the
    /// text field sees them.
    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, let model, event.window === panel else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        // ↩ and esc belong to the input method while it composes a letter.
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        if modifiers == .command, let source = NoteDraft.Print.Source.allCases.first(where: { $0.keyCode == keyCode }) {
            model.takePrint(source)
            return true
        }
        switch (keyCode, modifiers) {
        case (kVK_Delete, .command):
            // Without prints, ⌘⌫ deletes the line as usual.
            return model.removeLastPrint()
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            guard !composing else { return false }
            model.save()
            return true
        case (kVK_Escape, []):
            guard !composing else { return false }
            close()
            return true
        default:
            return false
        }
    }
}

final class QuickNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Prints and longer notes grow it downward, hanging from its top edge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if rect.origin == frame.origin, rect.height != frame.height {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }
}

/// What the HUD holds while it is open.
@MainActor
@Observable
final class QuickNoteModel {
    enum Problem: Equatable {
        case screenRecordingDenied
        case noWindow(app: String?)
        case failed
    }

    let state: AppState
    /// The note belongs to the moment the HUD opened, not to the moment it
    /// was finished typing.
    let startedAt = Date()
    var text = ""
    private(set) var draft = NoteDraft()
    private(set) var thumbnails: [UUID: NSImage] = [:]
    /// Why the last print didn't come, shown under the field.
    private(set) var problem: Problem?
    private(set) var isCapturing = false
    private(set) var isSelectingArea = false
    /// Bumped to put the cursor back in the field.
    private(set) var focusRequest = 0

    /// Hides the panel while a print is taken, and brings it back.
    @ObservationIgnored var setHidden: (_ hidden: Bool, _ selectingArea: Bool) -> Void = { _, _ in }
    @ObservationIgnored var close: () -> Void = {}

    /// The meeting being recorded when it opened: if the call ends while
    /// the note is being written, the note still goes there.
    private let openedMeeting: Meeting?
    /// The app in front when the HUD opened — the one the user was looking
    /// at, since the HUD doesn't activate Kuroneko: ⌘1 prints its window.
    private let frontApp: (pid: pid_t, name: String?)?
    @ObservationIgnored private var isClosed = false
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "QuickNote")

    private static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    init(state: AppState, frontApp: NSRunningApplication?) {
        self.state = state
        openedMeeting = state.activeMeeting
        self.frontApp = frontApp.map { ($0.processIdentifier, $0.localizedName) }
    }

    /// As recorded now: its audio may have started after the HUD opened.
    var meeting: Meeting? {
        guard let openedMeeting else { return nil }
        if let active = state.activeMeeting, active.id == openedMeeting.id { return active }
        return openedMeeting
    }

    var isRecording: Bool {
        openedMeeting != nil && state.activeMeeting?.id == openedMeeting?.id
    }

    func takePrint(_ source: NoteDraft.Print.Source) {
        guard openedMeeting != nil, !isCapturing else { return }
        guard ScreenCapture.hasPermission else {
            // macOS asks the first time; after that only System Settings.
            ScreenCapture.requestPermission()
            problem = .screenRecordingDenied
            return
        }
        let target: ScreenCapture.Target
        var app: String?
        switch source {
        case .window:
            // Kuroneko's own windows never show up in prints.
            let other = frontApp.flatMap { $0.pid == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
            guard let other, let window = ScreenCapture.frontWindow(pid: other.pid, in: ScreenCapture.windows()) else {
                problem = .noWindow(app: other?.name)
                return
            }
            target = .window(window.id)
            app = other.name ?? window.appName
        case .screen:
            target = .display(ScreenCapture.displayUnderMouse())
        case .area:
            target = .area
        }
        problem = nil
        isCapturing = true
        isSelectingArea = source == .area
        // The area is dragged on a screen without the HUD; the whole screen
        // is taken without it too when the shield is off.
        let hides = source == .area || (source == .screen && !state.hiddenFromScreenCapture)
        if hides { setHidden(true, source == .area) }
        Task {
            var taken: URL?
            do {
                // nil: esc in the area selection, back to the note.
                taken = try await ScreenCapture.capture(target)
            } catch {
                logger.error("Falha ao tirar o print: \(String(describing: error))")
                FileLog.shared.append("nota: print (\(source)) FALHOU: \(error)")
                problem = .failed
            }
            isCapturing = false
            isSelectingArea = false
            guard !isClosed else {
                // Closed meanwhile (⌘⌘ during the selection).
                if let taken { try? FileManager.default.removeItem(at: taken) }
                return
            }
            if hides { setHidden(false, false) }
            if let taken {
                let print = NoteDraft.Print(url: taken, source: source, app: app)
                draft.add(print)
                thumbnails[print.id] = Self.thumbnail(of: taken)
            }
            focusRequest += 1
        }
    }

    func remove(_ id: UUID) {
        draft.remove(id)
        thumbnails[id] = nil
    }

    /// ⌘⌫: false when there is no print to remove.
    func removeLastPrint() -> Bool {
        guard draft.removeLast() else { return false }
        thumbnails = thumbnails.filter { id, _ in draft.prints.contains { $0.id == id } }
        return true
    }

    func save() {
        guard !isCapturing else { return }
        guard let openedMeeting, let id = openedMeeting.id, draft.canSave(text: text) else {
            close()
            return
        }
        let files = draft.takeFiles()
        if state.activeMeeting?.id == id {
            state.addNoteToActiveMeeting(text, at: startedAt, attachments: files)
        } else {
            // The call ended while the note was being written.
            let meeting = (try? state.db.meeting(id: id)) ?? openedMeeting
            state.addNote(text, meetingId: id, atMs: meeting.audioOffsetMs(at: startedAt), attachments: files)
        }
        close()
    }

    /// Closing without saving: the prints go away.
    func discard() {
        isClosed = true
        draft.discard()
        thumbnails = [:]
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(Self.screenRecordingPane)
    }

    private static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 400,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

private extension NoteDraft.Print.Source {
    var buttonTitle: String {
        switch self {
        case .window: "Print da janela"
        case .screen: "Tela inteira"
        case .area: "Escolher área"
        }
    }

    /// ⌘ plus the digit; the key code keeps it on the same key in any
    /// keyboard layout.
    var keyCode: Int {
        switch self {
        case .window: kVK_ANSI_1
        case .screen: kVK_ANSI_2
        case .area: kVK_ANSI_3
        }
    }

    var shortcut: String {
        switch self {
        case .window: "⌘1"
        case .screen: "⌘2"
        case .area: "⌘3"
        }
    }
}

struct QuickNoteView: View {
    @Bindable var model: QuickNoteModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let meeting = model.meeting {
                note(meeting)
            } else {
                Text("Nenhuma reunião gravando agora.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(width: QuickNoteController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
    }

    private func note(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(meeting)
            ForEach(model.draft.prints) { print in
                printRow(print, isLatest: print.id == model.draft.prints.last?.id)
            }
            TextField("Anotar… #acao · @Nome = quem está falando", text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .lineLimit(1...5)
                .focused($focused)
                .padding(.vertical, 4)
            if let problem = model.problem {
                problemRow(problem)
            }
            footer
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? Color.red : Color.secondary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(meeting.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("às \(Format.time(model.startedAt)) · \(Format.clock(ms: meeting.audioOffsetMs(at: model.startedAt)))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("A nota fica neste momento da reunião, mesmo que você demore para escrever")
        }
        .font(.callout)
    }

    private func printRow(_ print: NoteDraft.Print, isLatest: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = model.thumbnails[print.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 78)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(print.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(details(of: print))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(isLatest ? "Remover (⌘⌫)" : "Remover") {
                    model.remove(print.id)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
    }

    /// "1440 × 900 · o Kuroneko não aparece no print".
    private func details(of print: NoteDraft.Print) -> String {
        let shielded = model.state.hiddenFromScreenCapture ? "o Kuroneko não aparece no print" : nil
        return [print.sizeText, shielded].compactMap { $0 }.joined(separator: " · ")
    }

    private func problemRow(_ problem: QuickNoteModel.Problem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            switch problem {
            case .screenRecordingDenied:
                Text("Os prints precisam da permissão de Gravação de Tela.")
                Button("Abrir Ajustes do Sistema") {
                    model.openScreenRecordingSettings()
                }
                .buttonStyle(.link)
            case .noWindow(let app):
                Text(app.map { "\($0) não tem janela aberta para o print." } ?? "Nenhuma janela para o print.")
            case .failed:
                Text("Não deu para tirar o print. Tente de novo.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(NoteDraft.Print.Source.allCases, id: \.self) { source in
                Button {
                    model.takePrint(source)
                } label: {
                    HStack(spacing: 6) {
                        KeyCap(keys: source.shortcut)
                        Text(source.buttonTitle)
                    }
                }
                .buttonStyle(ShortcutButtonStyle(isOn: model.draft.prints.contains { $0.source == source }))
                .disabled(model.isCapturing)
                .fixedSize()
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                Text(saveHint)
                Text("↩ salvar")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private var saveHint: String {
        switch model.draft.prints.count {
        case 0: "↩ salvar · esc fechar"
        case 1: "↩ salvar nota + print"
        default: "↩ salvar nota + prints"
        }
    }
}

/// A key as printed on the keyboard, inside the HUD's buttons.
private struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.subheadline)
            .padding(.horizontal, 4)
            .background(.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }
}

/// The print buttons; one lights up once that kind of print is attached.
private struct ShortcutButtonStyle: ButtonStyle {
    var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.callout)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isOn ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(configuration.isPressed ? 1 : 0.5)),
                in: shape
            )
            .overlay(shape.strokeBorder(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
    }
}

/// Over the screen while the area is dragged, with the HUD hidden.
private struct AreaSelectionHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Arraste para escolher a área · a nota volta em seguida · esc volta sem print")
        }
        .font(.callout)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}
