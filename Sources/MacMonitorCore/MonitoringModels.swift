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

/// What the camera is running for. Remote viewing needs only the live stream; motion recording
/// adds detection and the spool on top of the same capture.
public enum CaptureMode: String, Equatable {
    case off
    case live
    case recording
}

public enum CaptureModePolicy {
    /// Recording wins while wanted because its stream also serves viewers, so one capture covers
    /// both. A scheduled rest pauses recording but not a viewer who explicitly asked for video.
    public static func desiredMode(
        recordingWanted: Bool,
        resting: Bool,
        systemSleeping: Bool,
        liveStandby: Bool,
        liveDemanded: Bool
    ) -> CaptureMode {
        if systemSleeping { return .off }
        if recordingWanted && !resting { return .recording }
        if liveStandby && liveDemanded { return .live }
        return .off
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
            return "카메라 꺼짐"
        case .requestingCameraPermission:
            return "카메라 권한 확인 중"
        case .starting:
            return "카메라 시작 중"
        case let .running(info):
            return "움직임 녹화 중 — \(info.deviceName)"
        case let .recovering(attempt, maximum, delaySeconds):
            return "자동 복구 \(attempt)/\(maximum) — \(delaySeconds)초 후 재시작"
        case .stopping:
            return "카메라 끄는 중"
        case let .failed(message):
            return "오류 — \(message)"
        }
    }

    public func displayText(for mode: CaptureMode) -> String {
        guard mode == .live else { return displayText }
        switch self {
        case .requestingCameraPermission, .starting:
            return "원격 시청 준비 중 — 카메라를 켜는 중"
        case let .running(info):
            return "원격 시청 중 — \(info.deviceName) · 녹화 안 함"
        default:
            return displayText
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
