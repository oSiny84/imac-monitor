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
    func testExecutablePathIsOnlyPassedInEnvironmentWithoutReparsing() throws {
        for path in ["/usr/local/bin/ffmpeg", "/Applications/O'Brien Camera/ffmpeg", "/Applications/$HOME ${USER} $$ Camera/ffmpeg", "/Applications/한글 \\\" Camera/ffmpeg"] {
            let url = URL(fileURLWithPath: path)
            let paths = try RemoteStreamProfiles.paths(ffmpegURL: url)
            let lines = paths.components(separatedBy: "\n").filter { $0.contains("runOnDemand:") }
            XCTAssertEqual(lines.count, 2)
            for line in lines {
                let range = try XCTUnwrap(line.range(of: "runOnDemand: "))
                let scalar = String(line[range.upperBound...])
                let command = try JSONDecoder().decode(String.self, from: Data(scalar.utf8))
                XCTAssertTrue(command.hasPrefix("'${\(RemoteStreamProfiles.ffmpegEnvironmentKey)}' "))
                XCTAssertFalse(command.contains(path))
            }
            let environment = try RemoteStreamProfiles.environment(ffmpegURL: url, inheriting: ["PATH": "/usr/bin", RemoteStreamProfiles.ffmpegEnvironmentKey: "wrong"])
            XCTAssertEqual(environment[RemoteStreamProfiles.ffmpegEnvironmentKey], url.path)
            XCTAssertEqual(environment["PATH"], "/usr/bin")
        }
    }

    func testExecutablePathControlCharactersAreRejectedForConfigAndEnvironment() {
        for character in ["\n", "\r", "\0"] {
            let url = URL(fileURLWithPath: "/tmp/bad\(character)ffmpeg")
            XCTAssertThrowsError(try RemoteStreamProfiles.paths(ffmpegURL: url))
            XCTAssertThrowsError(try RemoteStreamProfiles.environment(ffmpegURL: url, inheriting: [:]))
        }
    }

    func testProcessEnvironmentPreservesSpecialExecutablePathLiterally() throws {
        let url = URL(fileURLWithPath: "/Applications/O'Brien $HOME ${USER} \\\" Camera/ffmpeg")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printenv")
        process.arguments = [RemoteStreamProfiles.ffmpegEnvironmentKey]
        process.environment = try RemoteStreamProfiles.environment(ffmpegURL: url, inheriting: ProcessInfo.processInfo.environment)
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(value, url.path + "\n")
    }

    func testPinnedMediaMTXActuallyExecutesSpecialCharacterExecutablePathWhenAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("vendor/mediamtx/mediamtx")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Run the pinned MediaMTX fetch script before this integration test.") }
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let specialDirectory = directory.appendingPathComponent("O'Brien $HOME ${USER} 한글 Camera", isDirectory: true)
        try files.createDirectory(at: specialDirectory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let fakeFFmpeg = specialDirectory.appendingPathComponent("ffmpeg")
        try files.createSymbolicLink(at: fakeFFmpeg, withDestinationURL: URL(fileURLWithPath: "/usr/bin/touch"))

        // Reuse the actual generated executable token, not a separately rebuilt
        // approximation. runOnInit uses the same externalcmd runner as runOnDemand.
        let paths = try RemoteStreamProfiles.paths(ffmpegURL: fakeFFmpeg)
        let line = try XCTUnwrap(paths.components(separatedBy: "\n").first { $0.contains("runOnDemand:") })
        let range = try XCTUnwrap(line.range(of: "runOnDemand: "))
        let command = try JSONDecoder().decode(String.self, from: Data(line[range.upperBound...].utf8))
        let executableToken = try XCTUnwrap(command.split(separator: " ", maxSplits: 1).first)
        let markerKey = "MACMONITOR_TEST_MARKER"
        let marker = directory.appendingPathComponent("invoked")
        let probeCommand = "\(executableToken) '${\(markerKey)}'"
        let quotedCommand = try XCTUnwrap(String(data: JSONEncoder().encode(probeCommand), encoding: .utf8))
        let configuration = """
        logLevel: error
        logDestinations: [stdout]
        api: false
        metrics: false
        pprof: false
        playback: false
        rtsp: false
        rtmp: false
        hls: false
        webrtc: false
        srt: false
        moq: false
        paths:
          probe:
            source: publisher
            runOnInit: \(quotedCommand)
        """
        let file = directory.appendingPathComponent("mediamtx.yml")
        try Data(configuration.utf8).write(to: file)
        let logFile = directory.appendingPathComponent("mediamtx.log")
        XCTAssertTrue(files.createFile(atPath: logFile.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: logFile)
        defer { try? logHandle.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = [file.path]
        var environment = try RemoteStreamProfiles.environment(ffmpegURL: fakeFFmpeg, inheriting: ProcessInfo.processInfo.environment)
        environment[markerKey] = marker.path
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        func stopProcess() {
            guard process.isRunning else { return }
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        defer { stopProcess() }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, !files.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let invoked = files.fileExists(atPath: marker.path)
        stopProcess()
        let log = String(data: try Data(contentsOf: logFile), encoding: .utf8) ?? ""
        XCTAssertTrue(invoked, "MediaMTX did not execute the exact special-character executable path: \(log)")
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
