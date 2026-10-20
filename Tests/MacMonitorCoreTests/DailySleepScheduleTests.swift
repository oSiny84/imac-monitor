import XCTest
@testable import MacMonitorCore

final class DailySleepScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour, minute: minute))!
    }

    func testOvernightSleepAndExactWakeBoundary() {
        let schedule = DailySleepSchedule(enabled: true)
        XCTAssertFalse(schedule.isRestTime(at: at(22, 59), calendar: calendar))
        XCTAssertTrue(schedule.isRestTime(at: at(23), calendar: calendar))
        XCTAssertTrue(schedule.isRestTime(at: at(0), calendar: calendar))
        XCTAssertTrue(schedule.isRestTime(at: at(5, 59), calendar: calendar))
        XCTAssertFalse(schedule.isRestTime(at: at(6), calendar: calendar))
        XCTAssertTrue(schedule.isRestTime(at: at(22, 59), calendar: calendar, preparationMinutes: 1))
    }

    func testSameDayIntervalAndDisabledSchedule() {
        var schedule = DailySleepSchedule(enabled: true, sleepMinute: 9 * 60, wakeMinute: 17 * 60)
        XCTAssertFalse(schedule.isRestTime(at: at(8), calendar: calendar))
        XCTAssertTrue(schedule.isRestTime(at: at(9), calendar: calendar))
        XCTAssertFalse(schedule.isRestTime(at: at(17), calendar: calendar))
        schedule.enabled = false
        XCTAssertFalse(schedule.isRestTime(at: at(10), calendar: calendar))
    }

    func testPreparationNeverSwallowsTheEntireAwakeInterval() {
        let schedule = DailySleepSchedule(enabled: true, sleepMinute: 361, wakeMinute: 360)
        XCTAssertFalse(schedule.isRestTime(at: at(6), calendar: calendar, preparationMinutes: 1))
    }

    func testLegacyScheduleDefaultsToSystemSleep() throws {
        let data = Data(#"{"enabled":true,"sleepMinute":1380,"wakeMinute":360}"#.utf8)
        let schedule = try JSONDecoder().decode(DailySleepSchedule.self, from: data)
        XCTAssertEqual(schedule.mode, .systemSleep)
        XCTAssertTrue(schedule.usesSystemSchedule)
        XCTAssertEqual(schedule.preparationMinutes, 1)
    }

    func testDisplayOnlyRoundTripAndExactRestStart() throws {
        let schedule = DailySleepSchedule(enabled: true, mode: .displayOnly)
        XCTAssertEqual(try JSONDecoder().decode(DailySleepSchedule.self,
            from: JSONEncoder().encode(schedule)), schedule)
        XCTAssertFalse(schedule.usesSystemSchedule)
        XCTAssertEqual(schedule.preparationMinutes, 0)
        XCTAssertFalse(schedule.isRestTime(at: at(22, 59), calendar: calendar,
                                           preparationMinutes: schedule.preparationMinutes))
        XCTAssertTrue(schedule.isRestTime(at: at(23), calendar: calendar))
        XCTAssertFalse(schedule.isRestTime(at: at(6), calendar: calendar))
    }

    func testOnlySystemScheduleChangesRequireAdministratorUpdate() {
        let disabled = DailySleepSchedule()
        let display = DailySleepSchedule(enabled: true, mode: .displayOnly)
        let system = DailySleepSchedule(enabled: true)
        XCTAssertFalse(display.requiresSystemUpdate(replacing: disabled))
        XCTAssertFalse(disabled.requiresSystemUpdate(replacing: display))
        XCTAssertFalse(display.requiresSystemUpdate(replacing: display))
        XCTAssertFalse(system.requiresSystemUpdate(replacing: system))
        XCTAssertTrue(system.requiresSystemUpdate(replacing: display))
        XCTAssertTrue(display.requiresSystemUpdate(replacing: system))
        XCTAssertTrue(disabled.requiresSystemUpdate(replacing: system))
        var updated = display
        updated.wakeMinute = 7 * 60
        XCTAssertFalse(updated.requiresSystemUpdate(replacing: display))
        updated.mode = .systemSleep
        XCTAssertTrue(updated.requiresSystemUpdate(replacing: system))
    }

    func testScheduledWakeWindowIncludingMidnight() {
        var schedule = DailySleepSchedule(enabled: true)
        XCTAssertTrue(schedule.isNearScheduledWake(at: at(5, 58), calendar: calendar))
        XCTAssertTrue(schedule.isNearScheduledWake(at: at(6, 2), calendar: calendar))
        XCTAssertFalse(schedule.isNearScheduledWake(at: at(6, 3), calendar: calendar))
        XCTAssertFalse(schedule.isNearScheduledWake(at: at(12), calendar: calendar))
        schedule.wakeMinute = 0
        XCTAssertTrue(schedule.isNearScheduledWake(at: at(23, 59), calendar: calendar))
        XCTAssertTrue(schedule.isNearScheduledWake(at: at(0, 1), calendar: calendar))
        schedule.mode = .displayOnly
        XCTAssertFalse(schedule.isNearScheduledWake(at: at(0), calendar: calendar))
        schedule.mode = .systemSleep
        schedule.enabled = false
        XCTAssertFalse(schedule.isNearScheduledWake(at: at(0), calendar: calendar))
    }

    func testDaytimeWakeDoesNotUndoManualStopButMissedResumeBoundaryDoes() {
        let schedule = DailySleepSchedule(enabled: true)
        XCTAssertFalse(schedule.crossesResumeTime(from: at(12), to: at(13), calendar: calendar))
        XCTAssertTrue(schedule.crossesResumeTime(from: at(5, 59), to: at(6), calendar: calendar))
        XCTAssertFalse(schedule.crossesResumeTime(from: at(6), to: at(7), calendar: calendar))
        let previousEvening = calendar.date(byAdding: .day, value: -1, to: at(22))!
        XCTAssertTrue(schedule.crossesResumeTime(from: previousEvening, to: at(7), calendar: calendar))
        XCTAssertFalse(schedule.crossesResumeTime(from: previousEvening, to: at(5, 59), calendar: calendar))
        XCTAssertFalse(schedule.crossesResumeTime(from: at(7), to: at(5), calendar: calendar))
        XCTAssertFalse(DailySleepSchedule().crossesResumeTime(from: previousEvening, to: at(7), calendar: calendar))
    }

    func testDisplayOnlyResumeBoundaryIsDetectedAcrossLongSleep() {
        let schedule = DailySleepSchedule(enabled: true, mode: .displayOnly)
        let previousEvening = calendar.date(byAdding: .day, value: -1, to: at(22))!
        XCTAssertTrue(schedule.crossesResumeTime(from: previousEvening, to: at(7), calendar: calendar))
    }
}
