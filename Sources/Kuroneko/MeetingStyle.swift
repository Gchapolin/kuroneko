import AppKit
import ImageIO
import KuronekoCore
import SwiftUI

/// Colors and small pieces shared by the parts of the meeting screen.
enum MeetingStyle {
    static let content = Color(nsColor: .textBackgroundColor)
    static let bar = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let chipFill = Color.primary.opacity(0.06)

    static let noteFill = dynamic(light: (0xFFF4D1, 1), dark: (0xFFD60A, 0.13))
    static let noteChipFill = dynamic(light: (0xFFFAEA, 1), dark: (0xFFD60A, 0.08))
    static let noteBorder = dynamic(light: (0xE0CF98, 1), dark: (0xFFD60A, 0.35))
    static let noteInk = dynamic(light: (0x9A6B00, 1), dark: (0xFFD60A, 0.9))
    static let noteMeta = dynamic(light: (0x6B5300, 1), dark: (0xE8C766, 1))
    /// Notes on the scrubber.
    static let mark = dynamic(light: (0xD49B00, 1), dark: (0xFFD60A, 1))
    static let decision = dynamic(light: (0x1E7F3A, 1), dark: (0x4CC26E, 1))
    static let recording = dynamic(light: (0xA31D15, 1), dark: (0xFF6961, 1))
    static let recordingBorder = dynamic(light: (0xF4C7C2, 1), dark: (0xFF6961, 0.45))
    /// Find: every occurrence, and the one being looked at.
    static let found = dynamic(light: (0xFFE066, 1), dark: (0xFFD60A, 0.35))
    static let foundCurrent = dynamic(light: (0xFF9F0A, 1), dark: (0xFF9F0A, 0.75))

    static func dynamic(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (hex, alpha) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }

    /// "Pendências · 3", "Transcrição".
    static func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Which text field of the meeting screen has the keyboard.
enum MeetingField: Hashable {
    case note, find, title, link
}

/// "▶ 12:31": plays the meeting from there.
struct PlayTimeButton: View {
    let ms: Int
    let canPlay: Bool
    var help: String?
    let onPlay: (Int) -> Void

    var body: some View {
        if canPlay {
            Button {
                onPlay(ms)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(Format.clock(ms: ms))
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help ?? "Ouvir a partir de \(Format.clock(ms: ms))")
            .accessibilityLabel("Ouvir a partir de \(Format.clock(ms: ms))")
        } else {
            Text(Format.clock(ms: ms))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// A person (round) or a link (rounded rectangle) in the header; dashed
/// for what is still to be filled in.
struct MeetingChip: ViewModifier {
    var fill: Color = MeetingStyle.chipFill
    var dashed = false
    var rounded = false

    func body(content: Content) -> some View {
        // A radius beyond half the height makes a capsule.
        let shape = RoundedRectangle(cornerRadius: rounded ? 6 : 100, style: .continuous)
        content
            .font(.callout)
            .padding(.horizontal, rounded ? 9 : 10)
            .padding(.vertical, 4)
            .background(dashed ? Color.clear : fill, in: shape)
            .overlay {
                if dashed {
                    shape.strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(shape)
    }
}

struct MeetingChipStyle: ButtonStyle {
    var fill: Color = MeetingStyle.chipFill
    var dashed = false
    var rounded = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(MeetingChip(fill: fill, dashed: dashed, rounded: rounded))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A bordered card with one row per item, as in Pendências and Decisões.
struct RowsCard<Item, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider()
                }
                row(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MeetingStyle.border))
    }
}

// MARK: - Voices

struct NamingTarget: Equatable {
    var cluster: Int
    /// Which control opened it: a chip or one transcript block.
    var anchor: String
}

/// Says who a voice is: the known people closest voice first, a new name,
/// and a few seconds of the voice to hear before choosing.
struct NameVoicePopover: View {
    let candidates: [PendingVoice.Candidate]
    let current: String?
    let onPlaySample: (() -> Void)?
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(current == nil ? "Quem é essa voz?" : "Corrigir nome").font(.headline)
                Spacer()
                if let onPlaySample {
                    Button(action: onPlaySample) {
                        Label("Ouvir", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Ouvir um trecho dessa voz")
                }
            }
            VoiceNamer(candidates: candidates, current: current, onChoose: onChoose)
            Text("Vozes mais parecidas primeiro. Nas próximas reuniões essa voz é reconhecida sozinha.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Prints

/// A print of a note, small; a click opens it in the default app.
struct PrintThumbnail: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            ZStack {
                Color.primary.opacity(0.05)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MeetingStyle.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Abrir o print")
        .accessibilityLabel("Abrir o print")
        .contextMenu {
            Button("Abrir") { NSWorkspace.shared.open(url) }
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task(id: url) {
            image = await Thumbnails.image(for: url, maxPixels: Int(max(width, height) * 2))
        }
    }
}

/// Small versions of the prints, made off the main thread (a print of a
/// Retina screen is several megabytes) and kept while the app runs.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    private struct Picture: @unchecked Sendable {
        let image: CGImage
    }

    static func image(for url: URL, maxPixels: Int) async -> NSImage? {
        let key = "\(url.path)#\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let picture = await Task.detached(priority: .utility) { () -> Picture? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Picture.init)
        }.value
        guard let picture else { return nil }
        let image = NSImage(cgImage: picture.image, size: NSSize(width: picture.image.width / 2, height: picture.image.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Width and height in pixels: "1280 × 720".
    nonisolated static func pixelSize(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}

// MARK: - Keyboard

/// What the keyboard does on the meeting screen.
enum MeetingKey {
    case togglePlay
    case skip(Int)
    case focusNote
    case find
    case findNext
    case findPrevious
    case escape
}

/// Space and the arrows play the meeting when nothing is being typed; ⌘N,
/// ⌘F and ⌘G work anywhere in the window. A local monitor, because those
/// keys must not reach the text fields as shortcuts would.
@MainActor
final class MeetingKeyMonitor {
    weak var window: NSWindow?
    /// True when the key was used.
    var handle: (MeetingKey, _ typing: Bool) -> Bool = { _, _ in false }
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.process(event) ?? false }
            return used ? nil : event
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }

    private func process(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        let typing = (window.firstResponder as? NSTextView)?.isEditable == true
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let command: MeetingKey?
        switch (event.keyCode, modifiers) {
        case (49, []) where !typing: command = .togglePlay
        case (123, []) where !typing: command = .skip(-MeetingPlayer.skipMs)
        case (124, []) where !typing: command = .skip(MeetingPlayer.skipMs)
        case (53, []): command = .escape
        case (36, [.shift]) where typing: command = .findPrevious
        case (_, [.command]) where key == "n": command = .focusNote
        case (_, [.command]) where key == "f": command = .find
        case (_, [.command]) where key == "g": command = .findNext
        case (_, [.command, .shift]) where key == "g": command = .findPrevious
        default: command = nil
        }
        guard let command else { return false }
        return handle(command, typing)
    }
}

/// Hands over the window a view is in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
