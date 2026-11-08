import Foundation

public struct RetentionPolicy {
    public let maximumAge: TimeInterval
    public let maximumBytes: Int64
    public let minimumFreeBytes: Int64
    /// Length of the clips FFmpeg writes. A clip is moved out of the spool this long plus a
    /// margin after its start, once FFmpeg has closed it.
    public let segmentDuration: TimeInterval

    public init(
        maximumAge: TimeInterval,
        maximumBytes: Int64,
        minimumFreeBytes: Int64,
        segmentDuration: TimeInterval = 600
    ) {
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.segmentDuration = segmentDuration
    }
}

/// Moves closed clips from the spool into the recordings folder and keeps that folder within
/// the age, size and free-space limits. Every clip is kept: a recording is something the owner
/// started on purpose, so there is nothing to select from it. Protected recordings are never
/// deleted; the web's own delete takes the same lock this pass takes.
public final class RecordingRetentionManager {
    private struct OwnedFile {
        let url: URL
        let start: Date
        let size: Int64
    }

    private let spoolDirectory: URL
    private let recordingsDirectory: URL
    private let policy: RetentionPolicy
    private let queue = DispatchQueue(label: "com.macmonitor.recording-retention")
    private var timer: DispatchSourceTimer?
    private let onWarning: ((String?) -> Void)?
    private let onPromoted: ((URL) -> Void)?
    private var lastWarning: String?
    private var publishedWarning = false

    public init(spoolDirectory: URL, recordingsDirectory: URL, policy: RetentionPolicy,
                onWarning: ((String?) -> Void)? = nil, onPromoted: ((URL) -> Void)? = nil) {
        self.spoolDirectory = spoolDirectory
        self.recordingsDirectory = recordingsDirectory
        self.policy = policy
        self.onWarning = onWarning
        self.onPromoted = onPromoted
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        queue.sync {
            guard timer == nil else { return }
            let scanTimer = DispatchSource.makeTimerSource(queue: queue)
            scanTimer.schedule(deadline: .now() + 2, repeating: 2)
            scanTimer.setEventHandler { [weak self] in self?.scan(now: Date(), finalizing: false) }
            self.timer = scanTimer
            scanTimer.resume()
        }
    }

    /// Stops the timer and promotes whatever is left in the spool, so the clip FFmpeg just
    /// closed at the end of a recording is not lost.
    public func stopAndFinalize() {
        queue.sync {
            timer?.cancel()
            timer = nil
            scan(now: Date(), finalizing: true)
        }
    }

    /// Runs a single time-gated maintenance pass as if the clock read `now`.
    /// Tests use this to exercise the promotion gate without waiting for the timer.
    func runMaintenance(now: Date) {
        queue.sync { scan(now: now, finalizing: false) }
    }

    /// A clip is only safe to move once FFmpeg has closed it. Ten seconds past its nominal end
    /// covers a late keyframe.
    private func promotionDecisionTime(segmentStart: Date) -> Date {
        segmentStart.addingTimeInterval(policy.segmentDuration + 10)
    }

    private func scan(now: Date, finalizing: Bool) {
        for file in files(in: spoolDirectory) {
            guard finalizing || now >= promotionDecisionTime(segmentStart: file.start) else { continue }
            if let destination = moveToRecordings(file.url) { onPromoted?(destination) }
        }
        enforceRetention(now: now)
    }

    private func moveToRecordings(_ source: URL) -> URL? {
        var destination = recordingsDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            destination = recordingsDirectory
                .appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).mp4")
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func enforceRetention(now: Date) {
        let protections = RecordingProtectionStore(directory: recordingsDirectory)
        do {
            try protections.withExclusiveLock {
                try enforceUnlockedRetention(now: now, protections: protections)
            }
        } catch {
            reportRetentionWarning("보호 상태 확인 또는 잠금 실패 · 자동 삭제를 보류합니다. 저장 공간과 진단 로그를 확인하세요.")
        }
    }

    private func enforceUnlockedRetention(now: Date, protections: RecordingProtectionStore) throws {
        var recordings = files(in: recordingsDirectory).sorted { $0.start < $1.start }
        for file in recordings where now.timeIntervalSince(file.start) > policy.maximumAge {
            guard !(try protections.isProtected(file.url)) else { continue }
            try? FileManager.default.removeItem(at: file.url)
        }
        recordings = files(in: recordingsDirectory).sorted { $0.start < $1.start }

        var totalBytes = recordings.reduce(Int64(0)) { $0 + $1.size }
        var freeBytes = availableBytes()
        for file in recordings {
            guard totalBytes > policy.maximumBytes || freeBytes < policy.minimumFreeBytes else { break }
            guard !(try protections.isProtected(file.url)) else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalBytes -= file.size
                freeBytes += file.size
            } catch {
                continue
            }
        }
        if totalBytes > policy.maximumBytes || freeBytes < policy.minimumFreeBytes {
            reportRetentionWarning("보관 용량 또는 디스크 여유 기준을 충족하지 못했습니다. 보호된 영상은 삭제하지 않습니다. 백업 후 보호 해제 또는 공간 확보가 필요하며 새 녹화가 실패할 수 있습니다.")
        } else { reportRetentionWarning(nil) }
    }

    private func reportRetentionWarning(_ value: String?) {
        guard !publishedWarning || value != lastWarning else { return }
        publishedWarning = true
        lastWarning = value
        if let value { NSLog("MacMonitor retention: %@", value) }
        onWarning?(value)
    }

    private func files(in directory: URL) -> [OwnedFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mp4",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return OwnedFile(
                url: url,
                start: Self.timestamp(from: url.lastPathComponent) ?? values.contentModificationDate ?? Date.distantPast,
                size: Int64(values.fileSize ?? 0)
            )
        }
    }

    private func availableBytes() -> Int64 {
        if let values = try? recordingsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: recordingsDirectory.path),
              let value = attributes[.systemFreeSize] as? NSNumber else { return Int64.max }
        return value.int64Value
    }

    private static func timestamp(from filename: String) -> Date? {
        guard let range = filename.range(of: #"\d{8}T\d{6}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: String(filename[range]))
    }

    deinit {
        timer?.cancel()
    }
}
