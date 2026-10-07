import CoreMedia
import Foundation

public final class LocalMonitoringPipeline: MonitoringPipelineControlling {
    public var failureHandler: ((Error) -> Void)?

    private let stateLock = NSLock()
    private var detector: MotionDetector?
    private var retention: RecordingRetentionManager?
    private var mediaServer: MediaMTXSupervisor?
    private var encoder: FFmpegPipeline?
    private var gateway: GatewaySupervisor?
    private var starting = false
    private var started = false

    public init() {}

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
            additionalHosts: configuration.externalWebRTCHosts
        )
        let retention = RecordingRetentionManager(
            spoolDirectory: AppDirectories.spool,
            recordingsDirectory: AppDirectories.recordings,
            policy: RetentionPolicy(
                maximumAge: TimeInterval(configuration.retentionDays) * 86_400,
                maximumBytes: Int64(configuration.retentionMaxGigabytes * 1_073_741_824),
                minimumFreeBytes: Int64(configuration.minimumFreeGigabytes * 1_073_741_824)
            ),
            eventMerger: FFmpegRecordingEventMerger(executableURL: ffmpegURL)
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
        let gateway = GatewaySupervisor()
        mediaServer.failureHandler = { [weak self] error in
            self?.reportFailure(error)
        }
        encoder.failureHandler = { [weak self] error in
            self?.reportFailure(error)
        }
        gateway.failureHandler = { [weak self] error in
            self?.reportFailure(error)
        }

        do {
            try mediaServer.start()
            try retention.start()
            try encoder.start()
            _ = try gateway.startIfConfigured()
        } catch {
            encoder.stop()
            retention.stopAndFinalize()
            gateway.stop()
            mediaServer.stop()
            throw error
        }

        detector = MotionDetector(
            configuration: MotionConfiguration(
                pixelDifferenceThreshold: configuration.motionPixelThreshold,
                changedPixelFraction: configuration.motionChangedFraction
            )
        )
        self.retention = retention
        self.mediaServer = mediaServer
        self.encoder = encoder
        self.gateway = gateway
        stateLock.lock()
        started = true
        stateLock.unlock()
    }

    public func consume(sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let isStarted = started
        stateLock.unlock()
        guard isStarted else { return }
        if let observation = detector?.analyze(sampleBuffer: sampleBuffer), observation.isMotion {
            retention?.recordMotion(at: observation.timestamp)
        }
        encoder?.consume(sampleBuffer: sampleBuffer)
    }

    public func stop() {
        stateLock.lock()
        guard started || starting else {
            stateLock.unlock()
            return
        }
        started = false
        starting = false
        stateLock.unlock()
        encoder?.stop()
        retention?.stopAndFinalize()
        gateway?.stop()
        mediaServer?.stop()
        detector?.reset()
        detector = nil
        retention = nil
        encoder = nil
        gateway = nil
        mediaServer = nil
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
