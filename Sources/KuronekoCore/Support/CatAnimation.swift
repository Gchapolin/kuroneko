import Foundation

/// The typing cat's two loops: resting while the call is quiet, typing
/// while someone talks. Both loops start and end on the same resting pose,
/// so typing starts at once and stops only at the end of its loop.
public struct CatAnimation: Sendable {
    public enum Clip: Sendable { case idle, typing }

    public let idleCount: Int
    public let typingCount: Int
    public private(set) var clip = Clip.idle
    public private(set) var frame = 0

    public init(idleCount: Int, typingCount: Int) {
        self.idleCount = idleCount
        self.typingCount = typingCount
    }

    /// One frame tick.
    public mutating func advance(speaking: Bool) {
        guard idleCount > 0, typingCount > 0 else { return }
        frame += 1
        switch clip {
        case .idle:
            if speaking {
                clip = .typing
                frame = 0
            } else {
                frame %= idleCount
            }
        case .typing:
            if frame >= typingCount {
                frame = 0
                if !speaking { clip = .idle }
            }
        }
    }
}
