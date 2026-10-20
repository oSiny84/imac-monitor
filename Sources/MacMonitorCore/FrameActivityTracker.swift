import Foundation

/// Monotonic arrival tracking. Identical images are valid frames; a quiet room
/// must never be treated as a stalled camera.
struct FrameActivityTracker {
    let firstFrameTimeout: TimeInterval
    let frameTimeout: TimeInterval
    private(set) var isActive = false
    private(set) var frames: UInt64 = 0
    private var beganAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval?
    private var fired = false
    private var sampleAt: TimeInterval = 0
    private var sampleFrames: UInt64 = 0
    private var lastFPS: Double = 0

    init(firstFrameTimeout: TimeInterval = 15, frameTimeout: TimeInterval = 10) {
        self.firstFrameTimeout = firstFrameTimeout
        self.frameTimeout = frameTimeout
    }

    mutating func start(at uptime: TimeInterval) {
        isActive = true
        beganAt = uptime
        sampleAt = uptime
        frames = 0
        sampleFrames = 0
        lastFrameAt = nil
        fired = false
        lastFPS = 0
    }

    mutating func stop() { isActive = false; lastFPS = 0 }

    mutating func recordFrame(at uptime: TimeInterval) {
        guard isActive else { return }
        frames += 1
        sampleFrames += 1
        lastFrameAt = uptime
    }

    mutating func takeFPS(at uptime: TimeInterval) -> Double {
        guard isActive else { return 0 }
        guard uptime - sampleAt >= 1 else { return lastFPS }
        lastFPS = Double(sampleFrames) / (uptime - sampleAt)
        sampleFrames = 0
        sampleAt = uptime
        return lastFPS
    }

    mutating func takeStall(at uptime: TimeInterval) -> Bool {
        guard isActive, !fired else { return false }
        let deadline = lastFrameAt.map { $0 + frameTimeout } ?? (beganAt + firstFrameTimeout)
        guard uptime >= deadline else { return false }
        fired = true
        return true
    }
}
