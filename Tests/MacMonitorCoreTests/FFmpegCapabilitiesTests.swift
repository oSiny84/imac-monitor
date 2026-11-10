import XCTest
@testable import MacMonitorCore

final class FFmpegCapabilitiesTests: XCTestCase {
    private let listing = """
    Encoders:
     V..... = Video
     A..... = Audio
     S..... = Subtitle
     .F.... = Frame-level multithreading
     ------
     V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
     A....D aac                  AAC (Advanced Audio Coding)
     A....D libopus              libopus Opus (codec opus)
     A....D pcm_mulaw            PCM mu-law / G.711 mu-law
    """

    func testEncoderNamesComeFromTheSecondColumnAndTheLegendIsSkipped() {
        let encoders = FFmpegCapabilities.parseEncoders(listing)
        XCTAssertEqual(encoders, ["h264_videotoolbox", "aac", "libopus", "pcm_mulaw"])
        XCTAssertEqual(FFmpegCapabilities.missingAudioEncoders(in: encoders), [])
        XCTAssertEqual(FFmpegCapabilities.missingAudioEncoders(in: ["aac"]), ["libopus"])
        XCTAssertEqual(FFmpegCapabilities.missingAudioEncoders(in: []), ["libopus", "aac"])
    }

    func testTheDryRunUsesTheProductionShape() {
        let arguments = FFmpegCapabilities.audioDryRunArguments()
        let joined = arguments.joined(separator: " ")
        XCTAssertTrue(joined.contains("-f rawvideo -pixel_format nv12"), "the same raw video input as the camera")
        XCTAssertTrue(joined.contains("-f s16le -ar 48000 -ac 1"), "the same raw audio input as the microphone")
        XCTAssertTrue(joined.contains("-c:a:0 libopus"))
        XCTAssertTrue(joined.contains("-c:a:1 aac"))
        XCTAssertTrue(joined.contains("[f=null:select=0,1]-|[f=null:select=0,2]-"), "the same stream selection as the camera")
        XCTAssertEqual(arguments.filter { $0 == "/dev/zero" }.count, 2, "no lavfi dependency: both inputs read zeros")
        XCTAssertTrue(arguments.contains("0.2"), "short enough to run at every camera start")
    }

    func testTheCacheProbesEachExecutableOnce() {
        var probes = 0
        let url = URL(fileURLWithPath: "/tmp/ffmpeg-\(UUID().uuidString)")
        let probe: (URL) -> FFmpegCapabilities = { _ in
            probes += 1
            return FFmpegCapabilities(encoders: ["aac"], audioProblem: "FFmpeg에 libopus 인코더가 없습니다")
        }
        let first = FFmpegCapabilities.cached(for: url, probe: probe)
        let second = FFmpegCapabilities.cached(for: url, probe: probe)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.supportsAudio)
    }
}
