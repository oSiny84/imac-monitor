import XCTest
@testable import MacMonitorCore

final class SlimModePolicyTests: XCTestCase {
    private let policy = SlimModePolicy()

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    // 2026-11-09 is a Monday.
    private func at(day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    private func decide(enabled: Bool = true, canSchedule: Bool = true, capture: Bool = false, uptime: TimeInterval = 1000,
                        wake: TimeInterval = 0, ended: TimeInterval? = nil, idle: TimeInterval = 3600) -> SlimModePolicy.Decision {
        policy.decide(SlimModePolicy.Inputs(enabled: enabled, canScheduleWake: canSchedule, captureWanted: capture,
            uptime: uptime, wakeUptime: wake, captureEndedUptime: ended, secondsSinceInput: idle))
    }

    func testSlimModeOffOrWithoutAWakeRuleKeepsTheMacAwakeAsBefore() {
        XCTAssertEqual(decide(enabled: false), .holdAwake)
        XCTAssertEqual(decide(canSchedule: false), .holdAwake, "a Mac that cannot wake itself must never be put to sleep")
    }

    func testTheMacStaysUpWhileWatchedDuringTheCheckWindowAndForAGraceAfterwards() {
        XCTAssertEqual(decide(capture: true, idle: 100_000), .holdAwake)
        XCTAssertEqual(decide(uptime: 59.9, wake: 0), .holdAwake, "the gateway needs the window to fetch a pending chat request")
        XCTAssertEqual(decide(uptime: 60, wake: 0), .sleepNow)
        XCTAssertEqual(decide(uptime: 1000, ended: 950), .holdAwake, "a viewer who just left may come straight back")
        XCTAssertEqual(decide(uptime: 1000, ended: 940), .sleepNow)
    }

    func testSomeoneAtTheMacPreventsForcedSleepButStillReleasesTheAssertion() {
        XCTAssertEqual(decide(idle: 599), .allowIdleSleep)
        XCTAssertEqual(decide(idle: 600), .sleepNow)
    }

    func testNextWakeIsThePeriodicCheckOrTheRecordingWindowWhicheverComesFirst() {
        let schedule = RecordingSchedule(enabled: true)
        let monday8 = at(day: 9, 8)
        XCTAssertEqual(policy.nextWake(after: monday8, interval: 600, recordingSchedule: schedule, calendar: calendar), at(day: 9, 8, 10))
        XCTAssertEqual(policy.nextWake(after: monday8, interval: 3600, recordingSchedule: schedule, calendar: calendar), at(day: 9, 8, 59),
                       "the recording window starts before the next periodic check")
        XCTAssertEqual(policy.nextWake(after: monday8, interval: nil, recordingSchedule: schedule, calendar: calendar), at(day: 9, 8, 59),
                       "without slim mode only the recording window wakes the Mac")
        XCTAssertEqual(policy.nextWake(after: at(day: 9, 8, 59, 30), interval: nil, recordingSchedule: schedule, calendar: calendar), at(day: 9, 9, 0, 30),
                       "a wake is never asked for less than a minute ahead")
        XCTAssertEqual(policy.nextWake(after: monday8, interval: 30, recordingSchedule: RecordingSchedule(), calendar: calendar), at(day: 9, 8, 1))
        XCTAssertNil(policy.nextWake(after: monday8, interval: nil, recordingSchedule: RecordingSchedule(), calendar: calendar))
    }

    func testSleepIsDetectedFromTheClockGap() {
        XCTAssertTrue(policy.slept(wallClockElapsed: 610, uptimeElapsed: 10))
        XCTAssertFalse(policy.slept(wallClockElapsed: 10.5, uptimeElapsed: 10))
        XCTAssertFalse(policy.slept(wallClockElapsed: 40, uptimeElapsed: 10), "thirty seconds is the threshold, not less")
        XCTAssertTrue(policy.slept(wallClockElapsed: 41, uptimeElapsed: 10))
    }

    func testPmsetDateUsesTheTwoDigitYearFormatFromTheManual() {
        XCTAssertEqual(SlimModePolicy.pmsetDateString(at(day: 8, 14, 30, 5), timeZone: TimeZone(secondsFromGMT: 0)!), "11/08/26 14:30:05")
    }

    func testAWakeNearTheScheduledTimeIsOurs() {
        let scheduled = at(day: 8, 14, 30)
        XCTAssertTrue(SlimModePolicy.isNear(at(day: 8, 14, 28), scheduled: scheduled))
        XCTAssertTrue(SlimModePolicy.isNear(at(day: 8, 14, 32), scheduled: scheduled))
        XCTAssertFalse(SlimModePolicy.isNear(at(day: 8, 14, 32, 1), scheduled: scheduled))
        XCTAssertFalse(SlimModePolicy.isNear(at(day: 8, 14, 30), scheduled: nil))
    }

    func testSettingsDecodeAsOffFromOlderFilesAndValidateTheInterval() throws {
        let legacy = try JSONDecoder().decode(SlimModeSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.enabled)
        XCTAssertEqual(legacy.wakeIntervalMinutes, 10)
        XCTAssertEqual(legacy.wakeInterval, 600)
        XCTAssertNoThrow(try SlimModeSettings(enabled: true, wakeIntervalMinutes: 5).validate())
        XCTAssertThrowsError(try SlimModeSettings(wakeIntervalMinutes: 4).validate())
        XCTAssertThrowsError(try SlimModeSettings(wakeIntervalMinutes: 61).validate())
        let original = SlimModeSettings(enabled: true, wakeIntervalMinutes: 15)
        XCTAssertEqual(try JSONDecoder().decode(SlimModeSettings.self, from: JSONEncoder().encode(original)), original)
    }
}
