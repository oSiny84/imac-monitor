import Foundation

public enum AppDirectories {
    public static let root: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacMonitor", isDirectory: true)
    }()

    public static let diagnostics = root.appendingPathComponent("Diagnostics", isDirectory: true)
    public static let spool = root.appendingPathComponent("Spool", isDirectory: true)
    public static let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    public static let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
    public static let configuration = root.appendingPathComponent("config.json")
    public static let gatewayConfiguration = root.appendingPathComponent("gateway.json")
    public static let monitoringStatus = runtime.appendingPathComponent("monitoring-status.json")

    public static func prepare() throws {
        for directory in [root, diagnostics, spool, recordings, runtime] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
