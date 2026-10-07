import XCTest
@testable import MacMonitorCore

final class ConstantRateFramePacerTests: XCTestCase {
    // Polls are offset off the exact frame boundary on purpose. Real timers never land on it,
    // and 1/15 is not representable in binary, so polling exactly on n/15 would make these
    // assertions depend on which side of the boundary the rounding error falls.
    private let pollOffset = 0.001

    func testSteadyCaptureEmitsOneFramePerIntervalWithoutBursting() {
        var pacer = ConstantRateFramePacer(framesPerSecond: 15)
        var emitted = 0
        var largestBurst = 0

        for step in 0...150 {
            let due = pacer.framesDue(at: Double(step) / 15 + pollOffset)
            largestBurst = max(largestBurst, due)
            emitted += due
        }

        XCTAssertEqual(Double(emitted) / 15, 10, accuracy: 0.1, "151 polls span 10 seconds")
        XCTAssertLessThanOrEqual(largestBurst, 2, "steady capture must not need catch-up bursts")
        XCTAssertEqual(pacer.resynchronisationCount, 0)
    }

    func testNoFrameIsDueBeforeTheIntervalElapses() {
        var pacer = ConstantRateFramePacer(framesPerSecond: 15)

        XCTAssertEqual(pacer.framesDue(at: 100), 1)
        XCTAssertEqual(pacer.framesDue(at: 100.06), 0, "1/15 has not elapsed yet")
        XCTAssertEqual(pacer.framesDue(at: 100.07), 1)
    }

    /// The regression this type exists for. The FFmpeg rawvideo input carries no timestamps, so
    /// one write per captured frame makes encoded content shorter than the wall-clock time it
    /// covers: a camera managing only 12fps produced 48 seconds of content per 60 seconds of
    /// monitoring, and the error accumulated for as long as monitoring ran.
    func testEmittedContentTracksWallClockWhenTheCameraRunsBelowItsNominalRate() {
        let framesPerSecond = 15
        var pacer = ConstantRateFramePacer(framesPerSecond: framesPerSecond)
        let monitoredSeconds = 60.0
        let cameraInterval = 1.0 / 12

        // Polling on the slow camera's cadence is the worst case: it is exactly the rate the
        // old code wrote at.
        var emitted = 0
        var uptime = 0.0
        while uptime <= monitoredSeconds {
            emitted += pacer.framesDue(at: uptime)
            uptime += cameraInterval
        }

        let framesTheCameraDelivered = Int((monitoredSeconds * 12).rounded(.down)) + 1
        let contentSeconds = Double(emitted) / Double(framesPerSecond)

        XCTAssertEqual(contentSeconds, monitoredSeconds, accuracy: 0.2)
        XCTAssertGreaterThan(
            emitted,
            framesTheCameraDelivered,
            "late frames must be repeated, not left as a hole in the timeline"
        )
        XCTAssertEqual(pacer.resynchronisationCount, 0)
    }

    func testCatchUpIsFilledInUpToTheBacklogLimit() {
        var pacer = ConstantRateFramePacer(framesPerSecond: 15, maximumBacklogSeconds: 2)

        XCTAssertEqual(pacer.framesDue(at: 0), 1)
        XCTAssertEqual(pacer.framesDue(at: 1), 15, "a one second gap is filled in")
        XCTAssertEqual(pacer.resynchronisationCount, 0)
    }

    func testAStallBeyondTheBacklogLimitResynchronisesInsteadOfBursting() {
        var pacer = ConstantRateFramePacer(framesPerSecond: 15, maximumBacklogSeconds: 2)
        XCTAssertEqual(pacer.framesDue(at: 0), 1)

        // Nothing was captured for a minute, so there is no timeline worth reconstructing.
        XCTAssertEqual(pacer.framesDue(at: 60), 1)
        XCTAssertEqual(pacer.resynchronisationCount, 1)

        // Pacing continues normally from the new baseline.
        XCTAssertEqual(pacer.framesDue(at: 60.07), 1)
        XCTAssertEqual(pacer.resynchronisationCount, 1)
    }

    func testResetStartsANewTimeline() {
        var pacer = ConstantRateFramePacer(framesPerSecond: 15)
        XCTAssertEqual(pacer.framesDue(at: 0), 1)
        XCTAssertEqual(pacer.framesDue(at: 1), 15)

        pacer.reset()

        XCTAssertEqual(pacer.framesDue(at: 500), 1)
        XCTAssertEqual(pacer.emittedFrameCount, 1)
    }

    func testAnInvalidFrameRateDoesNotDivideByZero() {
        var pacer = ConstantRateFramePacer(framesPerSecond: 0)

        XCTAssertEqual(pacer.framesPerSecond, 1)
        XCTAssertEqual(pacer.framesDue(at: 0), 1)
        XCTAssertEqual(pacer.framesDue(at: 1.5), 1)
    }
}
