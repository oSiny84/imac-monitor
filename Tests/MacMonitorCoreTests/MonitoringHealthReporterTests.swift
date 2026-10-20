import Foundation
import XCTest
@testable import MacMonitorCore

final class MonitoringHealthReporterTests: XCTestCase {
    func testPrivateSnapshotsDistinguishRestRunningAndStopAndRetainEventTimes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("Recordings")
        let status = root.appendingPathComponent("Runtime/monitoring-status.json")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let reporter = MonitoringHealthReporter(statusURL: status, recordingsDirectory: recordings)
        let info = CaptureRuntimeInfo(deviceName: "Test Camera", logURL: root.appendingPathComponent("capture.log"))
        reporter.start()
        reporter.setPauseReason(.scheduledRest)
        reporter.updateState(.running(info))
        waitForSnapshot(at: status) { $0["state"] as? String == "scheduledRest" && $0["expectingFrames"] as? Bool == false }

        reporter.setPauseReason(nil)
        reporter.recordFrame()
        reporter.recordMotion(at: Date())
        reporter.recordRecording(at: recordings.appendingPathComponent("motion-test.mp4"))
        reporter.updateState(.running(info)) // publish without resetting this session's frame counter
        waitForSnapshot(at: status) {
            $0["state"] as? String == "running" && $0["totalFrames"] as? Int == 1 &&
                $0["lastMotionAt"] != nil && $0["lastRecordingName"] as? String == "motion-test.mp4"
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: status.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let stopped = expectation(description: "health shutdown persisted")
        reporter.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
        waitForSnapshot(at: status) { $0["state"] as? String == "stopped" && $0["expectingFrames"] as? Bool == false }
    }

    private func waitForSnapshot(at url: URL, matching: @escaping ([String: Any]) -> Bool) {
        let predicate = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let value = object as? [String: Any] else { return false }
            return matching(value)
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        wait(for: [ready], timeout: 5)
    }
}
