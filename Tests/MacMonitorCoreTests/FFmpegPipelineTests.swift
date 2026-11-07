import Darwin
import Foundation
import XCTest
@testable import MacMonitorCore

final class FFmpegPipelineTests: XCTestCase {
    private func teeTarget(recordingEnabled: Bool) throws -> String {
        let pipeline = FFmpegPipeline(configuration: FFmpegPipelineConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            spoolDirectory: URL(fileURLWithPath: "/tmp/spool"),
            rtspPublishURL: try XCTUnwrap(URL(string: "rtsp://127.0.0.1:8554/live")),
            logURL: URL(fileURLWithPath: "/tmp/ffmpeg.log"),
            recordingEnabled: recordingEnabled
        ))
        return try XCTUnwrap(pipeline.arguments().last)
    }

    func testLiveOnlyPublishesTheStreamAndWritesNothingToTheSpool() throws {
        let target = try teeTarget(recordingEnabled: false)
        XCTAssertTrue(target.contains("rtsp://127.0.0.1:8554/live"))
        XCTAssertFalse(target.contains("f=segment"))
        XCTAssertFalse(target.contains("/tmp/spool"))
        XCTAssertFalse(target.contains("|"))
    }

    func testRecordingPublishesTheStreamAndWritesSegments() throws {
        let target = try teeTarget(recordingEnabled: true)
        XCTAssertTrue(target.contains("rtsp://127.0.0.1:8554/live"))
        XCTAssertTrue(target.contains("f=segment"))
        XCTAssertTrue(target.contains("/tmp/spool/segment-"))
    }

    func testClosedEncoderPipeReportsEPIPEInsteadOfTerminatingMonitoring() throws {
        let pipe = try FFmpegPipeline.makeInputPipe()
        defer { try? pipe.fileHandleForWriting.close() }
        // Check before writing so a broken implementation cannot kill the test runner.
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1 else {
            XCTFail("encoder input must suppress SIGPIPE on its own file descriptor")
            return
        }
        try pipe.fileHandleForReading.close()
        var byte: UInt8 = 0
        let result = Darwin.write(pipe.fileHandleForWriting.fileDescriptor, &byte, 1)
        let code = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(code, EPIPE)
    }
}
