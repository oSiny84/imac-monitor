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
