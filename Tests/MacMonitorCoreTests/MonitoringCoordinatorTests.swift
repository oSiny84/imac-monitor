import CoreMedia
import XCTest
@testable import MacMonitorCore

final class MonitoringCoordinatorTests: XCTestCase {
    func testObsoleteStartCompletionDoesNotStopReplacementRun() {
        let camera = DeferredCameraStub(deferStarts: true, deferStops: false)
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(camera: camera,
            idleSleepPreventer: sleepPreventer, pipeline: pipeline)
        let firstStart = expectation(description: "first start pending")
        let replacementStart = expectation(description: "replacement start pending")
        let stopped = expectation(description: "first run stopped")
        let running = expectation(description: "replacement running")
        camera.onStart = { count in
            if count == 1 { firstStart.fulfill() }
            if count == 2 { replacementStart.fulfill() }
        }
        coordinator.onStateChange = { state in
            if case .running = state { running.fulfill() }
        }

        coordinator.start()
        wait(for: [firstStart], timeout: 1)
        coordinator.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 1)
        coordinator.start()
        wait(for: [replacementStart], timeout: 1)
        camera.completeStart(at: 1)
        wait(for: [running], timeout: 1)

        // The old asynchronous callback is allowed to arrive after the new run is live.
        camera.completeStart(at: 0)
        let drained = expectation(description: "obsolete callback processed")
        coordinator.stop { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(camera.stopCount, 2, "only the two requested stops should stop the camera")
        XCTAssertEqual(pipeline.stopCount, 2)
        XCTAssertEqual(sleepPreventer.releaseCount, 2)
    }

    func testRepeatedStopsShareOneCleanupAndWaitForItToFinish() {
        let camera = DeferredCameraStub(deferStarts: false, deferStops: true)
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(camera: camera,
            idleSleepPreventer: sleepPreventer, pipeline: pipeline)
        let firstRunning = expectation(description: "first run")
        let replacementRunning = expectation(description: "replacement run")
        let stopPending = expectation(description: "one camera stop pending")
        let newerStopFinished = expectation(description: "newer stop finished")
        let olderStopFinished = expectation(description: "older stop finished")
        var runningCount = 0
        coordinator.onStateChange = { state in
            if case .running = state {
                runningCount += 1
                if runningCount == 1 { firstRunning.fulfill() }
                if runningCount == 2 { replacementRunning.fulfill() }
            }
        }
        camera.onStop = { stopPending.fulfill() }

        coordinator.start()
        wait(for: [firstRunning], timeout: 1)
        coordinator.stop { olderStopFinished.fulfill() }
        coordinator.stop { newerStopFinished.fulfill() }
        wait(for: [stopPending], timeout: 1)
        camera.completeStop(at: 0)
        wait(for: [newerStopFinished, olderStopFinished], timeout: 1)
        coordinator.start()
        wait(for: [replacementRunning], timeout: 1)

        XCTAssertEqual(camera.stopCount, 1)
        XCTAssertEqual(pipeline.stopCount, 1, "both requests must share the same completed cleanup")
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
        XCTAssertEqual(camera.startCount, 2)
    }

    func testSuccessfulStartAcquiresAssertionAndPublishesRunningState() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let coordinator = MonitoringCoordinator(camera: camera, idleSleepPreventer: sleepPreventer)
        let running = expectation(description: "running")

        coordinator.onStateChange = { state in
            if case .running = state { running.fulfill() }
        }
        coordinator.start()

