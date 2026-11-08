import Darwin
import Foundation
import XCTest
@testable import MacMonitorCore

final class FFmpegPipelineTests: XCTestCase {
    private func pipeline(recordingEnabled: Bool, segmentSeconds: Int = 5, prefix: String = "segment",
                          audio: FFmpegAudioConfiguration? = nil) throws -> FFmpegPipeline {
        FFmpegPipeline(configuration: FFmpegPipelineConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            spoolDirectory: URL(fileURLWithPath: "/tmp/spool"),
            rtspPublishURL: try XCTUnwrap(URL(string: "rtsp://127.0.0.1:8554/live")),
            logURL: URL(fileURLWithPath: "/tmp/ffmpeg.log"),
            segmentSeconds: segmentSeconds,
            segmentFilePrefix: prefix,
            recordingEnabled: recordingEnabled,
            audio: audio
        ))
    }

    private func teeTarget(recordingEnabled: Bool, segmentSeconds: Int = 5, prefix: String = "segment") throws -> String {
        try XCTUnwrap(pipeline(recordingEnabled: recordingEnabled, segmentSeconds: segmentSeconds, prefix: prefix).arguments().last)
    }

    func testSoundIsReadFromANamedPipeAndEncodedOnceForEachOutput() throws {
        let arguments = try pipeline(recordingEnabled: true, audio: FFmpegAudioConfiguration()).arguments(audioInput: "/tmp/runtime/audio.pcm")
        let joined = arguments.joined(separator: " ")
        XCTAssertTrue(joined.contains("-i pipe:0 -f s16le -ar 48000 -ac 1 -i /tmp/runtime/audio.pcm"), "video first, then the raw PCM pipe")
        XCTAssertTrue(joined.contains("-map 0:v:0 -map 1:a:0 -c:a:0 libopus -b:a:0 48k -map 1:a:0 -c:a:1 aac -b:a:1 64k"))
        XCTAssertFalse(arguments.contains("-an"))
        let target = try XCTUnwrap(arguments.last)
        XCTAssertTrue(target.contains("onfail=abort:select='v:0,a:0']rtsp://"), "the live stream gets the Opus track")
        XCTAssertTrue(target.contains("onfail=abort:select='v:0,a:1']/tmp/spool/segment-"), "the files get the AAC track")
        XCTAssertTrue(joined.contains("-realtime:v true -allow_sw:v 1"), "encoder-private options are video-only now that audio encoders exist")
    }

    func testLiveOnlySoundHasASingleOpusTrack() throws {
        let arguments = try pipeline(recordingEnabled: false, audio: FFmpegAudioConfiguration()).arguments(audioInput: "/tmp/runtime/audio.pcm")
        XCTAssertFalse(arguments.contains("aac"), "no file, no AAC encode")
        XCTAssertEqual(arguments.filter { $0 == "libopus" }.count, 1)
        let target = try XCTUnwrap(arguments.last)
        XCTAssertFalse(target.contains("|"))
        XCTAssertTrue(target.contains("select='v:0,a:0'"))
    }

    func testWithoutAPipeTheCommandStaysSilentEvenWhenSoundIsConfigured() throws {
        let arguments = try pipeline(recordingEnabled: true, audio: FFmpegAudioConfiguration()).arguments()
        XCTAssertTrue(arguments.contains("-an"))
        XCTAssertFalse(arguments.contains("libopus"))
        XCTAssertFalse(try XCTUnwrap(arguments.last).contains("select="), "a tee without audio keeps the proven single-stream shape")
    }

    func testRemoteRecordingWritesLongClipsUnderTheRemoteName() throws {
        let target = try teeTarget(recordingEnabled: true, segmentSeconds: 600, prefix: "remote")
        XCTAssertTrue(target.contains("segment_time=600:"))
        XCTAssertTrue(target.contains("/tmp/spool/remote-"))
        XCTAssertFalse(target.contains("segment-"), "remote clips must not look like motion spool segments")
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
