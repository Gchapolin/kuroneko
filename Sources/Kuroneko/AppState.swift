import Foundation
import KuronekoCore
import Observation
import os
import ServiceManagement

@MainActor
@Observable
final class AppState {
    private(set) var activeMeeting: Meeting?
    private(set) var isRecording = false
    private(set) var systemSource: CaptureEngine.SystemSource?
    private(set) var isMicRecording = false
    private(set) var lastError: String?
    private(set) var autoRecord: Bool
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var extraVocabulary: String
    private(set) var hiddenFromScreenCapture: Bool
    /// Bumped whenever stored data changes; views reload on it.
    private(set) var dataVersion = 0

    let db: AppDatabase
    let storage: MeetingStorage
    let processing: ProcessingQueue
    private let capture = CaptureEngine()
    private var policy = AutoRecordPolicy()
    private var voicePrompts = VoicePromptSchedule()
    @ObservationIgnored private var voicePromptHandler: (Int64?) -> Void = { _ in }
    @ObservationIgnored private var promptedMeetingId: Int64?
    @ObservationIgnored private var externalChanges: NSObjectProtocol?
    private let tabReader = ChromeTabReader()
    private var lastChromeState: String?
    private var lastTabError: ChromeTabsError?
    private var monitor: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "AppState")

    private static let autoRecordKey = "autoRecord"
    private static let hiddenFromScreenCaptureKey = "hiddenFromScreenCapture"
    nonisolated static let vocabularyKey = "extraVocabulary"

    init(db: AppDatabase, storage: MeetingStorage) {
        self.db = db
        self.storage = storage
        autoRecord = UserDefaults.standard.object(forKey: Self.autoRecordKey) as? Bool ?? true
        extraVocabulary = UserDefaults.standard.string(forKey: Self.vocabularyKey) ?? ""
        hiddenFromScreenCapture = UserDefaults.standard.object(forKey: Self.hiddenFromScreenCaptureKey) as? Bool ?? true
        let processor = MeetingProcessor(
            db: db,
            engines: .live(modelsDirectory: storage.root.appendingPathComponent("models", isDirectory: true)),
            extraVocabulary: {
                (UserDefaults.standard.string(forKey: AppState.vocabularyKey) ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
        processing = ProcessingQueue(db: db, processor: processor)
        processing.isBusyRecording = { [weak self] in self?.isMeetingActive ?? false }
        processing.onChange = { [weak self] in self?.dataVersion += 1 }
        processing.onTranscribed = { [weak self] id in self?.askAboutVoices(of: id) }
        capture.onLateMicStart = { [weak self] url in
            Task { @MainActor in self?.lateMicStarted(url) }
        }
        // Names, notes and summaries changed through the `kuroneko` command.
        externalChanges = DistributedNotificationCenter.default().addObserver(
            forName: ExternalChange.notification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dataChangedElsewhere() }
        }
        closeStaleMeeting()
        startMonitor()
        processing.kick()
    }

    static let shared = AppState.live()

    static func live() -> AppState {
        let storage = MeetingStorage.standard()
        do {
            return AppState(db: try AppDatabase.open(at: storage.databaseURL), storage: storage)
        } catch {
            fatalError("Não foi possível abrir o banco em \(storage.databaseURL.path): \(error)")
        }
    }

    var isMeetingActive: Bool {
        activeMeeting != nil
    }

    var startedAutomatically: Bool {
        policy.ownsActiveMeeting
    }

    func startMeeting() {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        beginMeeting(title: "Reunião · \(stamp)", source: "manual")
    }

    func endActiveMeeting() {
        policy.userEndedMeeting()
        finishActiveMeeting()
    }

    /// A note on the meeting being recorded, placed at `date`: when the
    /// user started writing it, closest to what prompted it.
    func addNoteToActiveMeeting(_ text: String, at date: Date) {
        guard let meeting = activeMeeting, let id = meeting.id else { return }
        addNote(text, meetingId: id, atMs: meeting.audioOffsetMs(at: date))
    }

    func addNote(_ text: String, meetingId: Int64, atMs tMs: Int) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        perform("salvar a nota") { try db.addNote(meetingId: meetingId, tMs: tMs, text: text) }
    }

    func deleteNote(_ id: Int64) {
        perform("apagar a nota") { try db.deleteNote(id) }
    }

    func renameMeeting(_ id: Int64, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        perform("renomear a reunião") {
            try db.renameMeeting(id, title: title)
            if activeMeeting?.id == id {
                activeMeeting = try db.meeting(id: id)
            }
        }
    }

    func nameSpeaker(meetingId: Int64, diarCluster: Int, as name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform("nomear a voz") {
            try db.assignSpeaker(meetingId: meetingId, diarCluster: diarCluster, personName: name)
        }
        settleVoicePrompt(meetingId)
    }

    func retranscribe(_ meetingId: Int64) {
        perform("transcrever de novo") { try db.setStatus(.recorded, meetingId: meetingId) }
        processing.kick()
    }

    func deleteMeeting(_ id: Int64) {
        perform("apagar a reunião") {
            try db.deleteMeeting(id)
            try? FileManager.default.removeItem(at: storage.meetingDirectory(id: id))
        }
        voicePrompts.remove(id)
        updateVoicePrompt()
    }

    // MARK: - Who was speaking?

    var hasVoicesToName: Bool {
        !voicePrompts.meetingIds.isEmpty
    }

    /// Shows (a meeting id) or hides (nil) the "who was speaking?" prompt.
    func onVoicePrompt(_ handler: @escaping (Int64?) -> Void) {
        voicePromptHandler = handler
        promptedMeetingId = nil
        updateVoicePrompt()
    }

    func voicesToName(meetingId: Int64) -> [PendingVoice] {
        let voices = (try? db.pendingVoices(meetingId: meetingId)) ?? []
        return voices.filter { !voicePrompts.isSkipped(meetingId: meetingId, diarCluster: $0.diarCluster) }
    }

    func skipVoice(meetingId: Int64, diarCluster: Int) {
        voicePrompts.skip(meetingId: meetingId, diarCluster: diarCluster)
        dataVersion += 1
        settleVoicePrompt(meetingId)
    }

    func dismissVoicePrompt(_ reason: String) {
        FileLog.shared.append("vozes: cartão fechado (\(reason))")
        voicePrompts.dismiss()
        updateVoicePrompt()
    }

    func showVoicePromptNow() {
        voicePrompts.resume()
        updateVoicePrompt()
    }

    private func dataChangedElsewhere() {
        dataVersion += 1
        for meetingId in voicePrompts.meetingIds {
            settleVoicePrompt(meetingId)
        }
    }

    private func askAboutVoices(of meetingId: Int64) {
        let voices = voicesToName(meetingId: meetingId)
        FileLog.shared.append("vozes: reunião \(meetingId) tem \(voices.count) sem nome")
        guard !voices.isEmpty else { return }
        voicePrompts.add(meetingId)
        updateVoicePrompt()
    }

    /// Done with a meeting once every voice is named or skipped, wherever
    /// that happened (the prompt or the meeting window).
    private func settleVoicePrompt(_ meetingId: Int64) {
        guard voicePrompts.meetingIds.contains(meetingId), voicesToName(meetingId: meetingId).isEmpty else { return }
        voicePrompts.remove(meetingId)
        updateVoicePrompt()
    }

    private func updateVoicePrompt() {
        let due = voicePrompts.due(inCall: isMeetingActive)
        guard due != promptedMeetingId else { return }
        FileLog.shared.append("vozes: pergunta \(due.map { "da reunião \($0)" } ?? "escondida")")
        promptedMeetingId = due
        voicePromptHandler(due)
    }

    func setAutoRecord(_ enabled: Bool) {
        autoRecord = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoRecordKey)
    }

    func setHiddenFromScreenCapture(_ hidden: Bool) {
        hiddenFromScreenCapture = hidden
        UserDefaults.standard.set(hidden, forKey: Self.hiddenFromScreenCaptureKey)
    }

    func setExtraVocabulary(_ text: String) {
        extraVocabulary = text
        UserDefaults.standard.set(text, forKey: Self.vocabularyKey)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            report(error, while: enabled ? "ativar abertura no login" : "desativar abertura no login")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func perform(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
            dataVersion += 1
        } catch {
            report(error, while: action)
        }
    }

    // MARK: - Meetings

    private func beginMeeting(title: String, source: String) {
        do {
            let meeting = try db.startMeeting(title: title, source: source)
            activeMeeting = meeting
            lastError = nil
            dataVersion += 1
            startRecording(meetingId: meeting.id!)
        } catch {
            report(error, while: "iniciar reunião")
        }
    }

    private func finishActiveMeeting() {
        guard let id = activeMeeting?.id else { return }
        stopRecording()
        do {
            try db.endMeeting(id)
            activeMeeting = nil
            lastError = nil
            dataVersion += 1
            processing.kick()
        } catch {
            report(error, while: "encerrar reunião")
        }
    }

    /// A meeting still open at launch means the app died mid-recording; the
    /// recording cannot resume, and leaving it open would block auto-start.
    private func closeStaleMeeting() {
        do {
            guard let stale = try db.activeMeeting(), let id = stale.id else { return }
            let endedAt = storage.lastAudioWrite(meetingId: id) ?? stale.startedAt
            try db.endMeeting(id, at: endedAt)
            FileLog.shared.append("launch: reunião \(id) aberta de uma execução anterior foi encerrada")
        } catch {
            report(error, while: "encerrar reunião anterior")
        }
    }

    // MARK: - Auto-record

    private func startMonitor() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollChrome()
                self?.updateVoicePrompt()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollChrome() {
        guard autoRecord else { return }
        let meetTab = readMeetTab()
        let activity = AudioProcessFinder.chromeActivity()
        // Logged on change: the raw signals behind every start/stop decision.
        let chromeState = "meet=\(meetTab.map { "\($0.url) \"\($0.title)\"" } ?? "-") saída=\(activity.output) mic=\(activity.input)"
        if chromeState != lastChromeState {
            FileLog.shared.append("chrome: \(chromeState)")
            lastChromeState = chromeState
        }

        // The room URL and title survive leaving the call ("you left" page);
        // what stops is Chrome's audio output, which WebRTC keeps running
        // for the whole call, even in silence.
        let inCall = meetTab != nil && activity.output
        switch policy.observe(inCall: inCall, meetingActive: isMeetingActive, at: Date()) {
        case .start:
            FileLog.shared.append("auto: iniciando reunião")
            let stamp = Date().formatted(date: .abbreviated, time: .shortened)
            let title = meetTab.flatMap { MeetDetector.meetingTitle(fromTabTitle: $0.title) } ?? "Reunião"
            beginMeeting(title: "\(title) · \(stamp)", source: "meet")
        case .stop:
            FileLog.shared.append("auto: encerrando reunião")
            finishActiveMeeting()
        case nil:
            break
        }
    }

    private func readMeetTab() -> BrowserTab? {
        do {
            let tab = MeetDetector.meetTab(in: try tabReader.readTabs())
            lastTabError = nil
            return tab
        } catch let error as ChromeTabsError {
            if error != lastTabError {
                FileLog.shared.append("chrome: falha ao ler abas: \(error)")
                logger.error("Falha ao ler abas do Chrome: \(String(describing: error))")
                lastError = error == .notPermitted
                    ? "Sem permissão para ver as abas do Chrome — habilite em Ajustes > Privacidade > Automação"
                    : "Falha ao ler as abas do Chrome"
                lastTabError = error
            }
            return nil
        } catch {
            report(error, while: "ler as abas do Chrome")
            return nil
        }
    }

    // MARK: - Recording

    private func startRecording(meetingId: Int64) {
        Task {
            do {
                let paths = try await capture.start(in: storage.meetingDirectory(id: meetingId))
                try db.updateAudio(
                    meetingId: meetingId,
                    startedAt: paths.startedAt,
                    micPath: paths.mic?.path,
                    systemPath: paths.system.path
                )
                activeMeeting = try db.meeting(id: meetingId)
                isRecording = true
                systemSource = capture.systemSource
                isMicRecording = capture.isMicRecording
            } catch CaptureError.tapCreationFailed(let status) {
                logger.error("Tap de áudio do sistema falhou: \(status)")
                lastError = "Permissão de gravação do áudio do sistema negada ou indisponível"
            } catch {
                FileLog.shared.append("recording.start FALHOU: \(error)")
                report(error, while: "iniciar gravação")
            }
        }
    }

    private func lateMicStarted(_ url: URL) {
        guard let id = activeMeeting?.id else { return }
        do {
            try db.updateMicPath(meetingId: id, micPath: url.path)
            isMicRecording = true
        } catch {
            report(error, while: "registrar o microfone")
        }
    }

    private func stopRecording() {
        capture.stop()
        isRecording = false
        systemSource = nil
        isMicRecording = false
    }

    private func report(_ error: Error, while action: String) {
        logger.error("Falha ao \(action): \(error)")
        lastError = "Falha ao \(action)"
    }
}
