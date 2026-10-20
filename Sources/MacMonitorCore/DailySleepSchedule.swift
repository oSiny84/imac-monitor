import Foundation

public enum ScheduledRestMode: String, Codable {
    case systemSleep
    case displayOnly
}

/// Local wall-clock minutes. An interval may cross midnight; wake is exclusive.
public struct DailySleepSchedule: Codable, Equatable {
    public var enabled: Bool
    public var sleepMinute: Int
    public var wakeMinute: Int
    public var mode: ScheduledRestMode

    public init(enabled: Bool = false, sleepMinute: Int = 23 * 60, wakeMinute: Int = 6 * 60,
                mode: ScheduledRestMode = .systemSleep) {
        self.enabled = enabled
        self.sleepMinute = sleepMinute
        self.wakeMinute = wakeMinute
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey { case enabled, sleepMinute, wakeMinute, mode }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        sleepMinute = try values.decode(Int.self, forKey: .sleepMinute)
        wakeMinute = try values.decode(Int.self, forKey: .wakeMinute)
        mode = try values.decodeIfPresent(ScheduledRestMode.self, forKey: .mode) ?? .systemSleep
    }

    public var usesSystemSchedule: Bool { enabled && mode == .systemSleep }
    public var preparationMinutes: Int { mode == .systemSleep ? 1 : 0 }

    public func requiresSystemUpdate(replacing previous: DailySleepSchedule) -> Bool {
        if usesSystemSchedule != previous.usesSystemSchedule { return true }
        return usesSystemSchedule && (sleepMinute != previous.sleepMinute || wakeMinute != previous.wakeMinute)
    }

    /// Detect a resume boundary even when the Mac slept through the entire rest
    /// interval. An unrelated daytime wake must preserve a manual monitoring stop.
    public func crossesResumeTime(from start: Date, to end: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, end > start else { return false }
        let time = DateComponents(hour: wakeMinute / 60, minute: wakeMinute % 60, second: 0)
        guard let next = calendar.nextDate(after: start, matching: time,
                                           matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return false }
        return next <= end
    }

    /// A wake notification alone does not reveal its cause. Limit automatic display-off
    /// to the scheduled wake window, including slightly early hardware wakes.
    public func isNearScheduledWake(at date: Date, calendar: Calendar = .current) -> Bool {
        guard usesSystemSchedule else { return false }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        let distance = abs(seconds - wakeMinute * 60)
        return min(distance, 86400 - distance) <= 120
    }

    public func validate() throws {
        guard (0..<1440).contains(sleepMinute), (0..<1440).contains(wakeMinute),
              sleepMinute != wakeMinute else {
            throw AppConfigurationError.invalid("잠자기·깨우기 시각 (서로 다른 시각 필요)")
        }
    }

    public func isRestTime(at date: Date, calendar: Calendar = .current, preparationMinutes: Int = 0) -> Bool {
        guard enabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let awakeMinutes = (sleepMinute - wakeMinute + 1440) % 1440
        let preparation = min(max(0, preparationMinutes), max(0, awakeMinutes - 1))
        let start = (sleepMinute - preparation + 1440) % 1440
        return start < wakeMinute ? minute >= start && minute < wakeMinute : minute >= start || minute < wakeMinute
    }

    public static func timeString(_ minute: Int) -> String {
        String(format: "%02d:%02d:00", minute / 60, minute % 60)
    }
}
