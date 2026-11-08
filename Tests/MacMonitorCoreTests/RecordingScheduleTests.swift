import XCTest
@testable import MacMonitorCore

final class RecordingScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    // 2026-11-08 is a Sunday, so day 9 is Monday and day 13 is Friday.
    private func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testWeekdayWindowIncludesTheStartAndExcludesTheEnd() {
        let schedule = RecordingSchedule(enabled: true)
        XCTAssertFalse(schedule.isActive(at: at(day: 9, 8, 59), calendar: calendar))
        XCTAssertTrue(schedule.isActive(at: at(day: 9, 9), calendar: calendar))
        XCTAssertTrue(schedule.isActive(at: at(day: 9, 17, 59), calendar: calendar))
        XCTAssertFalse(schedule.isActive(at: at(day: 9, 18), calendar: calendar))
        XCTAssertFalse(schedule.isActive(at: at(day: 14, 10), calendar: calendar), "Saturday is not a selected weekday")
        XCTAssertFalse(schedule.isActive(at: at(day: 8, 10), calendar: calendar), "Sunday is not a selected weekday")
    }

    func testDisabledScheduleIsNeverActive() {
        let schedule = RecordingSchedule(enabled: false)
        XCTAssertFalse(schedule.isActive(at: at(day: 9, 10), calendar: calendar))
        XCTAssertNil(schedule.nextStart(after: at(day: 9, 10), calendar: calendar))
    }

    func testMidnightCrossingWindowBelongsToTheDayItStartsOn() {
        // Friday 22:00 to Saturday 02:00.
        let schedule = RecordingSchedule(enabled: true, weekdays: [6], startMinute: 22 * 60, endMinute: 2 * 60)
        XCTAssertTrue(schedule.crossesMidnight)
        XCTAssertTrue(schedule.isActive(at: at(day: 13, 23), calendar: calendar))
        XCTAssertTrue(schedule.isActive(at: at(day: 14, 1, 59), calendar: calendar), "early Saturday is still Friday's window")
        XCTAssertFalse(schedule.isActive(at: at(day: 14, 2), calendar: calendar))
        XCTAssertFalse(schedule.isActive(at: at(day: 12, 23), calendar: calendar), "Thursday night is not selected")
        XCTAssertFalse(schedule.isActive(at: at(day: 15, 1), calendar: calendar), "Sunday morning follows an unselected Saturday")
        XCTAssertFalse(schedule.isActive(at: at(day: 13, 12), calendar: calendar))
    }

    func testSundayWrapsToSaturdayForAMidnightCrossingWindow() {
        let schedule = RecordingSchedule(enabled: true, weekdays: [7], startMinute: 23 * 60, endMinute: 60)
        XCTAssertTrue(schedule.isActive(at: at(day: 15, 0, 30), calendar: calendar), "Sunday 00:30 continues Saturday's window")
        XCTAssertFalse(schedule.isActive(at: at(day: 15, 23, 30), calendar: calendar), "Sunday night itself is not selected")
    }

    func testNextStartSkipsUnselectedDays() {
        let schedule = RecordingSchedule(enabled: true)
        XCTAssertEqual(schedule.nextStart(after: at(day: 8, 10), calendar: calendar), at(day: 9, 9), "from Sunday the next start is Monday 09:00")
        XCTAssertEqual(schedule.nextStart(after: at(day: 13, 10), calendar: calendar), at(day: 16, 9), "the weekend is skipped")
        XCTAssertEqual(schedule.nextStart(after: at(day: 9, 8, 59), calendar: calendar), at(day: 9, 9))
        XCTAssertEqual(schedule.nextStart(after: at(day: 9, 9), calendar: calendar), at(day: 10, 9), "a start exactly now is not next")
    }

    func testValidationRejectsEmptyDaysBadDaysAndEqualTimes() {
        XCTAssertThrowsError(try RecordingSchedule(enabled: true, weekdays: []).validate())
        XCTAssertNoThrow(try RecordingSchedule(enabled: false, weekdays: []).validate(), "an off schedule may have no days yet")
        XCTAssertThrowsError(try RecordingSchedule(weekdays: [0]).validate())
        XCTAssertThrowsError(try RecordingSchedule(weekdays: [8]).validate())
        XCTAssertThrowsError(try RecordingSchedule(startMinute: 600, endMinute: 600).validate())
        XCTAssertThrowsError(try RecordingSchedule(startMinute: 1440).validate())
        XCTAssertThrowsError(try RecordingSchedule(segmentMinutes: 0).validate())
        XCTAssertThrowsError(try RecordingSchedule(segmentMinutes: 61).validate())
        XCTAssertNoThrow(try RecordingSchedule(enabled: true, startMinute: 22 * 60, endMinute: 2 * 60).validate())
    }

    func testWeekdaysAreStoredSortedAndUniqueAndLegacyFilesDecodeAsOff() throws {
        let schedule = RecordingSchedule(weekdays: [6, 2, 6, 4])
        XCTAssertEqual(schedule.weekdays, [2, 4, 6])
        let decoded = try JSONDecoder().decode(RecordingSchedule.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, RecordingSchedule())
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.segmentDuration, 600)
        let roundTrip = try JSONDecoder().decode(RecordingSchedule.self, from: JSONEncoder().encode(schedule))
        XCTAssertEqual(roundTrip, schedule)
    }

    func testWeekdayNames() {
        XCTAssertEqual((1...7).map(RecordingSchedule.weekdayName), ["일", "월", "화", "수", "목", "금", "토"])
        XCTAssertEqual(RecordingSchedule.weekdayName(0), "?")
    }
}
