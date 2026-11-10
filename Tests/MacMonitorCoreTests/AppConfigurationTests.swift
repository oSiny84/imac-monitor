import XCTest
@testable import MacMonitorCore

final class AppConfigurationTests: XCTestCase {
    func testLegacyConfigurationLoadsAndIgnoresTheRemovedMotionKeys() throws {
        let json = #"{"externalWebRTCHosts":[],"videoBitrateKbps":1200,"motionPixelThreshold":18,"motionChangedFraction":0.025,"preRollSeconds":30,"postRollSeconds":60,"motionRegions":{"detection":[],"exclusion":[]},"retentionDays":14,"retentionMaxGigabytes":20,"minimumFreeGigabytes":5}"#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        try configuration.validate()
        XCTAssertEqual(configuration.retentionDays, 14)
        XCTAssertFalse(configuration.sleepSchedule.enabled)
        XCTAssertTrue(configuration.liveStandby, "remote viewing is the default for existing settings too")
    }

    func testASettingsFileFromTheScheduledRecordingBuildStillLoads() throws {
        // The 2026-11-08 build wrote a weekly recording schedule; the key is ignored, not an error.
        let json = #"{"externalWebRTCHosts":[],"videoBitrateKbps":1200,"motionPixelThreshold":18,"motionChangedFraction":0.025,"retentionDays":14,"retentionMaxGigabytes":20,"minimumFreeGigabytes":5,"recordingSchedule":{"enabled":true,"weekdays":[2,3],"startMinute":540,"endMinute":1080,"segmentMinutes":10}}"#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        try configuration.validate()
        XCTAssertEqual(configuration, try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration)))
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

    func testSoundIsOnByDefaultAndCanBeTurnedOff() throws {
        let json = #"{"externalWebRTCHosts":[],"videoBitrateKbps":1200,"motionPixelThreshold":18,"motionChangedFraction":0.025,"retentionDays":14,"retentionMaxGigabytes":20,"minimumFreeGigabytes":5}"#
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(legacy.audioEnabled, "settings written before sound existed get sound on")
        let silent = AppConfiguration(audioEnabled: false)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(silent))
        XCTAssertFalse(decoded.audioEnabled)
        XCTAssertEqual(decoded, silent)
    }

    func testLiveStandbyChoiceSurvivesRoundTrip() throws {
        let original = AppConfiguration(liveStandby: false)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertFalse(decoded.liveStandby)
        XCTAssertEqual(decoded, original)
    }

    func testNewSettingsSurviveRoundTrip() throws {
        let original = AppConfiguration(
            sleepSchedule: DailySleepSchedule(enabled: true, sleepMinute: 23 * 60, wakeMinute: 6 * 60))
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        try decoded.validate()
    }

    func testRejectsIdenticalAndOutOfRangeScheduleTimes() {
        XCTAssertThrowsError(try DailySleepSchedule(sleepMinute: 600, wakeMinute: 600).validate())
        XCTAssertThrowsError(try DailySleepSchedule(sleepMinute: 1440).validate())
    }
}