        wait(for: [running], timeout: 1)
        XCTAssertEqual(sleepPreventer.acquireCount, 1)
        XCTAssertEqual(sleepPreventer.releaseCount, 0)
        XCTAssertEqual(camera.startCount, 1)
    }

    func testCameraFailureReleasesAssertion() throws {
        let camera = CameraStub()
        camera.startResult = .failure(TestError.captureFailed)
        let sleepPreventer = SleepPreventerStub()
        let coordinator = MonitoringCoordinator(camera: camera, idleSleepPreventer: sleepPreventer)
        let failed = expectation(description: "failed")

        coordinator.onStateChange = { state in
            if case .failed = state { failed.fulfill() }
        }
        coordinator.start()

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(sleepPreventer.acquireCount, 1)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }

    func testDeniedPermissionDoesNotAcquireAssertionOrStartCamera() throws {
        let camera = CameraStub()
        camera.authorized = false
        let sleepPreventer = SleepPreventerStub()
        let coordinator = MonitoringCoordinator(camera: camera, idleSleepPreventer: sleepPreventer)
        let failed = expectation(description: "failed")

        coordinator.onStateChange = { state in
            if case .failed = state { failed.fulfill() }
        }
        coordinator.start()

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(sleepPreventer.acquireCount, 0)
        XCTAssertEqual(sleepPreventer.releaseCount, 0)
    }

    func testAssertionFailureDoesNotStartCamera() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        sleepPreventer.acquireError = TestError.assertionFailed
        let coordinator = MonitoringCoordinator(camera: camera, idleSleepPreventer: sleepPreventer)
        let failed = expectation(description: "failed")

        coordinator.onStateChange = { state in
            if case .failed = state { failed.fulfill() }
        }
        coordinator.start()

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(sleepPreventer.acquireCount, 1)
    }

    func testPipelineFailureReleasesAssertionAndDoesNotStartCamera() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        pipeline.startError = TestError.pipelineFailed
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline
        )
        let failed = expectation(description: "failed")
        coordinator.onStateChange = { state in
            if case .failed = state { failed.fulfill() }
        }

        coordinator.start()
        wait(for: [failed], timeout: 1)

        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(pipeline.startCount, 1)
        XCTAssertEqual(pipeline.stopCount, 1)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }

    func testRuntimePipelineFailureStopsCameraAndReleasesAssertion() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline,
            recoveryDelays: []
        )
        let running = expectation(description: "running")
        let failed = expectation(description: "failed")
        coordinator.onStateChange = { state in
            if case .running = state { running.fulfill() }
            if case .failed = state { failed.fulfill() }
        }
        coordinator.start()
        wait(for: [running], timeout: 1)

        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [failed], timeout: 1)

        XCTAssertEqual(camera.stopCount, 1)
        XCTAssertEqual(pipeline.stopCount, 1)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }

    func testRuntimeCameraFailureStopsPipelineAndReleasesAssertion() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline,
            recoveryDelays: []
        )
        let running = expectation(description: "running")
        let failed = expectation(description: "failed")
        coordinator.onStateChange = { state in
            if case .running = state { running.fulfill() }
            if case .failed = state { failed.fulfill() }
        }
        coordinator.start()
        wait(for: [running], timeout: 1)

        camera.failureHandler?(TestError.captureFailed)
        wait(for: [failed], timeout: 1)

        XCTAssertEqual(camera.stopCount, 1)
        XCTAssertEqual(pipeline.stopCount, 1)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }

    func testRuntimeFailureAutomaticallyRestartsMonitoring() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline,
            recoveryDelays: [0]
        )
        let initiallyRunning = expectation(description: "initially running")
        let recovered = expectation(description: "running after recovery")
        var runningCount = 0
        coordinator.onStateChange = { state in
            guard case .running = state else { return }
            runningCount += 1
            if runningCount == 1 { initiallyRunning.fulfill() }
            if runningCount == 2 { recovered.fulfill() }
        }

        coordinator.start()
        wait(for: [initiallyRunning], timeout: 1)
        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [recovered], timeout: 1)

        XCTAssertEqual(camera.startCount, 2)
        XCTAssertEqual(pipeline.startCount, 2)
        XCTAssertEqual(camera.stopCount, 1)
        XCTAssertEqual(pipeline.stopCount, 1)
        XCTAssertEqual(sleepPreventer.acquireCount, 2)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }

    func testStopCancelsScheduledRecovery() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline,
            recoveryDelays: [0.2]
        )
        let running = expectation(description: "running")
        let recovering = expectation(description: "recovering")
        let stopped = expectation(description: "stopped")
        let restarted = expectation(description: "must not restart")
        restarted.isInverted = true
        var runningCount = 0
        coordinator.onStateChange = { state in
            if case .running = state {
                runningCount += 1
                if runningCount == 1 { running.fulfill() } else { restarted.fulfill() }
            }
            if case .recovering = state { recovering.fulfill() }
        }

        coordinator.start()
        wait(for: [running], timeout: 1)
        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [recovering], timeout: 1)
        coordinator.stop { stopped.fulfill() }
        wait(for: [stopped, restarted], timeout: 0.5)

        XCTAssertEqual(camera.startCount, 1)
    }

    func testRecoveryBudgetIsRestoredAfterASustainedRun() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline,
            recoveryDelays: [0],
            recoveryResetInterval: 0.2
        )
        let firstRun = expectation(description: "first run")
        let runAfterRecovery = expectation(description: "run after the only recovery attempt")
        let runAfterReset = expectation(description: "run after the budget was restored")
        let gaveUp = expectation(description: "must not give up while failures are far apart")
        gaveUp.isInverted = true
        var runningCount = 0
        coordinator.onStateChange = { state in
            if case .running = state {
                runningCount += 1
                switch runningCount {
                case 1: firstRun.fulfill()
                case 2: runAfterRecovery.fulfill()
                case 3: runAfterReset.fulfill()
                default: break
                }
            }
            if case .failed = state { gaveUp.fulfill() }
        }

        coordinator.start()
        wait(for: [firstRun], timeout: 1)

        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [runAfterRecovery], timeout: 1)

        // The single recovery attempt is now spent. Staying up past recoveryResetInterval must
        // restore it, otherwise the next unrelated failure ends monitoring for good. The reset
        // runs on the coordinator's own queue, so sleeping the test thread does not block it.
        Thread.sleep(forTimeInterval: 0.4)

        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [runAfterReset, gaveUp], timeout: 1)

        XCTAssertEqual(camera.startCount, 3)
        XCTAssertEqual(pipeline.startCount, 3)
    }

    func testRepeatedFailuresInsideTheResetIntervalStillExhaustTheBudget() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let pipeline = PipelineStub()
        let coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: sleepPreventer,
            pipeline: pipeline,
            recoveryDelays: [0],
            recoveryResetInterval: 60
        )
        let firstRun = expectation(description: "first run")
        let runAfterRecovery = expectation(description: "run after the only recovery attempt")
        let failed = expectation(description: "gives up on the second rapid failure")
        var runningCount = 0
        coordinator.onStateChange = { state in
            if case .running = state {
                runningCount += 1
                if runningCount == 1 { firstRun.fulfill() }
                if runningCount == 2 { runAfterRecovery.fulfill() }
            }
            if case .failed = state { failed.fulfill() }
        }

        coordinator.start()
        wait(for: [firstRun], timeout: 1)
        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [runAfterRecovery], timeout: 1)
        pipeline.failureHandler?(TestError.pipelineFailed)
        wait(for: [failed], timeout: 1)

        XCTAssertEqual(camera.startCount, 2)
    }

    func testStopReleasesAssertionAfterCameraStops() throws {
        let camera = CameraStub()
        let sleepPreventer = SleepPreventerStub()
        let coordinator = MonitoringCoordinator(camera: camera, idleSleepPreventer: sleepPreventer)
        let running = expectation(description: "running")
        let idle = expectation(description: "idle")
        var didReachRunning = false

        coordinator.onStateChange = { state in
            if case .running = state {
                didReachRunning = true
                running.fulfill()
            } else if state == .idle, didReachRunning {
                idle.fulfill()
            }
        }
        coordinator.start()
        wait(for: [running], timeout: 1)
        coordinator.stop()
        wait(for: [idle], timeout: 1)

        XCTAssertEqual(camera.stopCount, 1)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }
}

