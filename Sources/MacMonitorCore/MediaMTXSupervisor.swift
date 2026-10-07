import Darwin
import Foundation

public final class MediaMTXSupervisor {
    public var failureHandler: ((Error) -> Void)?

    private let executableURL: URL
    private let configurationURL: URL
    private let logURL: URL
    private let additionalHosts: [String]
    private let stateLock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false

    public init(
        executableURL: URL,
        configurationURL: URL,
        logURL: URL,
        additionalHosts: [String]
    ) {
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.logURL = logURL
        self.additionalHosts = additionalHosts
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeConfiguration()
        try LogFileRotator.rotateIfNeeded(at: logURL)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [configurationURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.stateLock.lock()
            let ownsProcess = self.process.map { $0 === terminatedProcess } ?? false
            let unexpected = ownsProcess && !self.stopping
            let failureHandler = self.failureHandler
            self.stateLock.unlock()
            if unexpected {
                failureHandler?(MediaMTXError.unexpectedExit(terminatedProcess.terminationStatus))
            }
        }
        stateLock.lock()
        self.process = process
        self.logHandle = logHandle
        stopping = false
        stateLock.unlock()
        do {
            try process.run()
        } catch {
            stateLock.lock()
            self.process = nil
            self.logHandle = nil
            stateLock.unlock()
            try? logHandle.close()
            throw error
        }
        Thread.sleep(forTimeInterval: 0.4)
        guard process.isRunning else {
            stateLock.lock()
            self.process = nil
            self.logHandle = nil
            stateLock.unlock()
            try? logHandle.close()
            throw MediaMTXError.exitedDuringStartup(process.terminationStatus)
        }
    }

    public func stop() {
        stateLock.lock()
        stopping = true
        guard let process else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        stateLock.lock()
        self.process = nil
        let logHandle = self.logHandle
        self.logHandle = nil
        stateLock.unlock()
        try? logHandle?.close()
    }

    private func writeConfiguration() throws {
        let hosts = additionalHosts.map { "\"\($0)\"" }.joined(separator: ", ")
        let configuration = """
        logLevel: info
        logDestinations: [stdout]
        logStructured: false
        api: false
        metrics: false
        pprof: false
        playback: false
        rtsp: true
        rtspTransports: [tcp]
        rtspAddress: 127.0.0.1:8554
        rtmp: false
        hls: false
        webrtc: true
        webrtcAddress: 127.0.0.1:8889
        webrtcEncryption: false
        webrtcAllowOrigins: ["http://127.0.0.1:8889"]
        webrtcLocalUDPAddress: :8189
        webrtcLocalTCPAddress: :8189
        webrtcIPsFromInterfaces: true
        webrtcAdditionalHosts: [\(hosts)]
        srt: false
        moq: false
        paths:
          live:
            source: publisher
        """
        try Data(configuration.utf8).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
    }

    deinit {
        stop()
    }
}

public enum MediaMTXError: LocalizedError {
    case exitedDuringStartup(Int32)
    case unexpectedExit(Int32)

    public var errorDescription: String? {
        switch self {
        case let .exitedDuringStartup(status):
            return "MediaMTX가 시작 직후 종료되었습니다 (상태 \(status))."
        case let .unexpectedExit(status):
            return "MediaMTX 미디어 서버가 예기치 않게 종료되었습니다 (상태 \(status))."
        }
    }
}
