import Foundation

public struct AppConfiguration: Codable, Equatable {
    public var cameraUniqueID: String?
    public var externalWebRTCHosts: [String]
    public var videoBitrateKbps: Int
    public var motionPixelThreshold: Double
    public var motionChangedFraction: Double
    public var retentionDays: Int
    public var retentionMaxGigabytes: Double
    public var minimumFreeGigabytes: Double
    public var preRollSeconds: Int
    public var postRollSeconds: Int
    public var sleepSchedule: DailySleepSchedule
    public var motionRegions: MotionRegions

    public init(
        cameraUniqueID: String? = nil,
        externalWebRTCHosts: [String] = [],
        videoBitrateKbps: Int = 1_200,
        motionPixelThreshold: Double = 18,
        motionChangedFraction: Double = 0.025,
        retentionDays: Int = 14,
        retentionMaxGigabytes: Double = 20,
        minimumFreeGigabytes: Double = 5,
        preRollSeconds: Int = 30,
        postRollSeconds: Int = 30,
        sleepSchedule: DailySleepSchedule = DailySleepSchedule(),
        motionRegions: MotionRegions = MotionRegions()
    ) {
        self.cameraUniqueID = cameraUniqueID
        self.externalWebRTCHosts = externalWebRTCHosts
        self.videoBitrateKbps = videoBitrateKbps
        self.motionPixelThreshold = motionPixelThreshold
        self.motionChangedFraction = motionChangedFraction
        self.retentionDays = retentionDays
        self.retentionMaxGigabytes = retentionMaxGigabytes
        self.minimumFreeGigabytes = minimumFreeGigabytes
        self.preRollSeconds = preRollSeconds
        self.postRollSeconds = postRollSeconds
        self.sleepSchedule = sleepSchedule
        self.motionRegions = motionRegions
    }

    private enum CodingKeys: String, CodingKey {
        case cameraUniqueID, externalWebRTCHosts, videoBitrateKbps
        case motionPixelThreshold, motionChangedFraction, retentionDays
        case retentionMaxGigabytes, minimumFreeGigabytes
        case preRollSeconds, postRollSeconds, sleepSchedule
        case motionRegions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cameraUniqueID = try values.decodeIfPresent(String.self, forKey: .cameraUniqueID)
        externalWebRTCHosts = try values.decode([String].self, forKey: .externalWebRTCHosts)
        videoBitrateKbps = try values.decode(Int.self, forKey: .videoBitrateKbps)
        motionPixelThreshold = try values.decode(Double.self, forKey: .motionPixelThreshold)
        motionChangedFraction = try values.decode(Double.self, forKey: .motionChangedFraction)
        retentionDays = try values.decode(Int.self, forKey: .retentionDays)
        retentionMaxGigabytes = try values.decode(Double.self, forKey: .retentionMaxGigabytes)
        minimumFreeGigabytes = try values.decode(Double.self, forKey: .minimumFreeGigabytes)
        // Preserve the previous behavior when upgrading an existing installation.
        preRollSeconds = try values.decodeIfPresent(Int.self, forKey: .preRollSeconds) ?? 5
        postRollSeconds = try values.decodeIfPresent(Int.self, forKey: .postRollSeconds) ?? 15
        sleepSchedule = try values.decodeIfPresent(DailySleepSchedule.self, forKey: .sleepSchedule) ?? DailySleepSchedule()
        motionRegions = try values.decodeIfPresent(MotionRegions.self, forKey: .motionRegions) ?? MotionRegions()
    }

    public static func loadOrCreate() throws -> AppConfiguration {
        let configuration = try loadOrCreateForEditing()
        try configuration.validate()
        return configuration
    }

    /// Settings must be able to repair an older motion mask rejected by newer
    /// sampling rules. Runtime consumers must keep using loadOrCreate().
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
        var checked = configuration
        checked.motionRegions = MotionRegions()
        try checked.validate()
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
        guard (0...300).contains(preRollSeconds), (5...300).contains(postRollSeconds) else {
            throw AppConfigurationError.invalid("움직임 전 0~300초 / 후 5~300초")
        }
        try sleepSchedule.validate()
        try motionRegions.validate()
        guard (250...10_000).contains(videoBitrateKbps) else {
            throw AppConfigurationError.invalid("videoBitrateKbps")
        }
        guard (1...100).contains(motionPixelThreshold),
              (0.001...0.8).contains(motionChangedFraction) else {
            throw AppConfigurationError.invalid("motion sensitivity")
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
