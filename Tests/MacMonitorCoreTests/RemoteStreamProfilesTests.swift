import XCTest
import Foundation
import Darwin
@testable import MacMonitorCore

final class RemoteStreamProfilesTests: XCTestCase {
    func testProfilesAreOnDemandLoopbackOnlyWithoutRecordingOutputs() throws {
        let paths = try RemoteStreamProfiles.paths(ffmpegURL: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        XCTAssertTrue(paths.contains("live-balanced:"))
        XCTAssertTrue(paths.contains("live-low:"))
        XCTAssertTrue(paths.contains("fps=10,scale=854:480"))
        XCTAssertTrue(paths.contains("fps=8,scale=640:360"))
        XCTAssertEqual(paths.components(separatedBy: "runOnDemandCloseAfter: 5s").count - 1, 2)
        XCTAssertTrue(paths.contains("127.0.0.1:8554/live"))
        XCTAssertFalse(paths.contains("segment-"))
        XCTAssertFalse(paths.contains("tee"))
        XCTAssertFalse(paths.contains("0.0.0.0"))
    }
    func testExecutablePathsAreQuotedAndLineBreaksRejected() throws {
        let paths = try RemoteStreamProfiles.paths(ffmpegURL: URL(fileURLWithPath: "/Applications/O'Brien Camera/ffmpeg"))
        let line = try XCTUnwrap(paths.components(separatedBy: "\n").first { $0.contains("runOnDemand:") })
        let range = try XCTUnwrap(line.range(of: "runOnDemand: "))
        let scalar = String(line[range.upperBound...])
        let command = try JSONDecoder().decode(String.self, from: Data(scalar.utf8))
        XCTAssertTrue(command.contains("O'\\''Brien Camera"))
        XCTAssertTrue(paths.contains("runOnDemand:"))
        XCTAssertThrowsError(try RemoteStreamProfiles.paths(ffmpegURL: URL(fileURLWithPath: "/tmp/bad\nffmpeg")))
    }

    func testGeneratedConfigurationWithPinnedMediaMTXValidatorWhenAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("vendor/mediamtx/mediamtx")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Run the pinned MediaMTX fetch script before this integration test.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try MediaMTXSupervisor.configuration(additionalHosts: ["camera.example"], ffmpegURL: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        XCTAssertTrue(configuration.contains("webrtcICEServers2: []"))
        let file = directory.appendingPathComponent("mediamtx.yml")
        try Data(configuration.utf8).write(to: file)
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--validate-conf=" + file.path]
        process.standardOutput = output; process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 1) }
            XCTFail("MediaMTX configuration validation timed out"); return
        }
        let log = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, log)
    }
}
