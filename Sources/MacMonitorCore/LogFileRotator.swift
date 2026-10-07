import Foundation

enum LogFileRotator {
    static func rotateIfNeeded(
        at url: URL,
        maximumBytes: Int64 = 10 * 1_024 * 1_024,
        backupCount: Int = 3
    ) throws {
        guard maximumBytes > 0, backupCount > 0,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw LogFileRotationError.notRegularFile }
        guard Int64(values.fileSize ?? 0) >= maximumBytes else { return }

        let oldest = backupURL(for: url, index: backupCount)
        if FileManager.default.fileExists(atPath: oldest.path) {
            try FileManager.default.removeItem(at: oldest)
        }
        if backupCount > 1 {
            for index in stride(from: backupCount - 1, through: 1, by: -1) {
                let source = backupURL(for: url, index: index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.moveItem(
                    at: source,
                    to: backupURL(for: url, index: index + 1)
                )
            }
        }
        try FileManager.default.moveItem(at: url, to: backupURL(for: url, index: 1))
    }

    private static func backupURL(for url: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(url.path).\(index)")
    }
}

enum LogFileRotationError: LocalizedError {
    case notRegularFile

    var errorDescription: String? {
        "진단 로그 경로가 일반 파일이 아닙니다."
    }
}
