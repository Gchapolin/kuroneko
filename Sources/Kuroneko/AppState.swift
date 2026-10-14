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

    let db: AppDatabase
    private let storage: MeetingStorage
    private let capture = CaptureEngine()
    private var policy = AutoRecordPolicy()
    private let tabReader = ChromeTabReader()
    private var lastChromeState: String?
    private var lastTabError: ChromeTabsError?
    private var monitor: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "AppState")

    private static let autoRecordKey = "autoRecord"

    init(db: AppDatabase, storage: MeetingStorage) {
        self.db = db
        self.storage = storage
        autoRecord = UserDefaults.standard.object(forKey: Self.autoRecordKey) as? Bool ?? true
        closeStaleMeeting()
        startMonitor()
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

    func startMeeting(kind: MeetingKind) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        beginMeeting(title: "\(kind.label) \(stamp)", kind: kind)
    }

    func endActiveMeeting() {
        policy.userEndedMeeting()
        finishActiveMeeting()
    }

    func setAutoRecord(_ enabled: Bool) {
        autoRecord = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoRecordKey)
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

    // MARK: - Meetings

    private func beginMeeting(title: String, kind: MeetingKind) {
        do {
            let meeting = try db.startMeeting(title: title, kind: kind)
            activeMeeting = meeting
            lastError = nil
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
            beginMeeting(title: "\(title) · \(stamp)", kind: .outro)
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
                try db.updateAudioPaths(
                    meetingId: meetingId,
                    micPath: paths.mic?.path,
                    systemPath: paths.system.path
                )
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
