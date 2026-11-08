import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum CameraCaptureError: LocalizedError {
    case noCamera
    case selectedCameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case unsupportedVideoFormat
    case logInitializationFailed(Error)
    case runtimeFailure

    public var errorDescription: String? {
        switch self {
        case .noCamera:
            return "사용 가능한 카메라를 찾지 못했습니다."
        case .selectedCameraUnavailable:
            return "설정에서 선택한 카메라가 연결되어 있지 않습니다."
        case .cannotAddInput:
            return "카메라 입력을 캡처 세션에 연결할 수 없습니다."
        case .cannotAddOutput:
            return "영상 출력을 캡처 세션에 연결할 수 없습니다."
        case .unsupportedVideoFormat:
            return "선택한 카메라는 필요한 1280×720 영상 형식을 지원하지 않습니다. 다른 카메라를 선택해 주세요."
        case let .logInitializationFailed(error):
            return "진단 로그를 열 수 없습니다: \(error.localizedDescription)"
        case .runtimeFailure:
            return "카메라 캡처 세션에서 알 수 없는 실행 오류가 발생했습니다."
        }
    }
}

public struct CameraDeviceInfo: Equatable {
    public let uniqueID: String
    public let name: String
}

public final class CameraCaptureService: NSObject, CameraCapturing {
    public var failureHandler: ((Error) -> Void)?

    public static var diagnosticsDirectoryURL: URL {
        CaptureProbeLogger.diagnosticsDirectoryURL
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.macmonitor.capture.session")
    private let frameQueue = DispatchQueue(label: "com.macmonitor.capture.frames")
    private let audioQueue = DispatchQueue(label: "com.macmonitor.capture.audio")
    private let loggerLock = NSLock()
    private let stateLock = NSLock()
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var configuredAudio: AudioCaptureState = .off // sessionQueue-owned
    private var audioAuthorized = false
    private var audioFormatVerdict: Bool? // audioQueue-owned
    private var logger: CaptureProbeLogger?
    private var configuredDeviceName: String?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var active = false
    private let deviceUniqueIDProvider: () -> String?
    private let audioEnabledProvider: () -> Bool
    private let frameHandler: ((CMSampleBuffer) -> Void)?
    private let audioHandler: ((CMSampleBuffer) -> Void)?

    public init(
        deviceUniqueIDProvider: @escaping () -> String? = { nil },
        audioEnabledProvider: @escaping () -> Bool = { false },
        frameHandler: ((CMSampleBuffer) -> Void)? = nil,
        audioHandler: ((CMSampleBuffer) -> Void)? = nil
    ) {
        self.deviceUniqueIDProvider = deviceUniqueIDProvider
        self.audioEnabledProvider = audioEnabledProvider
        self.frameHandler = frameHandler
        self.audioHandler = audioHandler
        super.init()
        // The macOS 13.1 SDK in Xcode 14.2 predates AVCaptureSession.runtimeErrorNotification.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleRuntimeError(notification)
        }
    }

    public static func availableDevices() -> [CameraDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CameraDeviceInfo(uniqueID: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Local user-invoked settings preview only. Reuses the capture session;
    /// never requests permission, starts capture or changes power state.
    public func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        stateLock.lock()
        let isActive = active
        stateLock.unlock()
        guard isActive else { return AVCaptureVideoPreviewLayer() }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return preview
    }

    /// Camera access decides whether capture may start. The microphone is asked for right
    /// after, while the owner is still at the Mac for the prompt, but a refusal only leaves the
    /// recording silent: the completion is still true.
    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        Self.requestAccess(.video) { [weak self] granted in
            guard granted, let self, self.audioEnabledProvider() else {
                completion(granted)
                return
            }
            Self.requestAccess(.audio) { audioGranted in
                self.stateLock.lock()
                self.audioAuthorized = audioGranted
                self.stateLock.unlock()
                completion(true)
            }
        }
    }

    private static func requestAccess(_ mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    public func start(completion: @escaping (Result<CaptureRuntimeInfo, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if self.videoOutput == nil {
                    try self.configureSession()
                }
                let logger: CaptureProbeLogger
                do {
                    logger = try CaptureProbeLogger()
                } catch {
                    throw CameraCaptureError.logInitializationFailed(error)
                }
                self.setLogger(logger)

                guard let deviceName = self.configuredDeviceName else {
                    throw CameraCaptureError.noCamera
                }
                logger.recordStarted(deviceName: deviceName)
                self.setActive(true)
                self.session.startRunning()
                guard self.session.isRunning else { throw CameraCaptureError.runtimeFailure }

                completion(
                    .success(
                        CaptureRuntimeInfo(
                            deviceName: deviceName,
                            logURL: CaptureProbeLogger.defaultLogURL,
                            audio: self.configuredAudio
                        )
                    )
                )
            } catch {
                self.setActive(false)
                self.setLogger(nil)
                completion(.failure(error))
            }
        }
    }

