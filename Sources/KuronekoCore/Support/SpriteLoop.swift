import Foundation

/// Which frame of a looping animation is on screen at a given time.
public struct SpriteLoop: Sendable {
    public let frameCount: Int
    public let fps: Double

    public init(frameCount: Int, fps: Double) {
        self.frameCount = frameCount
        self.fps = fps
    }

    public func frame(at seconds: TimeInterval) -> Int {
        guard frameCount > 0, seconds > 0 else { return 0 }
        return Int((seconds * fps).rounded(.down)) % frameCount
    }
}
