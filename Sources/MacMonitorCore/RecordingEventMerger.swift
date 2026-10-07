import Darwin
import Foundation

protocol RecordingEventMerging {
    @discardableResult
    func merge(
        segmentURLs: [URL],
        eventStart: Date,
        destinationDirectory: URL
    ) throws -> URL
}

final class FFmpegRecordingEventMerger: RecordingEventMerging {
    private let executableURL: URL
    private let timeout: TimeInterval

    init(executableURL: URL, timeout: TimeInterval = 30) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func merge(
        segmentURLs: [URL],
        eventStart: Date,
        destinationDirectory: URL
    ) throws -> URL {
        guard !segmentURLs.isEmpty else { throw RecordingEventMergeError.noSegments }
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destination = uniqueDestination(for: eventStart, in: destinationDirectory)
        if segmentURLs.count == 1 {
            try FileManager.default.moveItem(at: segmentURLs[0], to: destination)
            return destination
        }

        let identifier = UUID().uuidString
        let concatList = destinationDirectory.appendingPathComponent(".concat-\(identifier).txt")
        let partialOutput = destinationDirectory.appendingPathComponent(".merge-\(identifier).mp4")
        defer {
            try? FileManager.default.removeItem(at: concatList)
            try? FileManager.default.removeItem(at: partialOutput)
        }
        let contents = segmentURLs
            .map { "file '\(escapeForConcat($0.path))'" }
            .joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: concatList, options: .atomic)

        let nullHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? nullHandle.close() }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "concat", "-safe", "0", "-i", concatList.path,
            "-map", "0:v:0", "-c", "copy", "-movflags", "+faststart",
            partialOutput.path
        ]
        process.standardOutput = nullHandle
        process.standardError = nullHandle
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            throw RecordingEventMergeError.timedOut
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: partialOutput.path) else {
            throw RecordingEventMergeError.ffmpegFailed(process.terminationStatus)
        }
        try FileManager.default.moveItem(at: partialOutput, to: destination)
        return destination
    }

    private func uniqueDestination(for date: Date, in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let stem = "motion-\(formatter.string(from: date))"
        var destination = directory.appendingPathComponent("\(stem).mp4")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "\(stem)-\(UUID().uuidString.prefix(8)).mp4"
            )
        }
        return destination
    }

    private func escapeForConcat(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}

enum RecordingEventMergeError: LocalizedError {
    case noSegments
    case timedOut
    case ffmpegFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "병합할 녹화 세그먼트가 없습니다."
        case .timedOut:
            return "녹화 사건 병합 시간이 초과되었습니다."
        case let .ffmpegFailed(status):
            return "녹화 사건 병합에 실패했습니다 (FFmpeg 상태 \(status))."
        }
    }
}
