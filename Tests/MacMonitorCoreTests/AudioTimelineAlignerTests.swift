import XCTest
@testable import MacMonitorCore

final class AudioTimelineAlignerTests: XCTestCase {
    // 48 kHz at 15 fps: one video frame covers 3,200 samples; the tolerance is 7,200 (150 ms).
    private let chunk = 1024

    func testAudioBeforeTheFirstVideoFrameIsDroppedAndThenWrittenInFull() {
        var aligner = AudioTimelineAligner()
        XCTAssertEqual(aligner.plan(incomingSamples: chunk, videoFramesEmitted: 0), .init(padSamples: 0, keepSamples: 0))
        XCTAssertEqual(aligner.trimmedSamples, Int64(chunk))
        XCTAssertEqual(aligner.samplesWritten, 0)
        XCTAssertEqual(aligner.plan(incomingSamples: chunk, videoFramesEmitted: 1), .init(padSamples: 0, keepSamples: chunk),
                       "the first frame covers 3,200 samples, so a 1,024-sample chunk is within tolerance")
        XCTAssertEqual(aligner.samplesWritten, Int64(chunk))
    }

    func testSteadyCaptureIsNeverCorrectedDespiteTheTwoArrivalRhythms() {
        var aligner = AudioTimelineAligner()
        // Audio arrives every 21.3 ms, video every 66.7 ms; simulate ten seconds of both.
        var frames: Int64 = 1
        var samplesArrived = 0
        for step in 1...470 {
            let now = Double(step) * Double(chunk) / 48_000
            frames = Int64(now * 15) + 1
            let plan = aligner.plan(incomingSamples: chunk, videoFramesEmitted: frames)
            XCTAssertEqual(plan, .init(padSamples: 0, keepSamples: chunk), "step \(step): jitter under one frame must pass untouched")
            samplesArrived += chunk
        }
        XCTAssertEqual(aligner.samplesWritten, Int64(samplesArrived))
        XCTAssertEqual(aligner.paddedSamples, 0)
        XCTAssertEqual(aligner.trimmedSamples, 0)
    }

    func testALateMicrophonePadsSilenceUpToTheVideo() {
        var aligner = AudioTimelineAligner()
        // The camera has run for a second (15 frames) before the first audio chunk arrives.
        let plan = aligner.plan(incomingSamples: chunk, videoFramesEmitted: 15)
        XCTAssertEqual(plan, .init(padSamples: 48_000 - chunk, keepSamples: chunk))
        XCTAssertEqual(aligner.samplesWritten, 48_000)
        XCTAssertEqual(aligner.paddedSamples, Int64(48_000 - chunk))
    }

    func testAudioRunningAheadIsTrimmedBackToTheVideo() {
        var aligner = AudioTimelineAligner()
        XCTAssertEqual(aligner.plan(incomingSamples: 3_200, videoFramesEmitted: 1), .init(padSamples: 0, keepSamples: 3_200))
        // The microphone keeps delivering while the pacer has not advanced: 8,000 more samples
        // would put audio 8,000 beyond the frame, past the 7,200 tolerance.
        XCTAssertEqual(aligner.plan(incomingSamples: 8_000, videoFramesEmitted: 1), .init(padSamples: 0, keepSamples: 0))
        XCTAssertEqual(aligner.trimmedSamples, 8_000)
        XCTAssertEqual(aligner.samplesWritten, 3_200)
        // Partially ahead: 12,000 more would reach 15,200, past the second frame's 6,400 plus
        // the tolerance, so only the newest samples that reach the target are kept.
        XCTAssertEqual(aligner.plan(incomingSamples: 12_000, videoFramesEmitted: 2), .init(padSamples: 0, keepSamples: 3_200))
        XCTAssertEqual(aligner.samplesWritten, 6_400)
    }

    func testSamplesThePipeRefusedArePaddedByTheNextChunk() {
        var aligner = AudioTimelineAligner()
        XCTAssertEqual(aligner.plan(incomingSamples: 3_200, videoFramesEmitted: 1).keepSamples, 3_200)
        aligner.noteUnwritten(samples: 3_200)
        XCTAssertEqual(aligner.droppedSamples, 3_200)
        XCTAssertEqual(aligner.samplesWritten, 0)
        // Five frames later the hole is wider than the tolerance and gets filled with silence.
        let plan = aligner.plan(incomingSamples: chunk, videoFramesEmitted: 5)
        XCTAssertEqual(plan, .init(padSamples: 16_000 - chunk, keepSamples: chunk))
        XCTAssertEqual(aligner.samplesWritten, 16_000)
    }

    func testTargetUsesIntegerSampleMathAndResetClearsEverything() {
        var aligner = AudioTimelineAligner(sampleRate: 44_100, framesPerSecond: 30)
        XCTAssertEqual(aligner.targetSamples(videoFramesEmitted: 30), 44_100)
        XCTAssertEqual(aligner.targetSamples(videoFramesEmitted: 1), 1_470)
        _ = aligner.plan(incomingSamples: 100, videoFramesEmitted: 0)
        aligner.reset()
        XCTAssertEqual(aligner.trimmedSamples, 0)
        XCTAssertEqual(aligner.samplesWritten, 0)
    }
}
