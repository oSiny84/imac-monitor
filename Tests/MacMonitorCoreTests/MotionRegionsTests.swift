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

    func testBoundaryUsesActualPixelCentersAndRejectsEmptyMask() {
        let regions = MotionRegions(
            detection: [MotionRectangle(x: 0, y: 0, width: 0.02, height: 1)],
            exclusion: [MotionRectangle(x: 0.008, y: 0, width: 0.02, height: 1)])
        // The former ideal-center calculation counted 36, but pixel x=10 has
        // center 10.5/1280, which is inside the exclusion. No real pixel survived.
        XCTAssertEqual(regions.activeSampleCount, 0)
        XCTAssertFalse(regions.samplingMask().isUsable)
        XCTAssertThrowsError(try regions.validate())
    }

    func testTinyAndOneDimensionalMasksAreRejectedButSmallUsableAreaPasses() throws {
        let tiny = MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 0.02, height: 0.02)])
        XCTAssertEqual(tiny.activeSampleCount, 1)
        XCTAssertThrowsError(try tiny.validate())

        let strip = MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 0.02, height: 1)])
        XCTAssertEqual(strip.activeSampleCount, 36)
        XCTAssertEqual(strip.samplingMask().sampledColumns, 1)
        XCTAssertThrowsError(try strip.validate())

        let small = MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 0.1, height: 0.12)])
        XCTAssertEqual(small.activeSampleCount, 24)
        XCTAssertEqual(small.samplingMask().sampledColumns, 6)
        XCTAssertEqual(small.samplingMask().sampledRows, 4)
        try small.validate()
    }

    func testGridHasExactUniquePixelCoordinatesAtNondivisibleAndSmallSizes() {
        let regions = MotionRegions()
        let detectorTestSize = regions.samplingMask(width: 64, height: 64)
        XCTAssertEqual(detectorTestSize.points.count, 2304)
        XCTAssertEqual(detectorTestSize.sampledColumns, 64)
        XCTAssertEqual(detectorTestSize.sampledRows, 36)
        XCTAssertEqual(regions.samplingMask(width: 64, height: 64, columns: 8, rows: 8).points.count, 64)
        let mask = regions.samplingMask(width: 65, height: 43, columns: 8, rows: 8)
        XCTAssertEqual(mask.points.count, 64)
        XCTAssertEqual(mask.sampledColumns, 8)
        XCTAssertEqual(mask.sampledRows, 8)
        XCTAssertTrue(mask.points.allSatisfy { $0.x >= 0 && $0.x < 65 && $0.y >= 0 && $0.y < 43 })
        let tiny = regions.samplingMask(width: 3, height: 3)
        XCTAssertEqual(tiny.points.count, 9)
        XCTAssertFalse(tiny.isUsable)
        XCTAssertTrue(regions.samplingMask(width: 4, height: 4).isUsable)
        XCTAssertTrue(regions.samplingMask(width: 0, height: 720).points.isEmpty)
        XCTAssertTrue(regions.samplingMask(columns: 0).points.isEmpty)
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

    func testEditingPreservesLegacyUnusableRegionsAndOtherSettingsUntilRepair() throws {
        let tiny = MotionRegions(detection: [MotionRectangle(x: 0, y: 0, width: 0.02, height: 0.02)])
        let schedule = DailySleepSchedule(enabled: true, sleepMinute: 22 * 60 + 30,
                                          wakeMinute: 7 * 60 + 15, mode: .displayOnly)
        var original = AppConfiguration(cameraUniqueID: "preserved-camera",
            externalWebRTCHosts: ["camera.example.com"], videoBitrateKbps: 2_400,
            preRollSeconds: 60, postRollSeconds: 90, sleepSchedule: schedule, motionRegions: tiny)
        let data = try JSONEncoder().encode(original)
        var editing = try AppConfiguration.decodeForEditing(data)
        XCTAssertEqual(editing, original, "Opening settings must not replace legacy fields with defaults.")
        XCTAssertEqual(editing.motionRegions, tiny)
        XCTAssertEqual(editing.videoBitrateKbps, 2_400)
        XCTAssertEqual(editing.preRollSeconds, 60)
        XCTAssertEqual(editing.postRollSeconds, 90)
        XCTAssertEqual(editing.sleepSchedule, schedule)
        XCTAssertThrowsError(try editing.validate(), "The legacy mask must not become valid merely by opening the editor.")
        editing.motionRegions = MotionRegions()
        XCTAssertNoThrow(try editing.validate())

        original.videoBitrateKbps = 249
        let invalidData = try JSONEncoder().encode(original)
        XCTAssertThrowsError(try AppConfiguration.decodeForEditing(invalidData),
                             "Editing may defer only region validation, not unrelated invalid fields.")
    }
}
