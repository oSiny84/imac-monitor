import XCTest
@testable import MacMonitorCore

final class FrameActivityTrackerTests: XCTestCase {
    func testFirstFrameGraceAndOnlyOneRecoveryPerRun() {
        var tracker = FrameActivityTracker()
        tracker.start(at: 100)
        XCTAssertFalse(tracker.takeStall(at: 114.9))
        XCTAssertTrue(tracker.takeStall(at: 115))
        XCTAssertFalse(tracker.takeStall(at: 130))
        tracker.start(at: 200)
        XCTAssertTrue(tracker.takeStall(at: 215))
    }

    func testReceivingFramesAndThenStallingUsesActualArrivalTime() {
        var tracker = FrameActivityTracker()
        tracker.start(at: 100)
        for index in 1...30 { tracker.recordFrame(at: 100 + Double(index) / 15) }
        XCTAssertEqual(tracker.takeFPS(at: 102), 15, accuracy: 0.001)
        XCTAssertEqual(tracker.frames, 30)
        XCTAssertFalse(tracker.takeStall(at: 111.9))
        XCTAssertTrue(tracker.takeStall(at: 112))
    }

    func testManualStopRestAndRecoveryNeverRequireFrames() {
        var tracker = FrameActivityTracker()
        XCTAssertFalse(tracker.takeStall(at: 1000))
        tracker.start(at: 100)
        tracker.recordFrame(at: 101)
        tracker.stop()
        XCTAssertFalse(tracker.takeStall(at: 1000))
        XCTAssertEqual(tracker.takeFPS(at: 1000), 0)
        tracker.start(at: 2000)
        XCTAssertEqual(tracker.frames, 0)
        XCTAssertFalse(tracker.takeStall(at: 2014))
    }
}
