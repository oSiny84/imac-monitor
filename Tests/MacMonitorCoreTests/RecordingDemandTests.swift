import Foundation
import XCTest
@testable import MacMonitorCore

final class RecordingDemandTests: XCTestCase {
    private let wire = #"{"schemaVersion":1,"until":"2026-11-08T13:00:00Z","hours":4,"requestedAt":"2026-11-08T09:00:00Z"}"#

    func testTheGatewayFileDecodesWithoutFractionalSecondsAndEndsAtItsTime() throws {
        let demand = try XCTUnwrap(RecordingDemand.decode(Data(wire.utf8)))
        XCTAssertEqual(demand.until, Date(timeIntervalSince1970: 1_794_142_800))
        XCTAssertEqual(demand.hours, 4)
        XCTAssertTrue(demand.isActive(at: demand.until.addingTimeInterval(-1)))
        XCTAssertFalse(demand.isActive(at: demand.until), "the end time itself is no longer recording")
    }

    func testAWrongFileNeverStartsTheCamera() {
        XCTAssertNil(RecordingDemand.decode(Data("not json".utf8)))
        XCTAssertNil(RecordingDemand.decode(Data(wire.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)))
        XCTAssertNil(RecordingDemand.decode(Data(wire.replacingOccurrences(of: "\"hours\":4", with: "\"hours\":0").utf8)))
        XCTAssertNil(RecordingDemand.decode(Data(wire.replacingOccurrences(of: "\"hours\":4", with: "\"hours\":25").utf8)))
        XCTAssertNil(RecordingDemand.decode(Data(wire.replacingOccurrences(of: "2026-11-08T13:00:00Z", with: "tomorrow").utf8)))
        XCTAssertNil(RecordingDemand.read(from: URL(fileURLWithPath: "/nonexistent/recording-demand.json")))
    }

    func testTheMonitorReportsARequestWhileItLastsAndClearingItFromTheMac() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("recording-demand.json")
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))

        let monitor = RecordingDemandMonitor(fileURL: file, pollInterval: 0.05)
        let started = expectation(description: "request seen")
        let ended = expectation(description: "request gone")
        var reports: [RecordingDemand?] = []
        monitor.onChange = { demand in
            reports.append(demand)
            if demand != nil { started.fulfill() } else { ended.fulfill() }
        }
        // An expired request left in the file is not a request.
        try Data(#"{"schemaVersion":1,"until":"\#(past)","hours":2}"#.utf8).write(to: file)
        monitor.start()
        try Data(#"{"schemaVersion":1,"until":"\#(future)","hours":2}"#.utf8).write(to: file)
        wait(for: [started], timeout: 5)
        XCTAssertEqual(reports.first.flatMap { $0 }?.hours, 2)

        try monitor.cancel()
        wait(for: [ended], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "cancelling from the Mac removes the gateway's file")
        XCTAssertNoThrow(try RecordingDemand.clear(at: file), "clearing an already missing request is not an error")
        monitor.stop()
    }
}
