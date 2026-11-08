import Foundation

/// Lets the Mac sleep while nobody watches and wakes it on a timer to look for requests.
public struct SlimModeSettings: Codable, Equatable {
    public var enabled: Bool
    public var wakeIntervalMinutes: Int

    public init(enabled: Bool = false, wakeIntervalMinutes: Int = 10) {
        self.enabled = enabled
        self.wakeIntervalMinutes = wakeIntervalMinutes
    }

    private enum CodingKeys: String, CodingKey { case enabled, wakeIntervalMinutes }

    /// Older settings files have no slim mode; they decode as off.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        wakeIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .wakeIntervalMinutes) ?? 10
    }

    public var wakeInterval: TimeInterval { TimeInterval(wakeIntervalMinutes * 60) }

    public func validate() throws {
        guard (5...60).contains(wakeIntervalMinutes) else {
            throw AppConfigurationError.invalid("슬림 모드 확인 간격 5~60분")
        }
    }
}

/// The decisions behind slim mode, kept free of AppKit and IOKit so they can be tested here.
public struct SlimModePolicy {
    /// After launch or a wake the Mac stays up this long so the gateway can come back and the
    /// chat bot can fetch a pending request.
    public var checkWindow: TimeInterval = 60
    /// After a viewer leaves or a recording window closes, the Mac stays up this long.
    public var graceAfterCapture: TimeInterval = 60
    /// Someone typing or moving the mouse within this time is treated as present.
    public var idleBeforeSleep: TimeInterval = 600
    /// Wall-clock time that passed while uptime did not: the Mac slept.
    public var sleepGapThreshold: TimeInterval = 30

    public init() {}

    public enum Decision: Equatable {
        /// Keep the idle-sleep assertion.
        case holdAwake
        /// Release the assertion; someone is at the Mac, so sleeping is left to Energy Saver.
        case allowIdleSleep
        /// Release the assertion and put the Mac to sleep now.
        case sleepNow
    }

    public struct Inputs {
        public var enabled: Bool
        public var canScheduleWake: Bool
        public var captureWanted: Bool
        public var uptime: TimeInterval
        public var wakeUptime: TimeInterval
        public var captureEndedUptime: TimeInterval?
        public var secondsSinceInput: TimeInterval

        public init(enabled: Bool, canScheduleWake: Bool, captureWanted: Bool, uptime: TimeInterval,
                    wakeUptime: TimeInterval, captureEndedUptime: TimeInterval?, secondsSinceInput: TimeInterval) {
            self.enabled = enabled
            self.canScheduleWake = canScheduleWake
            self.captureWanted = captureWanted
            self.uptime = uptime
            self.wakeUptime = wakeUptime
            self.captureEndedUptime = captureEndedUptime
            self.secondsSinceInput = secondsSinceInput
        }
    }

    /// A Mac that cannot wake itself must not be allowed to sleep, so a missing sudoers rule
    /// keeps today's always-awake standby.
    public func decide(_ inputs: Inputs) -> Decision {
        guard inputs.enabled, inputs.canScheduleWake else { return .holdAwake }
        if inputs.captureWanted { return .holdAwake }
        if inputs.uptime - inputs.wakeUptime < checkWindow { return .holdAwake }
        if let ended = inputs.captureEndedUptime, inputs.uptime - ended < graceAfterCapture { return .holdAwake }
        if inputs.secondsSinceInput < idleBeforeSleep { return .allowIdleSleep }
        return .sleepNow
    }

    /// When to wake next: the periodic check, or a minute before the next recording window if
    /// that comes first. Nil when neither applies. Never earlier than a minute from now, because
    /// pmset wants a future time and the Mac is about to sleep.
    public func nextWake(after now: Date, interval: TimeInterval?, recordingSchedule: RecordingSchedule,
                         calendar: Calendar = .current) -> Date? {
        let floor = now.addingTimeInterval(60)
        var candidates: [Date] = []
        if let interval {
            candidates.append(max(floor, now.addingTimeInterval(interval)))
        }
        if let start = recordingSchedule.nextStart(after: now, calendar: calendar) {
            candidates.append(max(floor, start.addingTimeInterval(-60)))
        }
        return candidates.min()
    }

    /// Scheduled wakes may arrive as dark wakes without a wake notification. Uptime pauses
    /// during sleep while the wall clock does not, so a tick can tell that the Mac slept.
    public func slept(wallClockElapsed: TimeInterval, uptimeElapsed: TimeInterval) -> Bool {
        wallClockElapsed - uptimeElapsed > sleepGapThreshold
    }

    /// pmset reads "MM/dd/yy HH:mm:ss" in local time.
    public static func pmsetDateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }

    /// A wake within this tolerance of the one we asked for is ours, so the display may be
    /// turned back off the way the daily schedule already does.
    public static func isNear(_ date: Date, scheduled: Date?, tolerance: TimeInterval = 120) -> Bool {
        guard let scheduled else { return false }
        return abs(date.timeIntervalSince(scheduled)) <= tolerance
    }
}
