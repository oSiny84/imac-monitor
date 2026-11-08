import CoreMedia
import Foundation

/// Whether sound is captured with the video and, if not, why. Sound is optional at every
/// step: a missing permission, microphone or encoder leaves the camera running without it.
public enum AudioCaptureState: Equatable {
    case off
    case on
    case unavailable(String)

    /// The value the status file carries; the web and Telegram turn it into words.
    public var statusValue: String {
        switch self {
        case .off: return "off"
        case .on: return "on"
        case .unavailable: return "unavailable"
        }
    }

    public var reason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

public struct CaptureRuntimeInfo: Equatable {
    public let deviceName: String
    public let logURL: URL
    public let audio: AudioCaptureState

    public init(deviceName: String, logURL: URL, audio: AudioCaptureState = .off) {
        self.deviceName = deviceName
        self.logURL = logURL
        self.audio = audio
    }
}

/// What the camera is running for. Remote viewing needs only the live stream; timed recording,
/// started from the web for a number of hours, also writes every clip until its end time.
public enum CaptureMode: String, Equatable {
    case off
    case live
    case timed

    /// Recording writes files and therefore needs the spool and the retention pass.
    public var writesRecordings: Bool { self == .timed }
}

public enum CaptureModePolicy {
    /// A timed recording wins while active because its stream also serves viewers, so one
    /// capture covers both. Like remote viewing it needs standby on, the owner's switch for
    /// "remote may use the camera". A scheduled rest pauses recording but not a viewer who
    /// explicitly asked for video.
    public static func desiredMode(
        timedRecording: Bool = false,
        resting: Bool,
        systemSleeping: Bool,
        liveStandby: Bool,
        liveDemanded: Bool
    ) -> CaptureMode {
        if systemSleeping { return .off }
        if !resting, timedRecording, liveStandby { return .timed }
        if liveStandby && liveDemanded { return .live }
        return .off
    }

    /// Nobody is at the Mac to press retry for a remote viewer, and an exhausted recovery budget
    /// must not leave the camera unreachable until someone returns. This applies to a timed
    /// recording as well: it wins the mode, so its failure would otherwise block the viewer for
    /// good. Without a waiting viewer a failed capture keeps waiting for the next request.
    public static func shouldRetryFailedCapture(
        state: MonitoringState,
        viewerWaiting: Bool,
        captureRequested: Bool,
        stopping: Bool,
        secondsSinceFailure: TimeInterval,
        retryInterval: TimeInterval = 30
    ) -> Bool {
        guard case .failed = state else { return false }
        return viewerWaiting && captureRequested && !stopping && secondsSinceFailure >= retryInterval
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
            return "카메라 켜짐 — \(info.deviceName)"
        case let .recovering(attempt, maximum, delaySeconds):
            return "자동 복구 \(attempt)/\(maximum) — \(delaySeconds)초 후 재시작"
        case .stopping:
            return "카메라 끄는 중"
        case let .failed(message):
            return "오류 — \(message)"
        }
    }

    public func displayText(for mode: CaptureMode) -> String {
        switch (mode, self) {
        case (.live, .requestingCameraPermission), (.live, .starting):
            return "원격 시청 준비 중 — 카메라를 켜는 중"
        case let (.live, .running(info)):
            return "원격 시청 중 — \(info.deviceName) · 녹화 안 함"
        case (.timed, .requestingCameraPermission), (.timed, .starting):
            return "원격 녹화 준비 중 — 카메라를 켜는 중"
        case let (.timed, .running(info)):
            return "원격 녹화 중 — \(info.deviceName)"
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
