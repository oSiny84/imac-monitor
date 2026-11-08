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
    /// After launch or a wake the Mac stays up this long so Wi-Fi can reconnect, the gateway
    /// can come back and the chat bot can fetch a pending request.
    public var checkWindow: TimeInterval = 90
    /// After a viewer leaves or a recording ends, the Mac stays up this long.
    public var graceAfterCapture: TimeInterval = 60
    /// Someone typing or moving the mouse within this time is treated as present. Energy
    /// Saver's own idle sleep is no fallback (sharing services often hold it off), so this is
    /// the only presence timer there is.
    public var idleBeforeSleep: TimeInterval = 300
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
        /// True once the Mac has slept and woken during this run; false after launch.
        public var wokeFromSleep: Bool

        public init(enabled: Bool, canScheduleWake: Bool, captureWanted: Bool, uptime: TimeInterval,
                    wakeUptime: TimeInterval, captureEndedUptime: TimeInterval?, secondsSinceInput: TimeInterval,
                    wokeFromSleep: Bool = false) {
            self.enabled = enabled
            self.canScheduleWake = canScheduleWake
            self.captureWanted = captureWanted
            self.uptime = uptime
            self.wakeUptime = wakeUptime
            self.captureEndedUptime = captureEndedUptime
            self.secondsSinceInput = secondsSinceInput
            self.wokeFromSleep = wokeFromSleep
        }
    }

    /// A Mac that cannot wake itself must not be allowed to sleep, so a missing sudoers rule
    /// keeps today's always-awake standby.
    public func decide(_ inputs: Inputs) -> Decision {
        guard inputs.enabled, inputs.canScheduleWake else { return .holdAwake }
        if inputs.captureWanted { return .holdAwake }
        if inputs.uptime - inputs.wakeUptime < checkWindow { return .holdAwake }
        if let ended = inputs.captureEndedUptime, inputs.uptime - ended < graceAfterCapture { return .holdAwake }
        // The click that put the Mac to sleep, or a keystroke from before it slept, is not
        // presence after the wake: nobody has touched the Mac since. Without this a 5-minute
        // wake cycle never reaches sleepNow again, because the idle clock pauses during sleep.
        if inputs.wokeFromSleep, !inputDuringThisWake(inputs) { return .sleepNow }
        if inputs.secondsSinceInput < idleBeforeSleep { return .allowIdleSleep }
        return .sleepNow
    }

    /// Whether the last input happened after the Mac last woke. The keypress that wakes a Mac
    /// can be stamped a moment before the app records the wake, so a few seconds count as after.
    public func inputDuringThisWake(_ inputs: Inputs) -> Bool {
        inputs.secondsSinceInput < inputs.uptime - inputs.wakeUptime + wakeInputTolerance
    }

    public var wakeInputTolerance: TimeInterval = 5

    /// The decision in the owner's words, for the status board and the Telegram 상태 reply. The
    /// first rule that applies is the one named, in the same order decide() uses, so the text
    /// always explains the decision actually taken.
    public func explain(_ inputs: Inputs) -> String {
        guard inputs.enabled else { return "슬림 모드 꺼짐 · 항상 깨어 있음" }
        guard inputs.canScheduleWake else { return "깨우기 예약 확인 실패 · 안전을 위해 깨어 있음" }
        if inputs.captureWanted { return "카메라 사용 중 · 깨어 있음" }
        let sinceWake = inputs.uptime - inputs.wakeUptime
        if sinceWake < checkWindow {
            return "깨어난 지 \(Int(sinceWake))초 · \(Int(checkWindow - sinceWake) + 1)초 뒤 판단"
        }
        if let ended = inputs.captureEndedUptime, inputs.uptime - ended < graceAfterCapture {
            return "카메라 꺼진 지 \(Int(inputs.uptime - ended))초 · \(Int(graceAfterCapture - (inputs.uptime - ended)) + 1)초 뒤 판단"
        }
        if inputs.wokeFromSleep, !inputDuringThisWake(inputs) { return "깨어난 뒤 입력 없음 · 잠자기 요청" }
        if inputs.secondsSinceInput < idleBeforeSleep {
            let remaining = Int((idleBeforeSleep - inputs.secondsSinceInput) / 60) + 1
            return "마지막 입력 \(Int(inputs.secondsSinceInput / 60))분 전 · 입력 없이 \(remaining)분 더 지나면 잠듦"
        }
        return "잠자기 요청"
    }

    /// When to wake next for the periodic check, or nil without slim mode. Never earlier than a
    /// minute from now, because pmset wants a future time and the Mac is about to sleep. A
    /// remote recording never needs a wake: it keeps the Mac up until it ends.
    public func nextWake(after now: Date, interval: TimeInterval?) -> Date? {
        guard let interval else { return nil }
        return now.addingTimeInterval(max(60, interval))
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
