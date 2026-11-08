import Foundation
import XCTest
@testable import MacMonitorCore

final class LiveDemandTests: XCTestCase {
    private let first = Data("first".utf8)
    private let second = Data("second".utf8)

    func testALeaseLeftFromAnEarlierRunDoesNotTurnTheCameraOn() {
        var lease = LiveDemandLease(duration: 20)
        XCTAssertFalse(lease.observe(content: first, at: 100))
        XCTAssertFalse(lease.observe(content: first, at: 101))
    }

    func testAChangedLeaseDemandsTheCameraUntilItExpires() {
        var lease = LiveDemandLease(duration: 20)
        XCTAssertFalse(lease.observe(content: first, at: 100))
        XCTAssertTrue(lease.observe(content: second, at: 101))
        XCTAssertTrue(lease.observe(content: second, at: 120.9))
        XCTAssertFalse(lease.observe(content: second, at: 121))
    }

    func testRenewalExtendsTheLease() {
        var lease = LiveDemandLease(duration: 20)
        XCTAssertFalse(lease.observe(content: first, at: 100))
        XCTAssertTrue(lease.observe(content: second, at: 101))
        XCTAssertTrue(lease.observe(content: first, at: 115))
        XCTAssertTrue(lease.observe(content: first, at: 134))
        XCTAssertFalse(lease.observe(content: first, at: 135))
    }

    func testTheFirstLeaseEverWrittenCountsWhenNoFileExistedAtStart() {
        var lease = LiveDemandLease(duration: 20)
        XCTAssertFalse(lease.observe(content: nil, at: 100))
        XCTAssertTrue(lease.observe(content: first, at: 101))
    }

    func testAnUnreadableLeaseDoesNotExtendOrCancelTheCurrentOne() {
        var lease = LiveDemandLease(duration: 20)
        XCTAssertFalse(lease.observe(content: first, at: 100))
        XCTAssertTrue(lease.observe(content: second, at: 101))
        XCTAssertTrue(lease.observe(content: nil, at: 110))
        XCTAssertFalse(lease.observe(content: nil, at: 121))
        XCTAssertFalse(lease.observe(content: second, at: 122), "the same content again is not a new viewer")
    }

    func testMonitorReportsAViewerArrivingAndLeaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("live-demand.json")
        try first.write(to: file)

        let monitor = LiveDemandMonitor(fileURL: file, leaseDuration: 0.5, pollInterval: 0.02)
        let arrived = expectation(description: "viewer arrived")
        let left = expectation(description: "viewer left")
        monitor.onChange = { demanded in
            if demanded { arrived.fulfill() } else { left.fulfill() }
        }
        monitor.start()
        // The first poll must take the leftover content as its baseline before it changes.
        Thread.sleep(forTimeInterval: 0.5)
        try second.write(to: file)
        wait(for: [arrived, left], timeout: 5, enforceOrder: true)
        monitor.stop()
    }

    func testStoppingTheMonitorEndsDemandImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("live-demand.json")
        try first.write(to: file)

        let monitor = LiveDemandMonitor(fileURL: file, leaseDuration: 60, pollInterval: 0.02)
        let arrived = expectation(description: "viewer arrived")
        let ended = expectation(description: "demand ended")
        monitor.onChange = { demanded in
            if demanded { arrived.fulfill() } else { ended.fulfill() }
        }
        monitor.start()
        Thread.sleep(forTimeInterval: 0.5)
        try second.write(to: file)
        wait(for: [arrived], timeout: 5)
        monitor.stop()
        wait(for: [ended], timeout: 5)
    }

    func testRecordingWinsAndServesViewersWhileLiveNeedsStandbyAndAViewer() {
        func mode(recording: Bool = false, scheduled: Bool = false, resting: Bool = false, sleeping: Bool = false,
                  standby: Bool = true, viewer: Bool = false) -> CaptureMode {
            CaptureModePolicy.desiredMode(recordingWanted: recording, scheduledRecording: scheduled, resting: resting,
                systemSleeping: sleeping, liveStandby: standby, liveDemanded: viewer)
        }
        XCTAssertEqual(mode(), .off, "no viewer means the camera stays off")
        XCTAssertEqual(mode(viewer: true), .live)
        XCTAssertEqual(mode(standby: false, viewer: true), .off, "standby off refuses remote camera start")
        XCTAssertEqual(mode(recording: true), .recording)
        XCTAssertEqual(mode(recording: true, viewer: true), .recording, "one capture serves both")
        XCTAssertEqual(mode(recording: true, resting: true), .off)
        XCTAssertEqual(mode(recording: true, resting: true, viewer: true), .live, "rest pauses recording, not an explicit viewer")
        XCTAssertEqual(mode(recording: true, sleeping: true, viewer: true), .off)
        XCTAssertEqual(mode(scheduled: true), .scheduled)
        XCTAssertEqual(mode(recording: true, scheduled: true), .scheduled, "continuous clips win over motion recording")
        XCTAssertEqual(mode(scheduled: true, viewer: true), .scheduled, "one capture serves the viewer too")
        XCTAssertEqual(mode(scheduled: true, resting: true), .off, "the daily rest pauses scheduled recording like motion recording")
        XCTAssertEqual(mode(scheduled: true, resting: true, viewer: true), .live)
        XCTAssertEqual(mode(scheduled: true, sleeping: true), .off)
    }

    func testLiveOnlyStatusSaysNothingIsBeingRecorded() {
        let info = CaptureRuntimeInfo(deviceName: "Test Camera", logURL: URL(fileURLWithPath: "/tmp/capture.log"))
        XCTAssertEqual(MonitoringState.running(info).displayText(for: .recording), "움직임 녹화 중 — Test Camera")
        XCTAssertEqual(MonitoringState.running(info).displayText(for: .live), "원격 시청 중 — Test Camera · 녹화 안 함")
        XCTAssertEqual(MonitoringState.running(info).displayText(for: .scheduled), "예약 녹화 중 — Test Camera")
        XCTAssertEqual(MonitoringState.starting.displayText(for: .scheduled), "예약 녹화 준비 중 — 카메라를 켜는 중")
        XCTAssertTrue(CaptureMode.scheduled.writesRecordings)
        XCTAssertFalse(CaptureMode.live.writesRecordings)
        XCTAssertEqual(MonitoringState.idle.displayText(for: .live), MonitoringState.idle.displayText)
    }

    func testAFailedCaptureIsRetriedOnlyWhileAViewerWaits() {
        func retry(state: MonitoringState = .failed("camera busy"), viewer: Bool = true, requested: Bool = true,
                   stopping: Bool = false, elapsed: TimeInterval = 30) -> Bool {
            CaptureModePolicy.shouldRetryFailedCapture(state: state, viewerWaiting: viewer, captureRequested: requested,
                stopping: stopping, secondsSinceFailure: elapsed)
        }
        XCTAssertTrue(retry(), "a waiting viewer restarts a failed capture; recording wins the mode, so this covers recording too")
        XCTAssertFalse(retry(viewer: false), "without a viewer a failed capture waits for a manual restart as before")
        XCTAssertFalse(retry(elapsed: 29.9))
        XCTAssertFalse(retry(stopping: true), "a stop in flight finishes first")
        XCTAssertFalse(retry(requested: false), "nothing to retry when no capture was requested")
        XCTAssertFalse(retry(state: .recovering(attempt: 1, maximum: 3, delaySeconds: 2)), "automatic recovery is still running")
        XCTAssertFalse(retry(state: .idle))
    }
}
