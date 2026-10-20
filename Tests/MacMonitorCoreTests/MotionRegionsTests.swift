import XCTest
import Foundation
@testable import MacMonitorCore

final class MotionRegionsTests: XCTestCase {
    func testDefaultWholeFrameAndExclusionPrecedenceWithMultipleDetectionAreas() throws {
        XCTAssertEqual(MotionRegions().activeSampleCount, 2304)
        let left = MotionRectangle(x: 0, y: 0, width: 0.5, height: 1)
        let topRight = MotionRectangle(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let excluded = MotionRectangle(x: 0, y: 0, width: 0.5, height: 0.5)
        let regions = MotionRegions(detection: [left, topRight], exclusion: [excluded])
        try regions.validate()
        XCTAssertFalse(regions.includes(x: 0.25, y: 0.25))
        XCTAssertTrue(regions.includes(x: 0.25, y: 0.75))
        XCTAssertTrue(regions.includes(x: 0.75, y: 0.25))
        XCTAssertFalse(regions.includes(x: 0.75, y: 0.75))
        XCTAssertEqual(regions.activeSampleCount, 1152)
    }

    func testRejectsOutOfBoundsEmptyMaskNonfiniteAndExcessiveRegions() {
        for rectangle in [MotionRectangle(x: -0.1, y: 0, width: 0.5, height: 0.5),
                          MotionRectangle(x: 0.8, y: 0, width: 0.5, height: 0.5),
                          MotionRectangle(x: 0, y: 0, width: 0.001, height: 0.5),
                          MotionRectangle(x: .nan, y: 0, width: 0.5, height: 0.5)] {
            XCTAssertThrowsError(try MotionRegions(detection: [rectangle]).validate())
        }
        let full = MotionRectangle(x: 0, y: 0, width: 1, height: 1)
        XCTAssertThrowsError(try MotionRegions(exclusion: [full]).validate())
        XCTAssertThrowsError(try MotionRegions(detection: Array(repeating: full, count: 13)).validate())
    }

    func testSettingsRoundTripAndLegacyDefaultKeepFullFrame() throws {
        let regions = MotionRegions(exclusion: [MotionRectangle(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])
        let configuration = AppConfiguration(motionRegions: regions)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.motionRegions, regions)
        try decoded.validate()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "motionRegions")
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.motionRegions, MotionRegions())
    }
}
