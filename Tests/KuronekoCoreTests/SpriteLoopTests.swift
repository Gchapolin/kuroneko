import Testing
@testable import KuronekoCore

@Suite struct SpriteLoopTests {
    private let loop = SpriteLoop(frameCount: 4, fps: 2)

    @Test func stepsOneFramePerTick() {
        #expect(loop.frame(at: 0) == 0)
        #expect(loop.frame(at: 0.49) == 0)
        #expect(loop.frame(at: 0.5) == 1)
        #expect(loop.frame(at: 1.6) == 3)
    }

    @Test func wrapsAround() {
        #expect(loop.frame(at: 2) == 0)
        #expect(loop.frame(at: 1000.75) == 1)
    }

    @Test func survivesOddInput() {
        #expect(loop.frame(at: -0.5) == 0)
        #expect(SpriteLoop(frameCount: 0, fps: 15).frame(at: 3) == 0)
    }
}
