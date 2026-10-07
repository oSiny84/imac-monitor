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

    private func pixelBuffer(fill: UInt8, changedQuadrant: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
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
        for y in 0..<64 {
            for x in 0..<64 {
                base[y * stride + x] = changedQuadrant && x < 32 && y < 32 ? 220 : fill
            }
        }
        return buffer
    }
}
