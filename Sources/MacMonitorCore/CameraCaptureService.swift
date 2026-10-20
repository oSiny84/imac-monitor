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
    private let loggerLock = NSLock()
    private let stateLock = NSLock()
    private var videoOutput: AVCaptureVideoDataOutput?
    private var logger: CaptureProbeLogger?
    private var configuredDeviceName: String?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var active = false
    private let deviceUniqueIDProvider: () -> String?
    private let frameHandler: ((CMSampleBuffer) -> Void)?

    public init(
        deviceUniqueIDProvider: @escaping () -> String? = { nil },
        frameHandler: ((CMSampleBuffer) -> Void)? = nil
    ) {
        self.deviceUniqueIDProvider = deviceUniqueIDProvider
        self.frameHandler = frameHandler
        super.init()
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
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

    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
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
                            logURL: CaptureProbeLogger.defaultLogURL
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

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        currentLogger()?.recordFrame(sampleBuffer)
        frameHandler?(sampleBuffer)
    }
}
