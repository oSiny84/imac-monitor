import Foundation

public enum RuntimeDependencyError: LocalizedError {
    case missing(String, searched: [String])

    public var errorDescription: String? {
        switch self {
        case let .missing(name, searched):
            return "\(name)을 찾을 수 없습니다. 확인한 경로: \(searched.joined(separator: ", "))"
        }
    }
}

public enum RuntimeDependencyLocator {
    public static func ffmpeg() throws -> URL {
        try find(
            name: "ffmpeg",
            candidates: [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg"),
                URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
                URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            ]
        )
    }

    public static func mediaMTX() throws -> URL {
        try find(
            name: "MediaMTX",
            candidates: [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mediamtx"),
                URL(fileURLWithPath: "/usr/local/bin/mediamtx"),
                URL(fileURLWithPath: "/opt/homebrew/bin/mediamtx")
            ]
        )
    }

    public static func gateway() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/macmonitor-gateway")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func find(name: String, candidates: [URL]) throws -> URL {
        if let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return result
        }
        throw RuntimeDependencyError.missing(name, searched: candidates.map(\.path))
    }
}
