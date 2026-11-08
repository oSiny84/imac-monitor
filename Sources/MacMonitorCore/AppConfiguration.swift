import Foundation

public struct AppConfiguration: Codable, Equatable {
    public var cameraUniqueID: String?
    public var externalWebRTCHosts: [String]
    public var videoBitrateKbps: Int
    public var retentionDays: Int
    public var retentionMaxGigabytes: Double
    public var minimumFreeGigabytes: Double
    public var sleepSchedule: DailySleepSchedule
    /// Lets an authenticated web viewer turn the camera on or start a timed recording. Off
    /// refuses both.
    public var liveStandby: Bool
    /// Lets the Mac sleep between remote requests and wake on a timer to check for them.
    public var slimMode: SlimModeSettings
    /// Captures the microphone with the video for the live stream and the files.
    public var audioEnabled: Bool

    public init(
        cameraUniqueID: String? = nil,
        externalWebRTCHosts: [String] = [],
        videoBitrateKbps: Int = 1_200,
        retentionDays: Int = 14,
        retentionMaxGigabytes: Double = 20,
        minimumFreeGigabytes: Double = 5,
        sleepSchedule: DailySleepSchedule = DailySleepSchedule(),
        slimMode: SlimModeSettings = SlimModeSettings(),
        liveStandby: Bool = true,
        audioEnabled: Bool = true
    ) {
        self.cameraUniqueID = cameraUniqueID
        self.externalWebRTCHosts = externalWebRTCHosts
        self.videoBitrateKbps = videoBitrateKbps
        self.retentionDays = retentionDays
        self.retentionMaxGigabytes = retentionMaxGigabytes
        self.minimumFreeGigabytes = minimumFreeGigabytes
        self.sleepSchedule = sleepSchedule
        self.slimMode = slimMode
        self.liveStandby = liveStandby
        self.audioEnabled = audioEnabled
    }

    // Settings files from earlier builds also carry motion-recording keys (motionPixelThreshold,
    // motionChangedFraction, preRollSeconds, postRollSeconds, motionRegions) and, from the
    // 2026-11-08 daytime build, recordingSchedule. Keyed decoding ignores keys not listed here.
    private enum CodingKeys: String, CodingKey {
        case cameraUniqueID, externalWebRTCHosts, videoBitrateKbps
        case retentionDays, retentionMaxGigabytes, minimumFreeGigabytes
        case sleepSchedule, liveStandby, slimMode, audioEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cameraUniqueID = try values.decodeIfPresent(String.self, forKey: .cameraUniqueID)
        externalWebRTCHosts = try values.decode([String].self, forKey: .externalWebRTCHosts)
        videoBitrateKbps = try values.decode(Int.self, forKey: .videoBitrateKbps)
        retentionDays = try values.decode(Int.self, forKey: .retentionDays)
        retentionMaxGigabytes = try values.decode(Double.self, forKey: .retentionMaxGigabytes)
        minimumFreeGigabytes = try values.decode(Double.self, forKey: .minimumFreeGigabytes)
        // Preserve the previous behavior when upgrading an existing installation.
        sleepSchedule = try values.decodeIfPresent(DailySleepSchedule.self, forKey: .sleepSchedule) ?? DailySleepSchedule()
        liveStandby = try values.decodeIfPresent(Bool.self, forKey: .liveStandby) ?? true
        slimMode = try values.decodeIfPresent(SlimModeSettings.self, forKey: .slimMode) ?? SlimModeSettings()
        // Sound is on unless the owner turned it off; earlier settings files never had the key.
        audioEnabled = try values.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
    }

    public static func loadOrCreate() throws -> AppConfiguration {
        let configuration = try loadOrCreateForEditing()
        try configuration.validate()
        return configuration
    }

    /// Settings and the runtime read the same file; the name remains from when the settings
    /// window could repair a value the runtime rejected.
    public static func loadOrCreateForEditing() throws -> AppConfiguration {
        try AppDirectories.prepare()
        if FileManager.default.fileExists(atPath: AppDirectories.configuration.path) {
            let data = try Data(contentsOf: AppDirectories.configuration)
            return try decodeForEditing(data)
        }

        let configuration = AppConfiguration()
        try configuration.save()
        return configuration
    }

    public static func decodeForEditing(_ data: Data) throws -> AppConfiguration {
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    public func save() throws {
        try validate()
        try AppDirectories.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: AppDirectories.configuration, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppDirectories.configuration.path
        )
    }

    public func validate() throws {
        try sleepSchedule.validate()
        try slimMode.validate()
        guard (250...10_000).contains(videoBitrateKbps) else {
            throw AppConfigurationError.invalid("videoBitrateKbps")
        }
        guard (1...3650).contains(retentionDays),
              (0.1...10_000).contains(retentionMaxGigabytes),
              (0.1...1_000).contains(minimumFreeGigabytes) else {
            throw AppConfigurationError.invalid("retention policy")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard externalWebRTCHosts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw AppConfigurationError.invalid("externalWebRTCHosts")
        }
    }
}

public enum AppConfigurationError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(field):
            return "설정값이 올바르지 않습니다: \(field)"
        }
    }
}
