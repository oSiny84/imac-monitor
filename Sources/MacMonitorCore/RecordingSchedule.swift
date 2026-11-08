import Foundation

/// Weekly recording windows in local wall-clock minutes. Inside a window the camera records
/// continuous clips without motion detection; the usual size, age and free-space limits still
/// decide how much is kept. A window whose end is not after its start crosses midnight and
/// belongs to the weekday it starts on.
public struct RecordingSchedule: Codable, Equatable {
    public var enabled: Bool
    /// Calendar weekday numbers, 1 = Sunday through 7 = Saturday, kept sorted and unique.
    public var weekdays: [Int]
    public var startMinute: Int
    public var endMinute: Int
    public var segmentMinutes: Int

    public init(enabled: Bool = false, weekdays: [Int] = [2, 3, 4, 5, 6], startMinute: Int = 9 * 60,
                endMinute: Int = 18 * 60, segmentMinutes: Int = 10) {
        self.enabled = enabled
        self.weekdays = Self.normalized(weekdays)
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.segmentMinutes = segmentMinutes
    }

    private enum CodingKeys: String, CodingKey { case enabled, weekdays, startMinute, endMinute, segmentMinutes }

    /// Older settings files have no schedule; they decode as the default, which is off.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        weekdays = Self.normalized(try values.decodeIfPresent([Int].self, forKey: .weekdays) ?? [2, 3, 4, 5, 6])
        startMinute = try values.decodeIfPresent(Int.self, forKey: .startMinute) ?? 9 * 60
        endMinute = try values.decodeIfPresent(Int.self, forKey: .endMinute) ?? 18 * 60
        segmentMinutes = try values.decodeIfPresent(Int.self, forKey: .segmentMinutes) ?? 10
    }

    private static func normalized(_ days: [Int]) -> [Int] {
        Array(Set(days)).sorted()
    }

    public var segmentDuration: TimeInterval { TimeInterval(segmentMinutes * 60) }
    public var crossesMidnight: Bool { endMinute <= startMinute }

    public func validate() throws {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else {
            throw AppConfigurationError.invalid("예약 녹화 시작·종료 시각 (서로 다른 시각 필요)")
        }
        guard weekdays.allSatisfy({ (1...7).contains($0) }), !enabled || !weekdays.isEmpty else {
            throw AppConfigurationError.invalid("예약 녹화 요일 (하루 이상 선택)")
        }
        guard (1...60).contains(segmentMinutes) else {
            throw AppConfigurationError.invalid("예약 녹화 파일 길이 1~60분")
        }
    }

    /// Whether `date` is inside a window. After midnight a crossing window still counts for the
    /// weekday it started on, so a Friday 22:00-02:00 window records early Saturday.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekday = parts.weekday ?? 0
        if !crossesMidnight {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        if minute >= startMinute { return weekdays.contains(weekday) }
        if minute < endMinute { return weekdays.contains(weekday == 1 ? 7 : weekday - 1) }
        return false
    }

    /// The next moment a window opens after `date`, or nil while the schedule is off. A sleeping
    /// Mac is woken shortly before it.
    public func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, !weekdays.isEmpty else { return nil }
        let time = DateComponents(hour: startMinute / 60, minute: startMinute % 60, second: 0)
        var candidate = date
        for _ in 0..<8 {
            guard let next = calendar.nextDate(after: candidate, matching: time,
                                               matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
            if weekdays.contains(calendar.component(.weekday, from: next)) { return next }
            candidate = next
        }
        return nil
    }

    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["일", "월", "화", "수", "목", "금", "토"]
        guard (1...7).contains(weekday) else { return "?" }
        return names[weekday - 1]
    }
}
