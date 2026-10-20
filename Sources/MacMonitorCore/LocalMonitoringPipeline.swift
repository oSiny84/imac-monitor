import CoreMedia
import Foundation

public final class LocalMonitoringPipeline: MonitoringPipelineControlling {
    public var failureHandler: ((Error) -> Void)?

    private let stateLock = NSLock()
    private var detector: MotionDetector?
    private var retention: RecordingRetentionManager?
    private var mediaServer: MediaMTXSupervisor?
    private var encoder: FFmpegPipeline?
    private var starting = false
    private var started = false
    private let healthReporter: MonitoringHealthReporter?

    public init(healthReporter: MonitoringHealthReporter? = nil) {
        self.healthReporter = healthReporter
        healthReporter?.onStall = { [weak self] in
            self?.reportFailure(CaptureFrameStallError())
        }
    }

    public func start() throws {
        stateLock.lock()
        let canStart = !started && !starting
        if canStart {
            starting = true
        }
        stateLock.unlock()
        guard canStart else { return }
        defer {
            stateLock.lock()
            starting = false
            stateLock.unlock()
        }
        try AppDirectories.prepare()
        let configuration = try AppConfiguration.loadOrCreate()
        let ffmpegURL = try RuntimeDependencyLocator.ffmpeg()
        try FileManager.default.createDirectory(at: AppDirectories.diagnostics, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppDirectories.runtime, withIntermediateDirectories: true)

        let mediaServer = MediaMTXSupervisor(
            executableURL: try RuntimeDependencyLocator.mediaMTX(),
            configurationURL: AppDirectories.runtime.appendingPathComponent("mediamtx.yml"),
            logURL: AppDirectories.diagnostics.appendingPathComponent("mediamtx.log"),
            additionalHosts: configuration.externalWebRTCHosts,
            ffmpegURL: ffmpegURL
        )
        let reporter = healthReporter
        let retention = RecordingRetentionManager(
            spoolDirectory: AppDirectories.spool,
            recordingsDirectory: AppDirectories.recordings,
            policy: RetentionPolicy(
                maximumAge: TimeInterval(configuration.retentionDays) * 86_400,
                maximumBytes: Int64(configuration.retentionMaxGigabytes * 1_073_741_824),
                minimumFreeBytes: Int64(configuration.minimumFreeGigabytes * 1_073_741_824),
                preRoll: TimeInterval(configuration.preRollSeconds),
                postRoll: TimeInterval(configuration.postRollSeconds)
            ),
            eventMerger: FFmpegRecordingEventMerger(executableURL: ffmpegURL, onCompleted: { [weak reporter] url in
                reporter?.recordRecording(at: url)
            }),
            onWarning: { [weak reporter] warning in reporter?.recordRetentionWarning(warning) }
        )
        let encoder = FFmpegPipeline(
            configuration: FFmpegPipelineConfiguration(
                executableURL: ffmpegURL,
                spoolDirectory: AppDirectories.spool,
                rtspPublishURL: URL(string: "rtsp://127.0.0.1:8554/live")!,
                logURL: AppDirectories.diagnostics.appendingPathComponent("ffmpeg.log"),
                bitrateKbps: configuration.videoBitrateKbps
            )
        )
        mediaServer.failureHandler = { [weak self] error in
            self?.reportFailure(error)
        }
        encoder.failureHandler = { [weak self] error in
            self?.reportFailure(error)
        }

        do {
            try mediaServer.start()
            try retention.start()
            try encoder.start()
        } catch {
            encoder.stop()
            retention.stopAndFinalize()
            mediaServer.stop()
            throw error
        }

        let detector = MotionDetector(
            configuration: MotionConfiguration(
                pixelDifferenceThreshold: configuration.motionPixelThreshold,
                changedPixelFraction: configuration.motionChangedFraction,
                regions: configuration.motionRegions
            )
        )
        stateLock.lock()
        guard starting else {
            stateLock.unlock()
            encoder.stop()
            retention.stopAndFinalize()
            mediaServer.stop()
            throw LocalMonitoringPipelineError.startCancelled
        }
        self.detector = detector
        self.retention = retention
        self.mediaServer = mediaServer
        self.encoder = encoder
        started = true
        starting = false
        stateLock.unlock()
    }

    public func consume(sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        guard started,
              let detector,
              let retention,
              let encoder else {
            stateLock.unlock()
            return
        }
        if let observation = detector.analyze(sampleBuffer: sampleBuffer), observation.isMotion {
            retention.recordMotion(at: observation.timestamp)
            healthReporter?.recordMotion(at: observation.timestamp)
        }
        let samplingError = detector.takeSamplingError()
        encoder.consume(sampleBuffer: sampleBuffer)
        stateLock.unlock()
        // Failure handling can stop/restart the pipeline and must run outside its lock.
        if let samplingError {
            reportFailure(samplingError)
        }
    }

    public func stop() {
        stateLock.lock()
        guard started || starting else {
            stateLock.unlock()
            return
        }
        started = false
        starting = false
        let detector = self.detector
        let retention = self.retention
        let mediaServer = self.mediaServer
        let encoder = self.encoder
        self.detector = nil
        self.retention = nil
        self.encoder = nil
        self.mediaServer = nil
        stateLock.unlock()
        encoder?.stop()
        retention?.stopAndFinalize()
        mediaServer?.stop()
        detector?.reset()
    }

    private func reportFailure(_ error: Error) {
        stateLock.lock()
        let shouldReport = started || starting
        let failureHandler = self.failureHandler
        stateLock.unlock()
        if shouldReport {
            failureHandler?(error)
        }
    }

    deinit { stop() }
}

private struct CaptureFrameStallError: LocalizedError {
    var errorDescription: String? { "카메라에서 새 프레임이 들어오지 않아 감시를 다시 시작합니다." }
}

public enum LocalMonitoringPipelineError: LocalizedError {
    case startCancelled

    public var errorDescription: String? {
        "감시 파이프라인 시작이 중지 요청으로 취소되었습니다."
    }
}
