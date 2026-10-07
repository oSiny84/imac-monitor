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

    public init(
        cameraUniqueID: String? = nil,
        externalWebRTCHosts: [String] = [],
        videoBitrateKbps: Int = 1_200,
        motionPixelThreshold: Double = 18,
        motionChangedFraction: Double = 0.025,
        retentionDays: Int = 14,
        retentionMaxGigabytes: Double = 20,
        minimumFreeGigabytes: Double = 5
    ) {
        self.cameraUniqueID = cameraUniqueID
        self.externalWebRTCHosts = externalWebRTCHosts
        self.videoBitrateKbps = videoBitrateKbps
        self.motionPixelThreshold = motionPixelThreshold
        self.motionChangedFraction = motionChangedFraction
        self.retentionDays = retentionDays
        self.retentionMaxGigabytes = retentionMaxGigabytes
        self.minimumFreeGigabytes = minimumFreeGigabytes
    }

    public static func loadOrCreate() throws -> AppConfiguration {
        try AppDirectories.prepare()
        if FileManager.default.fileExists(atPath: AppDirectories.configuration.path) {
            let data = try Data(contentsOf: AppDirectories.configuration)
            let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
            try configuration.validate()
            return configuration
        }

        let configuration = AppConfiguration()
        try configuration.save()
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
