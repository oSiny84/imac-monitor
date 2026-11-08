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
                        wake: TimeInterval = 0, ended: TimeInterval? = nil, idle: TimeInterval = 3600,
                        woke: Bool = false) -> SlimModePolicy.Decision {
        policy.decide(SlimModePolicy.Inputs(enabled: enabled, canScheduleWake: canSchedule, captureWanted: capture,
            uptime: uptime, wakeUptime: wake, captureEndedUptime: ended, secondsSinceInput: idle, wokeFromSleep: woke))
    }

    func testSlimModeOffOrWithoutAWakeRuleKeepsTheMacAwakeAsBefore() {
        XCTAssertEqual(decide(enabled: false), .holdAwake)
        XCTAssertEqual(decide(canSchedule: false), .holdAwake, "a Mac that cannot wake itself must never be put to sleep")
    }

    func testTheMacStaysUpWhileWatchedDuringTheCheckWindowAndForAGraceAfterwards() {
        XCTAssertEqual(decide(capture: true, idle: 100_000), .holdAwake)
        XCTAssertEqual(decide(uptime: 89.9, wake: 0), .holdAwake, "the gateway needs the window to fetch a pending chat request")
        XCTAssertEqual(decide(uptime: 90, wake: 0), .sleepNow)
        XCTAssertEqual(decide(uptime: 1000, ended: 950), .holdAwake, "a viewer who just left may come straight back")
        XCTAssertEqual(decide(uptime: 1000, ended: 940), .sleepNow)
    }

    func testSomeoneAtTheMacPreventsForcedSleepButStillReleasesTheAssertion() {
        XCTAssertEqual(decide(idle: 299), .allowIdleSleep)
        XCTAssertEqual(decide(idle: 300), .sleepNow)
    }

    func testInputFromBeforeTheSleepIsNotPresenceAfterTheWake() {
        // Woke at 1000, now 1100; the last input was 1050 s ago, before the Mac slept.
        XCTAssertEqual(decide(uptime: 1100, wake: 1000, idle: 1050, woke: true), .sleepNow,
                       "the Apple-menu click that started the sleep must not keep the Mac up for another five minutes")
        XCTAssertEqual(decide(uptime: 1100, wake: 1000, idle: 50, woke: true), .allowIdleSleep,
                       "someone touched the Mac after it woke")
        XCTAssertEqual(decide(uptime: 1100, wake: 1000, idle: 103, woke: true), .allowIdleSleep,
                       "the keypress that woke the Mac is stamped just before the app noticed the wake")
        XCTAssertEqual(decide(uptime: 1100, wake: 1000, idle: 106, woke: true), .sleepNow)
        XCTAssertEqual(decide(uptime: 1100, wake: 1000, idle: 200, woke: false), .allowIdleSleep,
                       "after launch the owner who just double-clicked the app is present even without a wake")
    }

    func testTheExplanationNamesTheRuleThatDecided() {
        func explain(enabled: Bool = true, canSchedule: Bool = true, capture: Bool = false, uptime: TimeInterval = 1000,
                     wake: TimeInterval = 0, ended: TimeInterval? = nil, idle: TimeInterval = 3600, woke: Bool = false) -> String {
            policy.explain(SlimModePolicy.Inputs(enabled: enabled, canScheduleWake: canSchedule, captureWanted: capture,
                uptime: uptime, wakeUptime: wake, captureEndedUptime: ended, secondsSinceInput: idle, wokeFromSleep: woke))
        }
        XCTAssertEqual(explain(enabled: false), "슬림 모드 꺼짐 · 항상 깨어 있음")
        XCTAssertEqual(explain(canSchedule: false), "깨우기 예약 확인 실패 · 안전을 위해 깨어 있음")
        XCTAssertEqual(explain(capture: true), "카메라 사용 중 · 깨어 있음")
        XCTAssertEqual(explain(uptime: 40, wake: 0), "깨어난 지 40초 · 51초 뒤 판단")
        XCTAssertEqual(explain(uptime: 1000, ended: 970), "카메라 꺼진 지 30초 · 31초 뒤 판단")
        XCTAssertEqual(explain(idle: 150), "마지막 입력 2분 전 · 입력 없이 3분 더 지나면 잠듦")
        XCTAssertEqual(explain(idle: 300), "잠자기 요청")
        XCTAssertEqual(explain(uptime: 1100, wake: 1000, idle: 1050, woke: true), "깨어난 뒤 입력 없음 · 잠자기 요청")
        // The same inputs decide .sleepNow, so the text and the action agree.
        XCTAssertEqual(decide(idle: 300), .sleepNow)
    }

    func testNextWakeIsThePeriodicCheckAndNeverLessThanAMinuteAhead() {
        let monday8 = at(day: 9, 8)
        XCTAssertEqual(policy.nextWake(after: monday8, interval: 600), at(day: 9, 8, 10))
        XCTAssertEqual(policy.nextWake(after: monday8, interval: 30), at(day: 9, 8, 1),
                       "a wake is never asked for less than a minute ahead")
        XCTAssertNil(policy.nextWake(after: monday8, interval: nil), "without slim mode nothing wakes the Mac")
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
