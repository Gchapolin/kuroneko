import Foundation
import ImageIO

/// The prints of a quick note still being written. They wait in a
/// temporary folder until the note is saved (`AppDatabase.addNote` moves
/// them into the meeting) or dropped, which deletes them.
public struct NoteDraft: Sendable {
    public struct Print: Identifiable, Equatable, Sendable {
        public enum Source: CaseIterable, Sendable {
            /// The front window of the app the user was in.
            case window
            /// The whole display under the mouse.
            case screen
            /// A rectangle the user dragged.
            case area
        }

        public let id: UUID
        public let url: URL
        public let source: Source
        /// The app whose window it is.
        public let app: String?
        /// In pixels, as the PNG was saved; nil when it can't be read.
        public let width: Int?
        public let height: Int?

        public init(url: URL, source: Source, app: String? = nil, id: UUID = UUID()) {
            self.id = id
            self.url = url
            self.source = source
            self.app = app
            let size = Self.pixelSize(of: url)
            width = size?.width
            height = size?.height
        }

        public var title: String {
            switch source {
            case .window: app.map { "Print da janela · \($0)" } ?? "Print da janela"
            case .screen: "Tela inteira"
            case .area: "Área"
            }
        }

        /// "1440 × 900".
        public var sizeText: String? {
            guard let width, let height else { return nil }
            return "\(width) × \(height)"
        }

        static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
            return (width, height)
        }
    }

    /// In the order they were taken.
    public private(set) var prints: [Print] = []

    public init() {}

    public mutating func add(_ print: Print) {
        prints.append(print)
    }

    /// Takes the print out of the note and deletes its file.
    public mutating func remove(_ id: UUID) {
        guard let index = prints.firstIndex(where: { $0.id == id }) else { return }
        Self.delete(prints.remove(at: index))
    }

    /// ⌘⌫: the latest print; false when there is none.
    @discardableResult
    public mutating func removeLast() -> Bool {
        guard let last = prints.last else { return false }
        remove(last.id)
        return true
    }

    /// Whether ↩ has anything to save: a print is enough without text.
    public func canSave(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !prints.isEmpty
    }

    /// The files to save with the note; from here on they are the
    /// database's, and dropping the draft leaves them alone.
    public mutating func takeFiles() -> [URL] {
        defer { prints = [] }
        return prints.map(\.url)
    }

    /// Closing without saving: every print goes away.
    public mutating func discard() {
        prints.forEach(Self.delete)
        prints = []
    }

    /// A temporary file; failing to delete it costs nothing but disk until
    /// the system cleans the folder.
    private static func delete(_ print: Print) {
        try? FileManager.default.removeItem(at: print.url)
    }
}