private enum TestError: Error {
    case captureFailed
    case assertionFailed
    case pipelineFailed
}

private final class PipelineStub: MonitoringPipelineControlling {
    var failureHandler: ((Error) -> Void)?
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func consume(sampleBuffer: CMSampleBuffer) {}

    func stop() {
        stopCount += 1
    }
}

private final class CameraStub: CameraCapturing {
    var failureHandler: ((Error) -> Void)?
    var authorized = true
    var startResult: Result<CaptureRuntimeInfo, Error> = .success(
        CaptureRuntimeInfo(deviceName: "Test Camera", logURL: URL(fileURLWithPath: "/tmp/test.jsonl"))
    )
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        completion(authorized)
    }

    func start(completion: @escaping (Result<CaptureRuntimeInfo, Error>) -> Void) {
        startCount += 1
        completion(startResult)
    }

    func stop(completion: @escaping () -> Void) {
        stopCount += 1
        completion()
    }
}

private final class DeferredCameraStub: CameraCapturing {
    var failureHandler: ((Error) -> Void)?
    var onStart: ((Int) -> Void)?
    var onStop: (() -> Void)?
    private let deferStarts: Bool
    private let deferStops: Bool
    private var pendingStarts: [(Result<CaptureRuntimeInfo, Error>) -> Void] = []
    private var pendingStops: [() -> Void] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(deferStarts: Bool, deferStops: Bool) {
        self.deferStarts = deferStarts
        self.deferStops = deferStops
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) { completion(true) }

    func start(completion: @escaping (Result<CaptureRuntimeInfo, Error>) -> Void) {
        startCount += 1
        pendingStarts.append(completion)
        onStart?(startCount)
        if !deferStarts { completeStart(at: pendingStarts.count - 1) }
    }

    func stop(completion: @escaping () -> Void) {
        stopCount += 1
        pendingStops.append(completion)
        onStop?()
        if !deferStops { completion() }
    }

    func completeStart(at index: Int) {
        pendingStarts[index](.success(CaptureRuntimeInfo(deviceName: "Test Camera",
            logURL: URL(fileURLWithPath: "/tmp/test.jsonl"))))
    }

    func completeStop(at index: Int) { pendingStops[index]() }
}

private final class SleepPreventerStub: IdleSleepPreventing {
    var acquireError: Error?
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0

    func acquire() throws {
        acquireCount += 1
        if let acquireError { throw acquireError }
    }

    func release() {
        releaseCount += 1
    }
}
