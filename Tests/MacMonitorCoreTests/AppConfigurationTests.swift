import XCTest
@testable import MacMonitorCore

final class AppConfigurationTests: XCTestCase {
    func testLegacyConfigurationKeepsItsRecordingWindow() throws {
        let json = #"{"externalWebRTCHosts":[],"videoBitrateKbps":1200,"motionPixelThreshold":18,"motionChangedFraction":0.025,"retentionDays":14,"retentionMaxGigabytes":20,"minimumFreeGigabytes":5}"#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        try configuration.validate()
        XCTAssertEqual(configuration.preRollSeconds, 5)
        XCTAssertEqual(configuration.postRollSeconds, 15)
        XCTAssertFalse(configuration.sleepSchedule.enabled)
        XCTAssertTrue(configuration.liveStandby, "remote viewing is the default for existing settings too")
        XCTAssertFalse(configuration.recordingSchedule.enabled, "older settings never recorded on a schedule")
    }

    func testRecordingScheduleSurvivesRoundTripAndIsValidated() throws {
        let original = AppConfiguration(recordingSchedule: RecordingSchedule(enabled: true, weekdays: [6, 2, 2],
            startMinute: 22 * 60, endMinute: 2 * 60, segmentMinutes: 30))
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.recordingSchedule.weekdays, [2, 6], "weekdays are stored sorted and unique")
        try decoded.validate()
        XCTAssertThrowsError(try AppConfiguration(recordingSchedule: RecordingSchedule(enabled: true, weekdays: [])).validate())
    }

    func testSlimModeDefaultsOffAndValidatesTheWakeInterval() throws {
        let json = #"{"externalWebRTCHosts":[],"videoBitrateKbps":1200,"motionPixelThreshold":18,"motionChangedFraction":0.025,"retentionDays":14,"retentionMaxGigabytes":20,"minimumFreeGigabytes":5}"#
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(legacy.slimMode.enabled, "older settings keep the always-awake standby")
        XCTAssertEqual(legacy.slimMode.wakeIntervalMinutes, 10)
        let original = AppConfiguration(slimMode: SlimModeSettings(enabled: true, wakeIntervalMinutes: 15))
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        try decoded.validate()
        XCTAssertThrowsError(try AppConfiguration(slimMode: SlimModeSettings(wakeIntervalMinutes: 4)).validate())
        XCTAssertThrowsError(try AppConfiguration(slimMode: SlimModeSettings(wakeIntervalMinutes: 61)).validate())
    }

    func testLiveStandbyChoiceSurvivesRoundTrip() throws {
        let original = AppConfiguration(liveStandby: false)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertFalse(decoded.liveStandby)
        XCTAssertEqual(decoded, original)
    }

    func testNewSettingsSurviveRoundTrip() throws {
        let original = AppConfiguration(preRollSeconds: 60, postRollSeconds: 120,
            sleepSchedule: DailySleepSchedule(enabled: true, sleepMinute: 23 * 60, wakeMinute: 6 * 60))
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        try decoded.validate()
    }

    func testRejectsInvalidWindowsAndIdenticalScheduleTimes() {
        XCTAssertThrowsError(try AppConfiguration(preRollSeconds: -1).validate())
        XCTAssertThrowsError(try AppConfiguration(postRollSeconds: 0).validate())
        XCTAssertThrowsError(try AppConfiguration(postRollSeconds: 301).validate())
        XCTAssertThrowsError(try DailySleepSchedule(sleepMinute: 600, wakeMinute: 600).validate())
        XCTAssertThrowsError(try DailySleepSchedule(sleepMinute: 1440).validate())
    }
}
