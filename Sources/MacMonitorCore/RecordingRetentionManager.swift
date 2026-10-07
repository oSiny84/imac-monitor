import Foundation

public struct RetentionPolicy {
    public let maximumAge: TimeInterval
    public let maximumBytes: Int64
    public let minimumFreeBytes: Int64
    public let preRoll: TimeInterval
    public let postRoll: TimeInterval
    public let segmentDuration: TimeInterval

    public init(
        maximumAge: TimeInterval,
        maximumBytes: Int64,
        minimumFreeBytes: Int64,
        preRoll: TimeInterval = 5,
        postRoll: TimeInterval = 15,
        segmentDuration: TimeInterval = 5
    ) {
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.preRoll = preRoll
        self.postRoll = postRoll
        self.segmentDuration = segmentDuration
    }
}

public final class RecordingRetentionManager {
    private struct MotionWindow {
        var start: Date
        var end: Date
    }

    private struct OwnedFile {
        let url: URL
        let start: Date
        let size: Int64
    }

    private let spoolDirectory: URL
    private let recordingsDirectory: URL
    private let policy: RetentionPolicy
    private let eventMerger: RecordingEventMerging?
    private let queue = DispatchQueue(label: "com.macmonitor.recording-retention")
    private var timer: DispatchSourceTimer?
    private var motionWindows: [MotionWindow] = []

    public init(spoolDirectory: URL, recordingsDirectory: URL, policy: RetentionPolicy) {
        self.spoolDirectory = spoolDirectory
        self.recordingsDirectory = recordingsDirectory
        self.policy = policy
        eventMerger = nil
    }

    init(
        spoolDirectory: URL,
        recordingsDirectory: URL,
        policy: RetentionPolicy,
        eventMerger: RecordingEventMerging
    ) {
        self.spoolDirectory = spoolDirectory
        self.recordingsDirectory = recordingsDirectory
        self.policy = policy
        self.eventMerger = eventMerger
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.scan(now: Date(), finalizing: false) }
            self.timer = timer
            timer.resume()
        }
    }

    public func recordMotion(at timestamp: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            let start = timestamp.addingTimeInterval(-self.policy.preRoll)
            let end = timestamp.addingTimeInterval(self.policy.postRoll)
            if var latest = self.motionWindows.last, start <= latest.end {
                latest.end = max(latest.end, end)
                latest.start = min(latest.start, start)
                self.motionWindows[self.motionWindows.count - 1] = latest
            } else {
                self.motionWindows.append(MotionWindow(start: start, end: end))
            }
        }
    }

    public func stopAndFinalize() {
        queue.sync {
            timer?.cancel()
            timer = nil
            scan(now: Date(), finalizing: true)
        }
    }

    /// Runs a single time-gated maintenance pass as if the clock read `now`.
    /// Tests use this to exercise the promotion and merge gates without waiting for the timer.
    func runMaintenance(now: Date) {
        queue.sync { scan(now: now, finalizing: false) }
    }

    /// The moment a spool segment may be promoted or discarded, once no later motion can
    /// still claim it.
    ///
    /// `mergeFinalizedEvents` derives its own gate from this same function so that a merge
    /// never runs before every segment it needs has reached `recordingsDirectory`. A window
    /// can only overlap segments starting strictly before `window.end`, so waiting until
    /// this moment computed for `window.end` covers all of them.
    private func promotionDecisionTime(segmentStart: Date) -> Date {
        segmentStart.addingTimeInterval(policy.segmentDuration + policy.preRoll + 2)
    }

    private func scan(now: Date, finalizing: Bool) {
        for file in files(in: spoolDirectory) {
            let segmentEnd = file.start.addingTimeInterval(policy.segmentDuration)
            guard finalizing || now >= promotionDecisionTime(segmentStart: file.start) else { continue }

            let keep = motionWindows.contains { window in
                file.start < window.end && segmentEnd > window.start
            }
            if keep {
                moveToRecordings(file.url)
            } else {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
        mergeFinalizedEvents(now: now, finalizing: finalizing)
        motionWindows.removeAll { $0.end < now.addingTimeInterval(-3600) }
        enforceRetention(now: now)
    }

    private func mergeFinalizedEvents(now: Date, finalizing: Bool) {
        guard let eventMerger else { return }
        var completedIndexes: [Int] = []
        for (index, window) in motionWindows.enumerated() {
            let readyAt = promotionDecisionTime(segmentStart: window.end)
            guard finalizing || now >= readyAt else { continue }
            let segments = files(in: recordingsDirectory)
                .filter { file in
                    file.url.lastPathComponent.hasPrefix("segment-") &&
                        file.start < window.end &&
                        file.start.addingTimeInterval(policy.segmentDuration) > window.start
                }
                .sorted { $0.start < $1.start }
            guard !segments.isEmpty else { continue }
            do {
                try eventMerger.merge(
                    segmentURLs: segments.map(\.url),
                    eventStart: window.start,
                    destinationDirectory: recordingsDirectory
                )
                for segment in segments {
                    try? FileManager.default.removeItem(at: segment.url)
                }
                completedIndexes.append(index)
            } catch {
                continue
            }
        }
        for index in completedIndexes.reversed() {
            motionWindows.remove(at: index)
        }
    }

    private func moveToRecordings(_ source: URL) {
        var destination = recordingsDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            destination = recordingsDirectory
                .appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).mp4")
        }
        try? FileManager.default.moveItem(at: source, to: destination)
    }

    private func enforceRetention(now: Date) {
        var recordings = files(in: recordingsDirectory).sorted { $0.start < $1.start }
        for file in recordings where now.timeIntervalSince(file.start) > policy.maximumAge {
            try? FileManager.default.removeItem(at: file.url)
        }
        recordings = files(in: recordingsDirectory).sorted { $0.start < $1.start }

        var totalBytes = recordings.reduce(Int64(0)) { $0 + $1.size }
        var freeBytes = availableBytes()
        for file in recordings {
            guard totalBytes > policy.maximumBytes || freeBytes < policy.minimumFreeBytes else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalBytes -= file.size
                freeBytes += file.size
            } catch {
                continue
            }
        }
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
