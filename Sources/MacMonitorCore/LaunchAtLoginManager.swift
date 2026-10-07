import Foundation

public enum LaunchAtLoginManager {
    public static let label = "local.macmonitor.app"

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let applicationURL = Bundle.main.bundleURL
            guard applicationURL.pathExtension.lowercased() == "app" else {
                throw LaunchAtLoginError.applicationBundleRequired
            }
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try propertyListData(applicationURL: applicationURL)
            try data.write(to: launchAgentURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: launchAgentURL.path
            )
        } else if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    static func propertyListData(applicationURL: URL) throws -> Data {
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", applicationURL.path],
            "RunAtLoad": true,
            "ProcessType": "Background"
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }
}

public enum LaunchAtLoginError: LocalizedError {
    case applicationBundleRequired

    public var errorDescription: String? {
        switch self {
        case .applicationBundleRequired:
            return "로그인 시 자동 실행은 빌드된 MacMonitor.app에서만 설정할 수 있습니다."
        }
    }
}
