import Foundation

/// Normalized, unmirrored camera coordinates; origin is the top-left.
public struct MotionRectangle: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && y >= self.y && x < self.x + width && y < self.y + height
    }

    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width >= 0.02, height >= 0.02, x + width <= 1.000000001, y + height <= 1.000000001 else {
            throw AppConfigurationError.invalid("감지 영역은 화면 안에서 너비·높이 2% 이상이어야 합니다.")
        }
    }
}

/// The exact pixel locations used by both settings validation and the detector.
public struct MotionSamplePoint: Equatable {
    public let x: Int
    public let y: Int
}

public struct MotionSampleMask: Equatable {
    public let points: [MotionSamplePoint]
    public let sampledColumns: Int
    public let sampledRows: Int

    /// A single sample cannot distinguish local motion from exposure changes.
    /// Require enough independent samples, spread across both image dimensions.
    public var isUsable: Bool {
        points.count >= MotionRegions.minimumActiveSamples && sampledColumns >= 2 && sampledRows >= 2
    }

    fileprivate init(points: [MotionSamplePoint]) {
        self.points = points
        sampledColumns = Set(points.map(\.x)).count
        sampledRows = Set(points.map(\.y)).count
    }
}

public struct MotionRegions: Codable, Equatable {
    public static let maximumRectangles = 12
    public static let minimumActiveSamples = 16
    public static let referenceFrameWidth = 1280
    public static let referenceFrameHeight = 720
    public static let defaultSampleColumns = 64
    public static let defaultSampleRows = 36
    public var detection: [MotionRectangle]
    public var exclusion: [MotionRectangle]

    public init(detection: [MotionRectangle] = [], exclusion: [MotionRectangle] = []) {
        self.detection = detection; self.exclusion = exclusion
    }

    public func includes(x: Double, y: Double) -> Bool {
        (detection.isEmpty || detection.contains { $0.contains(x: x, y: y) }) &&
            !exclusion.contains { $0.contains(x: x, y: y) }
    }

    public var activeSampleCount: Int {
        samplingMask().points.count
    }

    /// Select a fixed-size grid first, then test the centers of its actual pixels.
    /// Using ideal normalized centers for validation and integer pixel centers at
    /// runtime can disagree at exclusion boundaries, even producing an empty mask.
    public func samplingMask(
        width: Int = MotionRegions.referenceFrameWidth,
        height: Int = MotionRegions.referenceFrameHeight,
        columns: Int = MotionRegions.defaultSampleColumns,
        rows: Int = MotionRegions.defaultSampleRows
    ) -> MotionSampleMask {
        guard width > 0, height > 0, columns > 0, rows > 0 else {
            return MotionSampleMask(points: [])
        }
        let columnCount = min(width, columns)
        let rowCount = min(height, rows)
        var points: [MotionSamplePoint] = []
        points.reserveCapacity(columnCount * rowCount)
        for row in 0..<rowCount {
            let y = min(height - 1, Int((Double(row) + 0.5) * Double(height) / Double(rowCount)))
            for column in 0..<columnCount {
                let x = min(width - 1, Int((Double(column) + 0.5) * Double(width) / Double(columnCount)))
                if includes(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height)) {
                    points.append(MotionSamplePoint(x: x, y: y))
                }
            }
        }
        return MotionSampleMask(points: points)
    }

    public func validate() throws {
        guard detection.count <= Self.maximumRectangles, exclusion.count <= Self.maximumRectangles else {
            throw AppConfigurationError.invalid("감지·제외 영역은 각각 최대 12개입니다.")
        }
        for rectangle in detection + exclusion { try rectangle.validate() }
        guard samplingMask().isUsable else {
            throw AppConfigurationError.invalid("감지 영역에 가로·세로 각각 2개 이상, 총 16개 이상의 감지 표본이 필요합니다. 감지 영역을 넓히거나 제외 영역을 줄이세요.")
        }
    }
}
