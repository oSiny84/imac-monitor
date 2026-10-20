import CoreMedia
import CoreVideo
import Foundation

public struct MotionConfiguration: Equatable {
    public var analysisFramesPerSecond: Double
    public var pixelDifferenceThreshold: Double
    public var changedPixelFraction: Double
    public var sampleColumns: Int
    public var sampleRows: Int
    public var regions: MotionRegions

    public init(
        analysisFramesPerSecond: Double = 3,
        pixelDifferenceThreshold: Double = 18,
        changedPixelFraction: Double = 0.025,
        sampleColumns: Int = 64,
        sampleRows: Int = 36,
        regions: MotionRegions = MotionRegions()
    ) {
        self.analysisFramesPerSecond = analysisFramesPerSecond
        self.pixelDifferenceThreshold = pixelDifferenceThreshold
        self.changedPixelFraction = changedPixelFraction
        self.sampleColumns = sampleColumns
        self.sampleRows = sampleRows
        self.regions = regions
    }
}

public struct MotionObservation: Equatable {
    public let timestamp: Date
    public let score: Double
    public let isMotion: Bool
}

/// Low-cost luma detector. A frame-wide brightness offset is removed before comparison,
/// which reduces false positives when exposure changes or a light is switched on.
public final class MotionDetector {
    private let configuration: MotionConfiguration
    private var background: [Double] = []
    private var lastAnalysisUptime = -Double.infinity

    public init(configuration: MotionConfiguration = MotionConfiguration()) {
        self.configuration = configuration
    }

    public func analyze(
        sampleBuffer: CMSampleBuffer,
        timestamp: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> MotionObservation? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return analyze(pixelBuffer: pixelBuffer, timestamp: timestamp, uptime: uptime)
    }

    public func analyze(
        pixelBuffer: CVPixelBuffer,
        timestamp: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> MotionObservation? {
        let interval = 1 / max(configuration.analysisFramesPerSecond, 0.1)
        guard uptime - lastAnalysisUptime >= interval else { return nil }
        lastAnalysisUptime = uptime

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let samples = lumaSamples(from: pixelBuffer), !samples.isEmpty else { return nil }
        if background.count != samples.count {
            background = samples
            return MotionObservation(timestamp: timestamp, score: 0, isMotion: false)
        }

        var meanOffset = 0.0
        for index in samples.indices {
            meanOffset += samples[index] - background[index]
        }
        meanOffset /= Double(samples.count)

        var changed = 0
        for index in samples.indices {
            let adjustedDifference = abs((samples[index] - background[index]) - meanOffset)
            if adjustedDifference >= configuration.pixelDifferenceThreshold {
                changed += 1
            }
        }

        let score = Double(changed) / Double(samples.count)
        let isMotion = score >= configuration.changedPixelFraction
        let backgroundWeight = isMotion ? 0.01 : 0.08
        for index in samples.indices {
            background[index] += (samples[index] - background[index]) * backgroundWeight
        }
        return MotionObservation(timestamp: timestamp, score: score, isMotion: isMotion)
    }

    public func reset() {
        background.removeAll(keepingCapacity: false)
        lastAnalysisUptime = -Double.infinity
    }

    private func lumaSamples(from pixelBuffer: CVPixelBuffer) -> [Double]? {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let baseAddress: UnsafeMutableRawPointer?

        if planeCount > 0 {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        } else {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        }
        guard width > 0, height > 0, let baseAddress else { return nil }

        let stepX = max(1, width / max(configuration.sampleColumns, 1))
        let stepY = max(1, height / max(configuration.sampleRows, 1))
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var result: [Double] = []
        result.reserveCapacity((width / stepX + 1) * (height / stepY + 1))
        for y in stride(from: stepY / 2, to: height, by: stepY) {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in stride(from: stepX / 2, to: width, by: stepX) {
                guard configuration.regions.includes(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height)) else { continue }
                result.append(Double(row[x]))
            }
        }
        return result
    }
}
