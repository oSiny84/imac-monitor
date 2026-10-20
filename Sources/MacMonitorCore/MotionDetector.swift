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
        sampleColumns: Int = MotionRegions.defaultSampleColumns,
        sampleRows: Int = MotionRegions.defaultSampleRows,
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

public struct MotionSamplingError: LocalizedError, Equatable {
    public let activeSamples: Int
    public let frameWidth: Int
    public let frameHeight: Int

    public var errorDescription: String? {
        "현재 카메라 해상도에서 감지 영역을 사용할 수 없습니다(표본 \(activeSamples)개). 가로·세로 각각 2개 이상, 총 16개 이상의 표본을 확보하도록 감지 영역을 넓히거나 제외 영역을 줄이세요."
    }
}

/// Low-cost luma detector. A frame-wide brightness offset is removed before comparison,
/// which reduces false positives when exposure changes or a light is switched on.
public final class MotionDetector {
    private let configuration: MotionConfiguration
    private var background: [Double] = []
    private var lastAnalysisUptime = -Double.infinity
    private var samplingLayout: (width: Int, height: Int, mask: MotionSampleMask)?
    private var pendingSamplingError: MotionSamplingError?

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
        samplingLayout = nil
        pendingSamplingError = nil
    }

    /// Consumed once for each invalid layout. The caller should report this after
    /// releasing its own pipeline lock, not silently treat a nil analysis as idle.
    public func takeSamplingError() -> MotionSamplingError? {
        let error = pendingSamplingError
        pendingSamplingError = nil
        return error
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

        if samplingLayout?.width != width || samplingLayout?.height != height {
            let mask = configuration.regions.samplingMask(width: width, height: height,
                columns: configuration.sampleColumns, rows: configuration.sampleRows)
            samplingLayout = (width, height, mask)
            background.removeAll(keepingCapacity: true)
            pendingSamplingError = mask.isUsable ? nil : MotionSamplingError(
                activeSamples: mask.points.count, frameWidth: width, frameHeight: height)
        }
        guard let mask = samplingLayout?.mask, mask.isUsable else { return nil }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var result: [Double] = []
        result.reserveCapacity(mask.points.count)
        for point in mask.points {
            result.append(Double(bytes[point.y * bytesPerRow + point.x]))
        }
        return result
    }
}
