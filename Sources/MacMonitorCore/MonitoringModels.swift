import CoreMedia
import Foundation

public struct CaptureRuntimeInfo: Equatable {
    public let deviceName: String
    public let logURL: URL

    public init(deviceName: String, logURL: URL) {
        self.deviceName = deviceName
        self.logURL = logURL
    }
}

public enum MonitoringState: Equatable {
    case idle
    case requestingCameraPermission
    case starting
    case running(CaptureRuntimeInfo)
    case recovering(attempt: Int, maximum: Int, delaySeconds: Int)
    case stopping
    case failed(String)
}

extension MonitoringState {
    public var displayText: String {
        switch self {
        case .idle:
            return "감시 중지됨"
        case .requestingCameraPermission:
            return "카메라 권한 확인 중"
        case .starting:
            return "감시 시작 중"
        case let .running(info):
            return "감시 중 — \(info.deviceName)"
        case let .recovering(attempt, maximum, delaySeconds):
            return "자동 복구 \(attempt)/\(maximum) — \(delaySeconds)초 후 재시작"
        case .stopping:
            return "감시 종료 중"
        case let .failed(message):
            return "오류 — \(message)"
        }
    }
}

public protocol CameraCapturing: AnyObject {
    var failureHandler: ((Error) -> Void)? { get set }
    func requestAuthorization(completion: @escaping (Bool) -> Void)
    func start(completion: @escaping (Result<CaptureRuntimeInfo, Error>) -> Void)
    func stop(completion: @escaping () -> Void)
}

public protocol IdleSleepPreventing: AnyObject {
    func acquire() throws
    func release()
}

public protocol MonitoringPipelineControlling: AnyObject {
    var failureHandler: ((Error) -> Void)? { get set }
    func start() throws
    func consume(sampleBuffer: CMSampleBuffer)
    func stop()
}
