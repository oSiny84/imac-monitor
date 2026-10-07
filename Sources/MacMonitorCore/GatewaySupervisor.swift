import Darwin
import Foundation

public final class GatewaySupervisor {
    public var failureHandler: ((Error) -> Void)?

    private let stateLock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false

    public init() {}

    @discardableResult
    public func startIfConfigured() throws -> Bool {
        guard FileManager.default.fileExists(atPath: AppDirectories.gatewayConfiguration.path) else {
            return false
        }
        guard let executableURL = RuntimeDependencyLocator.gateway() else {
            throw GatewaySupervisorError.executableMissing
        }

        let logURL = AppDirectories.diagnostics.appendingPathComponent("gateway.log")
        try FileManager.default.createDirectory(at: AppDirectories.diagnostics, withIntermediateDirectories: true)
        try LogFileRotator.rotateIfNeeded(at: logURL)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["serve", "-config", AppDirectories.gatewayConfiguration.path]
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
                failureHandler?(GatewaySupervisorError.unexpectedExit(terminatedProcess.terminationStatus))
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
        Thread.sleep(forTimeInterval: 0.3)
        guard process.isRunning else {
            stateLock.lock()
            self.process = nil
            self.logHandle = nil
            stateLock.unlock()
            try? logHandle.close()
            throw GatewaySupervisorError.exitedDuringStartup(process.terminationStatus)
        }
        return true
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

    deinit { stop() }
}

public enum GatewaySupervisorError: LocalizedError {
    case executableMissing
    case exitedDuringStartup(Int32)
    case unexpectedExit(Int32)

    public var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "게이트웨이 설정이 있지만 macmonitor-gateway 실행 파일이 없습니다."
        case let .exitedDuringStartup(status):
            return "HTTPS 게이트웨이가 시작 직후 종료되었습니다 (상태 \(status))."
        case let .unexpectedExit(status):
            return "HTTPS 게이트웨이가 예기치 않게 종료되었습니다 (상태 \(status))."
        }
    }
}
