import CoreMedia
import CoreVideo
import Foundation

public struct FFmpegPipelineConfiguration {
    public let executableURL: URL
    public let spoolDirectory: URL
    public let rtspPublishURL: URL
    public let logURL: URL
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let bitrateKbps: Int
    public let segmentSeconds: Int

    public init(
        executableURL: URL,
        spoolDirectory: URL,
        rtspPublishURL: URL,
        logURL: URL,
        width: Int = 1280,
        height: Int = 720,
        framesPerSecond: Int = 15,
        bitrateKbps: Int = 1_200,
        segmentSeconds: Int = 5
    ) {
        self.executableURL = executableURL
        self.spoolDirectory = spoolDirectory
        self.rtspPublishURL = rtspPublishURL
        self.logURL = logURL
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrateKbps = bitrateKbps
        self.segmentSeconds = segmentSeconds
    }
}

public final class FFmpegPipeline {
    public var failureHandler: ((Error) -> Void)?

    private let configuration: FFmpegPipelineConfiguration
    private let writerQueue = DispatchQueue(label: "com.macmonitor.ffmpeg.writer")
    private let stateLock = NSLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var logHandle: FileHandle?
    private var acceptingFrames = false
    private var terminationSignal = DispatchSemaphore(value: 0)
    private var latestFrame: Data?
    private var pacer: ConstantRateFramePacer
    private var pacingTimer: DispatchSourceTimer?

    public init(configuration: FFmpegPipelineConfiguration) {
        self.configuration = configuration
        pacer = ConstantRateFramePacer(framesPerSecond: configuration.framesPerSecond)
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: configuration.spoolDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configuration.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try LogFileRotator.rotateIfNeeded(at: configuration.logURL)
        if !FileManager.default.fileExists(atPath: configuration.logURL.path) {
            FileManager.default.createFile(atPath: configuration.logURL.path, contents: nil)
        }

        let logHandle = try FileHandle(forWritingTo: configuration.logURL)
        logHandle.seekToEndOfFile()
        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments()
        process.standardInput = inputPipe
        process.standardOutput = logHandle
        process.standardError = logHandle
        terminationSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.stateLock.lock()
            let wasUnexpected = self.acceptingFrames
            self.acceptingFrames = false
            let failureHandler = self.failureHandler
            self.stateLock.unlock()
            self.terminationSignal.signal()
            if wasUnexpected {
                failureHandler?(FFmpegPipelineError.unexpectedExit(terminatedProcess.terminationStatus))
            }
        }

        stateLock.lock()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        self.logHandle = logHandle
        latestFrame = nil
        pacer.reset()
        acceptingFrames = true
        stateLock.unlock()

        do {
            try process.run()
        } catch {
            stateLock.lock()
            acceptingFrames = false
            self.process = nil
            inputHandle = nil
            self.logHandle = nil
            latestFrame = nil
            stateLock.unlock()
            try? inputPipe.fileHandleForWriting.close()
            try? logHandle.close()
            throw error
        }

        startPacing()
    }

    /// Writes to the FFmpeg pipe on the clock rather than on frame arrival, so that the
    /// `-framerate` the input is configured with is what the stream actually carries.
    private func startPacing() {
        let interval = 1 / Double(max(configuration.framesPerSecond, 1))
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitDueFrames(uptime: ProcessInfo.processInfo.systemUptime)
        }
        stateLock.lock()
        let previous = pacingTimer
        pacingTimer = timer
        stateLock.unlock()
        previous?.cancel()
        timer.resume()
    }

    private func emitDueFrames(uptime: TimeInterval) {
        stateLock.lock()
        guard acceptingFrames, let frame = latestFrame, let handle = inputHandle else {
            stateLock.unlock()
            return
        }
        let dueCount = pacer.framesDue(at: uptime)
        stateLock.unlock()
        guard dueCount > 0 else { return }

        do {
            for _ in 0..<dueCount {
                try handle.write(contentsOf: frame)
            }
        } catch {
            reportWriteFailure(error)
        }
    }

    public func consume(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        let isAccepting = acceptingFrames
        stateLock.unlock()
        guard isAccepting else { return }

        guard let frame = NV12FrameCopier.copy(
            pixelBuffer: pixelBuffer,
            width: configuration.width,
            height: configuration.height
        ) else { return }

        // The pacing timer owns the pipe. Handing the newest frame over keeps the capture
        // thread free of the blocking write, and a frame that arrives late is repeated by the
        // pacer rather than shortening the encoded timeline.
        stateLock.lock()
        latestFrame = frame
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        acceptingFrames = false
        let pacingTimer = self.pacingTimer
        self.pacingTimer = nil
        latestFrame = nil
        stateLock.unlock()
        pacingTimer?.cancel()
        writerQueue.sync {}

        stateLock.lock()
        let process = self.process
        let inputHandle = self.inputHandle
        self.inputHandle = nil
        self.process = nil
        stateLock.unlock()

        try? inputHandle?.close()
        if let process, process.isRunning {
            if terminationSignal.wait(timeout: .now() + 5) == .timedOut {
                process.terminate()
                _ = terminationSignal.wait(timeout: .now() + 2)
            }
        }
        try? logHandle?.close()
        logHandle = nil
    }

    private func reportWriteFailure(_ error: Error) {
        stateLock.lock()
        let shouldReport = acceptingFrames
        acceptingFrames = false
        let failureHandler = self.failureHandler
        stateLock.unlock()
        if shouldReport {
            failureHandler?(FFmpegPipelineError.inputWriteFailed(error))
        }
    }

    private func arguments() -> [String] {
        let segmentPattern = configuration.spoolDirectory
            .appendingPathComponent("segment-%Y%m%dT%H%M%S.mp4")
            .path
        let teeTarget = [
            "[f=rtsp:rtsp_transport=tcp:onfail=ignore]\(configuration.rtspPublishURL.absoluteString)",
            "[f=segment:segment_time=\(configuration.segmentSeconds):segment_time_delta=0.033:reset_timestamps=1:strftime=1:segment_format=mp4:segment_format_options=movflags=+faststart:onfail=ignore]\(segmentPattern)"
        ].joined(separator: "|")

        return [
            "-hide_banner", "-loglevel", "warning", "-nostdin",
            "-f", "rawvideo",
            "-pixel_format", "nv12",
            "-video_size", "\(configuration.width)x\(configuration.height)",
            "-framerate", "\(configuration.framesPerSecond)",
            "-i", "pipe:0",
            "-map", "0:v:0",
            "-an",
            "-c:v", "h264_videotoolbox",
            "-realtime", "true",
            "-allow_sw", "1",
            "-profile:v", "main",
            "-b:v", "\(configuration.bitrateKbps)k",
            "-maxrate", "\(configuration.bitrateKbps * 5 / 4)k",
            "-bufsize", "\(configuration.bitrateKbps * 2)k",
            "-g", "\(configuration.framesPerSecond * 2)",
            "-force_key_frames", "expr:gte(t,n_forced*\(configuration.segmentSeconds))",
            "-bf", "0",
            "-flags", "+cgop+global_header",
            "-f", "tee",
            "-use_fifo", "1",
            teeTarget
        ]
    }

    deinit {
        stop()
    }
}

public enum FFmpegPipelineError: LocalizedError {
    case unexpectedExit(Int32)
    case inputWriteFailed(Error)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedExit(status):
            return "FFmpeg 영상 파이프라인이 예기치 않게 종료되었습니다 (상태 \(status))."
        case let .inputWriteFailed(error):
            return "FFmpeg에 영상 프레임을 전달하지 못했습니다: \(error.localizedDescription)"
        }
    }
}
