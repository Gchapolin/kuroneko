import AppKit
import KuronekoCore
import Observation
import SwiftUI

/// Floating "who was speaking?" card that pops up in the corner as soon as a
/// transcription finishes with unnamed voices, and goes away by itself like
/// a notification. It does not take the keyboard until clicked, so it never
/// steals what is being typed elsewhere.
@MainActor
final class VoicePromptController {
    static let shared = VoicePromptController()
    static let width: CGFloat = 380

    private var panel: VoicePromptPanel?
    private var meetingId: Int64?

    func update(meetingId: Int64?, state: AppState) {
        guard meetingId != self.meetingId else { return }
        close()
        guard let meetingId else { return }
        let panel = VoicePromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
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
        let host = NSHostingController(rootView: VoicePromptView(state: state, meetingId: meetingId, focus: panel.focus))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.layoutIfNeeded()
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
        }
        CaptureShield.protect(panel)
        panel.orderFrontRegardless()
        FileLog.shared.append("vozes: cartão da reunião \(meetingId) em \(panel.frame)")
        self.panel = panel
        self.meetingId = meetingId
    }

    private func close() {
        // Dropping the content first stops any sample still playing.
        panel?.contentViewController = nil
        panel?.orderOut(nil)
        panel = nil
        meetingId = nil
    }
}

/// Whether the card has the keyboard (the user clicked into it).
@MainActor
@Observable
final class PanelFocus {
    var isKey = false
}

final class VoicePromptPanel: NSPanel {
    let focus = PanelFocus()

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        focus.isKey = true
    }

    override func resignKey() {
        super.resignKey()
        focus.isKey = false
    }

    /// The card grows and shrinks as voices are named; it stays hanging
    /// from its top edge instead of from the bottom.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.origin == frame.origin, rect.height != frame.height {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }
}

struct VoicePromptView: View {
    let state: AppState
    let meetingId: Int64
    let focus: PanelFocus

    @State private var meeting: Meeting?
    @State private var voices: [PendingVoice] = []
    @State private var player = MeetingPlayer()
    @State private var playing: Int?
    @State private var hovering = false
    @State private var deadline: Date?

    /// Seconds the card stays up untouched.
    private static let countdown: TimeInterval = 10
    /// A few at a time; the rest come up as these are answered.
    private static let maxShown = 3

    /// Pointer over it, typing in it or listening to a voice holds it up.
    private var isEngaged: Bool {
        hovering || focus.isKey || playing != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voices.count == 1 ? "Quem é essa voz?" : "Quem são essas vozes?").font(.headline)
                    Text(meeting?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    state.dismissVoicePrompt("botão")
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Fechar; dá para responder depois pelo menu do gato ou na reunião")
            }
            ForEach(voices.prefix(Self.maxShown), id: \.diarCluster) { voice in
                card(voice)
            }
            if voices.count > Self.maxShown {
                Text("Mais \(voices.count - Self.maxShown) depois dessas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            countdownBar
        }
        .padding(16)
        .frame(width: VoicePromptController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .onHover { hovering = $0 }
        .onChange(of: isEngaged, initial: true) {
            deadline = isEngaged ? nil : Date().addingTimeInterval(Self.countdown)
        }
        .task(id: deadline) {
            guard let deadline else { return }
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            if !Task.isCancelled { state.dismissVoicePrompt("sem resposta em \(Int(Self.countdown))s") }
        }
        .task(id: state.dataVersion) { reload() }
        .onChange(of: player.isPlaying) { if !player.isPlaying { playing = nil } }
        .onDisappear { player.stop() }
    }

    /// Empties over the countdown; full while the card is held up.
    private var countdownBar: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: deadline == nil)) { context in
            let remaining = deadline.map { max(0, $0.timeIntervalSince(context.date) / Self.countdown) } ?? 1
            GeometryReader { geometry in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.secondary).frame(width: geometry.size.width * remaining)
                    }
            }
            .frame(height: 3)
        }
    }

    private func card(_ voice: PendingVoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(SpeakerStyle.color(for: "c\(voice.diarCluster)")).frame(width: 10, height: 10)
                Text("Pessoa \(voice.diarCluster + 1)").bold()
                Text("\(Format.clock(ms: voice.speechMs)) de fala").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let sample = voice.sample, player.hasAudio {
                    let isPlaying = playing == voice.diarCluster
                    Button {
                        toggleSample(sample, of: voice.diarCluster)
                    } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .help("Ouvir um trecho dessa voz")
                }
                Button("Não sei") {
                    state.skipVoice(meetingId: meetingId, diarCluster: voice.diarCluster)
                }
                .help("Não perguntar mais sobre essa voz")
            }
            VoiceNamer(candidates: voice.candidates) { name in
                if playing == voice.diarCluster { player.pause() }
                state.nameSpeaker(meetingId: meetingId, diarCluster: voice.diarCluster, as: name)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggleSample(_ sample: VoiceSample, of cluster: Int) {
        if playing == cluster {
            player.pause()
            playing = nil
        } else {
            player.play(fromMs: sample.startMs, stopAfterMs: sample.durationMs)
            playing = cluster
        }
    }

    private func reload() {
        let loaded = try? state.db.meeting(id: meetingId)
        if let loaded, meeting?.audioSystemPath != loaded.audioSystemPath || meeting?.audioMicPath != loaded.audioMicPath {
            player.load(loaded)
        }
        meeting = loaded
        voices = state.voicesToName(meetingId: meetingId)
    }
}
