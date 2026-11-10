import CoreMedia
import CoreVideo
import Darwin
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
    /// Stem of the clip files: motion spool segments and remote clips must stay distinguishable.
    public let segmentFilePrefix: String
    /// False publishes the live stream only and writes nothing to the spool.
    public let recordingEnabled: Bool
    /// Nil keeps the stream silent. Otherwise raw PCM arrives through a named pipe and is
    /// encoded twice: Opus for WebRTC viewers and AAC for the MP4 files.
    public let audio: FFmpegAudioConfiguration?

    public init(
        executableURL: URL,
        spoolDirectory: URL,
        rtspPublishURL: URL,
        logURL: URL,
        width: Int = 1280,
        height: Int = 720,
        framesPerSecond: Int = 15,
        bitrateKbps: Int = 1_200,
        segmentSeconds: Int = 5,
        segmentFilePrefix: String = "segment",
        recordingEnabled: Bool = true,
        audio: FFmpegAudioConfiguration? = nil
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
        self.segmentFilePrefix = segmentFilePrefix
        self.recordingEnabled = recordingEnabled
        self.audio = audio
    }
}

public struct FFmpegAudioConfiguration: Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let liveBitrateKbps: Int
    public let recordingBitrateKbps: Int
    /// Where the named pipe lives; the runtime directory is private to the user.
    public let fifoDirectory: URL

    public init(
        sampleRate: Int = 48_000,
        channels: Int = 1,
        liveBitrateKbps: Int = 48,
        recordingBitrateKbps: Int = 64,
        fifoDirectory: URL = AppDirectories.runtime
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.liveBitrateKbps = liveBitrateKbps
        self.recordingBitrateKbps = recordingBitrateKbps
        self.fifoDirectory = fifoDirectory
    }

    var bytesPerSample: Int { 2 * channels }
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
    // Audio reaches FFmpeg through a named pipe read as a second input. It is opened read-write
    // so neither side blocks on open and a reader that died cannot raise SIGPIPE here. Writes
    // are non-blocking: a full pipe drops samples that the aligner later replaces with silence.
    private let audioQueue = DispatchQueue(label: "com.macmonitor.ffmpeg.audio")
    private var audioFileDescriptor: Int32 = -1
    private var audioFIFOPath: String?
    private var aligner: AudioTimelineAligner?
    private var lastAudioReport: TimeInterval = 0 // audioQueue-owned

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
        let inputPipe: Pipe
        do {
            inputPipe = try Self.makeInputPipe()
        } catch {
            try? logHandle.close()
            throw error
        }
        var audioPipe: (path: String, descriptor: Int32)?
        if let audio = configuration.audio {
            do {
                audioPipe = try Self.openAudioPipe(in: audio.fifoDirectory)
            } catch {
                try? inputPipe.fileHandleForWriting.close()
                try? logHandle.close()
                throw error
            }
        }
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments(audioInput: audioPipe?.path)
        process.standardInput = inputPipe
        process.standardOutput = logHandle
        process.standardError = logHandle
        let terminationSignal = DispatchSemaphore(value: 0)
        self.terminationSignal = terminationSignal
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.stateLock.lock()
            let ownsProcess = self.process.map { $0 === terminatedProcess } ?? false
            let wasUnexpected = ownsProcess && self.acceptingFrames
            if ownsProcess {
                self.acceptingFrames = false
            }
            let failureHandler = self.failureHandler
            self.stateLock.unlock()
            terminationSignal.signal()
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
        audioFileDescriptor = audioPipe?.descriptor ?? -1
        audioFIFOPath = audioPipe?.path
        aligner = configuration.audio.map {
            AudioTimelineAligner(sampleRate: $0.sampleRate, framesPerSecond: configuration.framesPerSecond)
        }
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
            audioFileDescriptor = -1
            audioFIFOPath = nil
            aligner = nil
            stateLock.unlock()
            try? inputPipe.fileHandleForWriting.close()
            Self.closeAudioPipe(audioPipe)
            try? logHandle.close()
            throw error
        }

        startPacing()
    }

    /// Creates the named pipe FFmpeg reads audio from. A stale pipe from a crashed run is
    /// replaced. O_RDWR means this open never waits for FFmpeg and FFmpeg's open never waits
    /// for us; O_NONBLOCK keeps a full pipe from stalling the audio queue.
    static func openAudioPipe(in directory: URL) throws -> (path: String, descriptor: Int32) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("audio-\(UUID().uuidString).pcm").path
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            throw FFmpegPipelineError.audioInputFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        let descriptor = open(path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            unlink(path)
            throw FFmpegPipelineError.audioInputFailed(error)
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        return (path, descriptor)
    }

    static func closeAudioPipe(_ pipe: (path: String, descriptor: Int32)?) {
        guard let pipe else { return }
        close(pipe.descriptor)
        unlink(pipe.path)
    }

    /// Make a broken encoder pipe report EPIPE instead of terminating the app
    /// with SIGPIPE. The write error can then reach coordinated recovery.
    static func makeInputPipe() throws -> Pipe {
        let pipe = Pipe()
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw FFmpegPipelineError.inputWriteFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        return pipe
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
        if acceptingFrames {
            latestFrame = frame
        }
        stateLock.unlock()
    }

    /// Raw PCM from the microphone, as the capture delegate delivers it. Copied out of the
    /// sample buffer here and written on the audio queue, so the capture thread never waits
    /// on the pipe.
    public func consume(audioSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return }
        audioQueue.async { [weak self] in self?.writeAudio(data) }
    }

    private func writeAudio(_ data: Data) {
        stateLock.lock()
        guard acceptingFrames, audioFileDescriptor >= 0, var aligner = self.aligner, let audio = configuration.audio else {
            stateLock.unlock()
            return
        }
        let descriptor = audioFileDescriptor
        let frames = pacer.emittedFrameCount
        stateLock.unlock()

        let bytesPerSample = audio.bytesPerSample
        let plan = aligner.plan(incomingSamples: data.count / bytesPerSample, videoFramesEmitted: frames)
        var unwrittenBytes = 0
        if plan.padSamples > 0 {
            unwrittenBytes += Self.writeNonBlocking(Data(count: plan.padSamples * bytesPerSample), to: descriptor)
        }
        if plan.keepSamples > 0 {
            unwrittenBytes += Self.writeNonBlocking(Data(data.suffix(plan.keepSamples * bytesPerSample)), to: descriptor)
        }
        aligner.noteUnwritten(samples: unwrittenBytes / bytesPerSample)

        stateLock.lock()
        if self.aligner != nil { self.aligner = aligner }
        stateLock.unlock()
        reportAudioStatistics(aligner)
    }

    /// Writes what the pipe takes right now and returns the bytes it refused. Blocking would
    /// stall the audio queue behind a slow encoder; dropping keeps the timeline honest because
    /// the aligner pads the hole with silence afterwards.
    private static func writeNonBlocking(_ data: Data, to descriptor: Int32) -> Int {
        var remaining = data.count
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written > 0 {
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                break
            }
        }
        return remaining
    }

    /// The Mac test reads these lines to judge the alignment; zero corrections is the goal.
    private func reportAudioStatistics(_ aligner: AudioTimelineAligner) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAudioReport >= 60 else { return }
        lastAudioReport = now
        guard aligner.paddedSamples + aligner.trimmedSamples + aligner.droppedSamples > 0 else { return }
        NSLog("MacMonitor audio: %lld samples written, %lld padded, %lld trimmed, %lld dropped",
              aligner.samplesWritten, aligner.paddedSamples, aligner.trimmedSamples, aligner.droppedSamples)
    }

    public func stop() {
        stateLock.lock()
        acceptingFrames = false
        let pacingTimer = self.pacingTimer
        self.pacingTimer = nil
        latestFrame = nil
        let process = self.process
        let inputHandle = self.inputHandle
        let terminationSignal = self.terminationSignal
        let logHandle = self.logHandle
        let audioPipe = audioFIFOPath.map { (path: $0, descriptor: audioFileDescriptor) }
        self.inputHandle = nil
        self.process = nil
        self.logHandle = nil
        audioFileDescriptor = -1
        audioFIFOPath = nil
        aligner = nil
        stateLock.unlock()

        pacingTimer?.cancel()
        // Closing stdin first gives FFmpeg EOF and also releases a writer blocked on the pipe.
        try? inputHandle?.close()
        // The audio pipe is closed as well, or FFmpeg would wait for more sound before exiting.
        audioQueue.sync {}
        Self.closeAudioPipe(audioPipe)
        if let process, process.isRunning {
            if terminationSignal.wait(timeout: .now() + 5) == .timedOut {
                process.terminate()
                if terminationSignal.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminationSignal.wait(timeout: .now() + 1)
                }
            }
        }
        writerQueue.sync {}
        try? logHandle?.close()
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

    /// `audioInput` is the named pipe FFmpeg reads sound from; nil keeps the stream silent.
    func arguments(audioInput: String? = nil) -> [String] {
        let segmentPattern = configuration.spoolDirectory
            .appendingPathComponent("\(configuration.segmentFilePrefix)-%Y%m%dT%H%M%S.mp4")
            .path
        let audio = audioInput == nil ? nil : configuration.audio
        // Each tee output gets the video and its own audio encode: Opus is what WebRTC plays,
        // AAC is what Safari plays from a file. The streams are named by output index (0 video,
        // 1 Opus, 2 AAC, in -map order) because tee splits its options at every colon, quotes
        // or not: `select='v:0,a:0'` failed with "No option found near" in FFmpeg 7.1 and in
        // the iMac's evermeet build (2026-11-10), which turned sound off.
        let liveSelect = audio == nil ? "" : ":select=0,1"
        let fileSelect = audio == nil ? "" : ":select=0,2"
        // A local publish failure must restart the pipeline; silently dropping
        // this slave would leave monitoring 'running' without any live video.
        var teeOutputs = ["[f=rtsp:rtsp_transport=tcp:onfail=abort\(liveSelect)]\(configuration.rtspPublishURL.absoluteString)"]
        if configuration.recordingEnabled {
            // Recording is essential: surface a failed output through process termination
            // so MonitoringCoordinator can recover instead of silently losing recordings.
            teeOutputs.append("[f=segment:segment_time=\(configuration.segmentSeconds):segment_time_delta=0.033:reset_timestamps=1:strftime=1:segment_format=mp4:segment_format_options=movflags=+faststart:onfail=abort\(fileSelect)]\(segmentPattern)")
        }
        let teeTarget = teeOutputs.joined(separator: "|")

        var arguments = [
            "-hide_banner", "-loglevel", "warning", "-nostdin",
            "-f", "rawvideo",
            "-pixel_format", "nv12",
            "-video_size", "\(configuration.width)x\(configuration.height)",
            "-framerate", "\(configuration.framesPerSecond)",
            "-i", "pipe:0"
        ]
        if let audio, let audioInput {
            arguments += ["-f", "s16le", "-ar", "\(audio.sampleRate)", "-ac", "\(audio.channels)", "-i", audioInput]
        }
        arguments += ["-map", "0:v:0"]
        if let audio {
            arguments += ["-map", "1:a:0", "-c:a:0", "libopus", "-b:a:0", "\(audio.liveBitrateKbps)k"]
            if configuration.recordingEnabled {
                arguments += ["-map", "1:a:0", "-c:a:1", "aac", "-b:a:1", "\(audio.recordingBitrateKbps)k"]
            }
        } else {
            arguments += ["-an"]
        }
        arguments += [
            "-c:v", "h264_videotoolbox",
            "-realtime:v", "true",
            "-allow_sw:v", "1",
            "-profile:v", "main",
            "-b:v", "\(configuration.bitrateKbps)k",
            "-maxrate:v", "\(configuration.bitrateKbps * 5 / 4)k",
            "-bufsize:v", "\(configuration.bitrateKbps * 2)k",
            "-g:v", "\(configuration.framesPerSecond * 2)",
            "-force_key_frames:v", "expr:gte(t,n_forced*\(configuration.segmentSeconds))",
            "-bf:v", "0",
            "-flags", "+cgop+global_header",
            "-f", "tee",
            "-use_fifo", "1",
            teeTarget
        ]
        return arguments
    }

    deinit {
        stop()
    }
}

public enum FFmpegPipelineError: LocalizedError {
    case unexpectedExit(Int32)
    case inputWriteFailed(Error)
    case audioInputFailed(Error)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedExit(status):
            return "FFmpeg 영상 파이프라인이 예기치 않게 종료되었습니다 (상태 \(status))."
        case let .inputWriteFailed(error):
            return "FFmpeg에 영상 프레임을 전달하지 못했습니다: \(error.localizedDescription)"
        case let .audioInputFailed(error):
            return "소리 전달용 파이프를 만들지 못했습니다: \(error.localizedDescription)"
        }
    }
}
