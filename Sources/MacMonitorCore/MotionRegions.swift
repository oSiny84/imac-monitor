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

public struct MotionRegions: Codable, Equatable {
    public static let maximumRectangles = 12
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
        (0..<36).reduce(0) { count, row in
            count + (0..<64).filter { includes(x: (Double($0) + 0.5) / 64, y: (Double(row) + 0.5) / 36) }.count
        }
    }

    public func validate() throws {
        guard detection.count <= Self.maximumRectangles, exclusion.count <= Self.maximumRectangles else {
            throw AppConfigurationError.invalid("감지·제외 영역은 각각 최대 12개입니다.")
        }
        for rectangle in detection + exclusion { try rectangle.validate() }
        guard activeSampleCount > 0 else {
            throw AppConfigurationError.invalid("실제 감지할 영역이 없습니다. 제외 영역을 줄이세요.")
        }
    }
}
