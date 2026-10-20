import CoreVideo
import XCTest
@testable import MacMonitorCore

final class MotionDetectorTests: XCTestCase {
    func testLocalizedChangeTriggersMotionButGlobalBrightnessDoesNot() throws {
        let detector = MotionDetector(
            configuration: MotionConfiguration(
                analysisFramesPerSecond: 100,
                pixelDifferenceThreshold: 10,
                changedPixelFraction: 0.1,
                sampleColumns: 8,
                sampleRows: 8
            )
        )

        let baseline = try pixelBuffer(fill: 80)
        XCTAssertEqual(detector.analyze(pixelBuffer: baseline, uptime: 0)?.isMotion, false)

        let brighter = try pixelBuffer(fill: 120)
        XCTAssertEqual(detector.analyze(pixelBuffer: brighter, uptime: 1)?.isMotion, false)

        let localized = try pixelBuffer(fill: 120, changedQuadrant: true)
        let observation = detector.analyze(pixelBuffer: localized, uptime: 2)
        XCTAssertEqual(observation?.isMotion, true)
        XCTAssertGreaterThan(observation?.score ?? 0, 0.1)
    }

    private func pixelBuffer(fill: UInt8, changedQuadrant: Bool = false,
                             width: Int = 64, height: Int = 64,
                             changed: ((Int, Int) -> Bool)? = nil) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "MotionDetectorTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let isChanged = (changedQuadrant && x < width / 2 && y < height / 2) || (changed?(x, y) == true)
                base[y * stride + x] = isChanged ? 220 : fill
            }
        }
        return buffer
    }

    func testExcludedOrOutsideMotionDoesNotTriggerAndActiveMotionDoes() throws {
        let topLeft = MotionRectangle(x: 0, y: 0, width: 0.5, height: 0.5)
        for regions in [MotionRegions(exclusion: [topLeft]),
                        MotionRegions(detection: [MotionRectangle(x: 0.5, y: 0, width: 0.5, height: 1)])] {
            let detector = MotionDetector(configuration: MotionConfiguration(analysisFramesPerSecond: 100,
                pixelDifferenceThreshold: 10, changedPixelFraction: 0.1, sampleColumns: 8, sampleRows: 8, regions: regions))
            _ = detector.analyze(pixelBuffer: try pixelBuffer(fill: 80), uptime: 0)
            XCTAssertEqual(detector.analyze(pixelBuffer: try pixelBuffer(fill: 80, changedQuadrant: true), uptime: 1)?.isMotion, false)
        }
        let active = MotionDetector(configuration: MotionConfiguration(analysisFramesPerSecond: 100,
            pixelDifferenceThreshold: 10, changedPixelFraction: 0.1, sampleColumns: 8, sampleRows: 8,
            regions: MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 1, height: 0.5)])))
        _ = active.analyze(pixelBuffer: try pixelBuffer(fill: 80), uptime: 0)
        XCTAssertEqual(active.analyze(pixelBuffer: try pixelBuffer(fill: 80, changedQuadrant: true), uptime: 1)?.isMotion, true)
    }

    func testInvalidBoundaryAndTinyMasksReportErrorRatherThanHealthyIdle() throws {
        let boundary = MotionRegions(
            detection: [MotionRectangle(x: 0, y: 0, width: 0.02, height: 1)],
            exclusion: [MotionRectangle(x: 0.008, y: 0, width: 0.02, height: 1)])
        let tiny = MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 0.02, height: 0.02)])
        for regions in [boundary, tiny] {
            let detector = MotionDetector(configuration: MotionConfiguration(analysisFramesPerSecond: 100, regions: regions))
            let baseline = try pixelBuffer(fill: 80, width: 1280, height: 720)
            XCTAssertNil(detector.analyze(pixelBuffer: baseline, uptime: 0))
            let error = try XCTUnwrap(detector.takeSamplingError())
            XCTAssertEqual(error.activeSamples, regions.activeSampleCount)
            XCTAssertEqual(error.frameWidth, 1280)
            XCTAssertEqual(error.frameHeight, 720)
            XCTAssertNil(detector.takeSamplingError())
            XCTAssertNil(detector.analyze(pixelBuffer: baseline, uptime: 1))
            XCTAssertNil(detector.takeSamplingError(), "Do not flood the pipeline with repeated layout errors.")
            detector.reset()
            XCTAssertNil(detector.analyze(pixelBuffer: baseline, uptime: 2))
            XCTAssertNotNil(detector.takeSamplingError())
        }
    }

    func testSmallUsableMaskStillDetectsLocalizedChangeAndIgnoresExposureShift() throws {
        let regions = MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 0.1, height: 0.12)])
        try regions.validate()
        let detector = MotionDetector(configuration: MotionConfiguration(analysisFramesPerSecond: 100,
            pixelDifferenceThreshold: 10, changedPixelFraction: 0.1, regions: regions))
        XCTAssertEqual(detector.analyze(pixelBuffer: try pixelBuffer(fill: 80, width: 1280, height: 720), uptime: 0)?.isMotion, false)
        XCTAssertEqual(detector.analyze(pixelBuffer: try pixelBuffer(fill: 120, width: 1280, height: 720), uptime: 1)?.isMotion, false)
        let localized = try pixelBuffer(fill: 120, width: 1280, height: 720, changed: { x, y in x < 64 && y < 48 })
        XCTAssertEqual(detector.analyze(pixelBuffer: localized, uptime: 2)?.isMotion, true)
        XCTAssertNil(detector.takeSamplingError())
    }

    func testActualResolutionIsRevalidatedAndResolutionChangesResetBackground() throws {
        let detector = MotionDetector(configuration: MotionConfiguration(analysisFramesPerSecond: 100))
        XCTAssertNotNil(detector.analyze(pixelBuffer: try pixelBuffer(fill: 80), uptime: 0))
        XCTAssertNil(detector.analyze(pixelBuffer: try pixelBuffer(fill: 80, width: 3, height: 3), uptime: 1))
        XCTAssertEqual(detector.takeSamplingError()?.activeSamples, 9)
        XCTAssertEqual(detector.analyze(pixelBuffer: try pixelBuffer(fill: 220), uptime: 2)?.isMotion, false)
        XCTAssertNil(detector.takeSamplingError())
    }
}