    public func stop(completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.setActive(false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.frameQueue.sync {}
            self.audioQueue.sync { self.audioFormatVerdict = nil }
            let logger = self.currentLogger()
            logger?.recordStopped()
            self.setLogger(nil)
            self.session.beginConfiguration()
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            self.session.commitConfiguration()
            self.videoOutput = nil
            self.audioOutput = nil
            self.configuredAudio = .off
            self.configuredDeviceName = nil
            completion()
        }
    }

    private func configureSession() throws {
        let device: AVCaptureDevice
        if let requestedID = deviceUniqueIDProvider() {
            guard let selectedDevice = AVCaptureDevice(uniqueID: requestedID) else {
                throw CameraCaptureError.selectedCameraUnavailable
            }
            device = selectedDevice
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .video) else {
                throw CameraCaptureError.noCamera
            }
            device = defaultDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }

        session.beginConfiguration()
        session.addInput(input)
        guard session.canSetSessionPreset(.hd1280x720) else {
            session.removeInput(input)
            session.commitConfiguration()
            throw CameraCaptureError.unsupportedVideoFormat
        }
        session.sessionPreset = .hd1280x720
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        configuredAudio = configureAudio()
        session.commitConfiguration()

        do {
            try configureFrameRate(device: device, framesPerSecond: 15)
        } catch {
            session.beginConfiguration()
            session.removeOutput(output)
            session.removeInput(input)
            session.commitConfiguration()
            throw error
        }
        videoOutput = output
        configuredDeviceName = device.localizedName
    }

    /// Adds the default microphone when the owner wants sound and allowed it. Every failure is
    /// a reason in the status, never a failed camera start. The output is asked for 48 kHz
    /// mono 16-bit integer samples, which is exactly what FFmpeg's raw `s16le` input expects.
    private func configureAudio() -> AudioCaptureState {
        guard audioEnabledProvider() else { return .off }
        stateLock.lock()
        let authorized = audioAuthorized
        stateLock.unlock()
        guard authorized else { return .unavailable("마이크 권한 필요") }
        guard let microphone = AVCaptureDevice.default(for: .audio) else { return .unavailable("마이크 없음") }
        guard let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) else {
            return .unavailable("마이크 입력 연결 실패")
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(output) else { return .unavailable("마이크 출력 연결 실패") }
        session.addInput(input)
        session.addOutput(output)
        audioOutput = output
        return .on
    }

    /// Checks the first buffer against what FFmpeg is told. Mis-typed samples would be heard
    /// as noise, so a mismatch drops the audio and logs why instead.
    private func audioFormatIsUsable(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if let verdict = audioFormatVerdict { return verdict }
        var usable = false
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            usable = basic.mFormatID == kAudioFormatLinearPCM && basic.mSampleRate == 48_000
                && basic.mChannelsPerFrame == 1 && basic.mBitsPerChannel == 16
                && basic.mFormatFlags & kAudioFormatFlagIsFloat == 0
                && basic.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
                && basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            if !usable {
                NSLog("MacMonitor: microphone delivers %.0f Hz, %u channel(s), %u bit, flags %u; not the 48 kHz mono 16-bit the encoder expects, so audio is dropped",
                      basic.mSampleRate, basic.mChannelsPerFrame, basic.mBitsPerChannel, basic.mFormatFlags)
            }
        }
        audioFormatVerdict = usable
        return usable
    }

    private func setLogger(_ newLogger: CaptureProbeLogger?) {
        loggerLock.lock()
        logger = newLogger
        loggerLock.unlock()
    }

    private func currentLogger() -> CaptureProbeLogger? {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        return logger
    }

    private func configureFrameRate(device: AVCaptureDevice, framesPerSecond: Double) throws {
        let supportsTarget = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= framesPerSecond && framesPerSecond <= range.maxFrameRate
        }
        guard supportsTarget else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func setActive(_ active: Bool) {
        stateLock.lock()
        self.active = active
        stateLock.unlock()
    }

    private func handleRuntimeError(_ notification: Notification) {
        stateLock.lock()
        let shouldReport = active
        let failureHandler = self.failureHandler
        stateLock.unlock()
        guard shouldReport else { return }
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            ?? CameraCaptureError.runtimeFailure
        failureHandler?(error)
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Both delegate protocols share this one method; the output tells the two apart.
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            guard audioFormatIsUsable(sampleBuffer) else { return }
            audioHandler?(sampleBuffer)
            return
        }
        currentLogger()?.recordFrame(sampleBuffer)
        frameHandler?(sampleBuffer)
    }
}
