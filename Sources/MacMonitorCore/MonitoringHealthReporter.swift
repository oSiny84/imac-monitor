import Foundation

public enum MonitoringPauseReason: String {
    case manualStop = "stopped"
    case scheduledRest
    case systemSleep = "sleeping"
}

struct MonitoringHealthSnapshot: Codable {
    let schemaVersion: Int
    var updatedAt: Date
    let state: String
    let detail: String
    let expectingFrames: Bool
    let captureStartedAt: Date?
    let lastFrameAt: Date?
    let captureFPS: Double
    let totalFrames: UInt64
    let lastMotionAt: Date?
    let lastRecordingAt: Date?
    let lastRecordingName: String?
    var diskFreeBytes: Int64?
    let watchdogRecoveries: Int
    let lastRecoveryAt: Date?
    let retentionWarning: String?
}

/// A small private, atomically replaced status file is read by the independent
/// HTTPS gateway. Frame callbacks only update memory; they never write to disk.
public final class MonitoringHealthReporter {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.macmonitor.monitoring-health")
    private let statusURL: URL
    private let recordingsDirectory: URL
    private var timer: DispatchSourceTimer?
    private var enabled = false
    private var coordinatorState: MonitoringState = .idle
    private var pauseReason: MonitoringPauseReason? = .manualStop
    private var activity = FrameActivityTracker()
    private var captureStartedAt: Date?
    private var lastFrameAt: Date?
    private var lastMotionAt: Date?
    private var lastRecordingAt: Date?
    private var lastRecordingName: String?
    private var watchdogRecoveries = 0
    private var lastRecoveryAt: Date?
    private var stallHandler: (() -> Void)?
    private var reportedWriteError = false // queue-owned
    private var retentionWarning: String?

    public var onStall: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stallHandler }
        set { lock.lock(); defer { lock.unlock() }; stallHandler = newValue }
    }

    public init(statusURL: URL = AppDirectories.monitoringStatus,
                recordingsDirectory: URL = AppDirectories.recordings) {
        self.statusURL = statusURL
        self.recordingsDirectory = recordingsDirectory
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.enabled = true
            self.lock.unlock()
            if self.timer == nil {
                self.loadLastRecording()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 2)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            }
        }
    }

    public func updateState(_ state: MonitoringState) {
        lock.lock()
        coordinatorState = state
        updateExpectation()
        lock.unlock()
        queue.async { [weak self] in self?.tick() }
    }

    public func setPauseReason(_ reason: MonitoringPauseReason?) {
        lock.lock()
        guard pauseReason != reason else { lock.unlock(); return }
        pauseReason = reason
        updateExpectation()
        lock.unlock()
        queue.async { [weak self] in self?.tick() }
    }

    public func recordFrame(at date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        lastFrameAt = date
        activity.recordFrame(at: uptime)
    }

    public func recordMotion(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        lastMotionAt = date
    }

    public func recordRetentionWarning(_ warning: String?) {
        lock.lock(); defer { lock.unlock() }
        retentionWarning = warning
    }

    public func recordRecording(at url: URL, completedAt date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if lastRecordingAt == nil || date > lastRecordingAt! {
            lastRecordingAt = date
            lastRecordingName = url.lastPathComponent
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            if let self {
                self.timer?.cancel()
                self.timer = nil
                self.lock.lock()
                self.enabled = false
                self.pauseReason = .manualStop
                self.coordinatorState = .idle
                self.activity.stop()
                let snapshot = self.snapshot(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                self.lock.unlock()
                self.write(snapshot)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    // Called with lock held. Starting/recovering/paused states do not run a watchdog.
    private func updateExpectation() {
        let running: Bool
        if case .running = coordinatorState { running = pauseReason == nil } else { running = false }
        if running && !activity.isActive {
            activity.start(at: ProcessInfo.processInfo.systemUptime)
            captureStartedAt = Date()
        } else if !running { activity.stop() }
    }

    private func tick() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let stalled = activity.takeStall(at: uptime)
        if stalled { watchdogRecoveries += 1; lastRecoveryAt = now }
        let callback = stalled ? stallHandler : nil
        let value = snapshot(now: now, uptime: uptime)
        lock.unlock()
        // Invoke recovery outside our lock and before any potentially failing disk I/O.
        callback?()
        write(value)
    }

    // Called with lock held.
    private func snapshot(now: Date, uptime: TimeInterval) -> MonitoringHealthSnapshot {
        let state: String
        let detail: String
        if let pauseReason {
            state = pauseReason.rawValue
            switch pauseReason {
            case .manualStop: detail = "수동 감시 중지"
            case .scheduledRest: detail = "예약 휴식 중"
            case .systemSleep: detail = "시스템 잠자기"
            }
        } else {
            switch coordinatorState {
            case .idle: state = "stopped"
            case .requestingCameraPermission, .starting: state = "starting"
            case .running: state = "running"
            case .stopping: state = "stopping"
            case .recovering: state = "recovering"
            case .failed: state = "failed"
            }
            detail = coordinatorState.displayText
        }
        return MonitoringHealthSnapshot(schemaVersion: 1, updatedAt: now,
            state: state, detail: detail, expectingFrames: activity.isActive,
            captureStartedAt: captureStartedAt, lastFrameAt: lastFrameAt,
            captureFPS: activity.takeFPS(at: uptime), totalFrames: activity.frames,
            lastMotionAt: lastMotionAt, lastRecordingAt: lastRecordingAt,
            lastRecordingName: lastRecordingName, diskFreeBytes: nil,
            watchdogRecoveries: watchdogRecoveries, lastRecoveryAt: lastRecoveryAt,
            retentionWarning: retentionWarning)
    }

    private func write(_ snapshot: MonitoringHealthSnapshot) {
        var value = snapshot
        value.diskFreeBytes = freeDiskBytes()
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: statusURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
            reportedWriteError = false
        } catch {
            if !reportedWriteError { NSLog("MacMonitor: monitoring status write failed: %@", error.localizedDescription) }
            reportedWriteError = true
        }
    }

    private func freeDiskBytes() -> Int64? {
        if let values = try? recordingsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage, bytes >= 0 { return bytes }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: recordingsDirectory.path)
        guard let bytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value, bytes >= 0 else { return nil }
        return bytes
    }

    private func loadLastRecording() {
        let key = URLResourceKey.contentModificationDateKey
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory,
            includingPropertiesForKeys: [key, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension == "mp4" && file.lastPathComponent.hasPrefix("motion-") {
            if let values = try? file.resourceValues(forKeys: [key, .isRegularFileKey]),
               values.isRegularFile == true, let date = values.contentModificationDate {
                recordRecording(at: file, completedAt: date)
            }
        }
    }

    deinit { timer?.cancel() }
}
