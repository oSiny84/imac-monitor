import Foundation

public final class MonitoringCoordinator {
    public var onStateChange: ((MonitoringState) -> Void)?

    private let camera: CameraCapturing
    private let idleSleepPreventer: IdleSleepPreventing
    private let pipeline: MonitoringPipelineControlling?
    private let recoveryDelays: [TimeInterval]
    private let recoveryResetInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.macmonitor.monitoring.coordinator")
    private var state: MonitoringState = .idle
    private var generation: UInt64 = 0
    private var recoveryAttempt = 0
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryBudgetResetWorkItem: DispatchWorkItem?
    private var explicitStopInProgress = false
    private var stopCompletions: [() -> Void] = []

    public init(
        camera: CameraCapturing,
        idleSleepPreventer: IdleSleepPreventing,
        pipeline: MonitoringPipelineControlling? = nil,
        recoveryDelays: [TimeInterval] = [2, 5, 15],
        recoveryResetInterval: TimeInterval = 300
    ) {
        self.camera = camera
        self.idleSleepPreventer = idleSleepPreventer
        self.pipeline = pipeline
        self.recoveryDelays = recoveryDelays
        self.recoveryResetInterval = recoveryResetInterval
        camera.failureHandler = { [weak self] error in
            self?.handleRuntimeFailure(error)
        }
        pipeline?.failureHandler = { [weak self] error in
            self?.handleRuntimeFailure(error)
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .idle, .failed:
                break
            default:
                return
            }

            self.recoveryWorkItem?.cancel()
            self.recoveryWorkItem = nil
            self.cancelRecoveryBudgetReset()
            self.recoveryAttempt = 0
            self.generation &+= 1
            let runGeneration = self.generation
            self.beginStart(generation: runGeneration, isRecovery: false)
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }

            self.recoveryWorkItem?.cancel()
            self.recoveryWorkItem = nil
            self.cancelRecoveryBudgetReset()
            if self.explicitStopInProgress {
                if let completion { self.stopCompletions.append(completion) }
                return
            }
            self.generation &+= 1
            let stopGeneration = self.generation
            if self.state == .idle {
                DispatchQueue.main.async { completion?() }
                return
            }

            self.explicitStopInProgress = true
            if let completion { self.stopCompletions.append(completion) }
            self.transition(to: .stopping)
            self.camera.stop { [weak self] in
                self?.queue.async {
                    guard let self else {
                        DispatchQueue.main.async { completion?() }
                        return
                    }
                    guard self.explicitStopInProgress,
                          self.generation == stopGeneration else { return }
                    self.pipeline?.stop()
                    self.idleSleepPreventer.release()
                    self.explicitStopInProgress = false
                    self.transition(to: .idle)
                    let completions = self.stopCompletions
                    self.stopCompletions.removeAll()
                    DispatchQueue.main.async { completions.forEach { $0() } }
                }
            }
        }
    }

    private func beginStart(generation: UInt64, isRecovery: Bool) {
        transition(to: .requestingCameraPermission)
        camera.requestAuthorization { [weak self] authorized in
            self?.queue.async {
                self?.continueStart(
                    authorized: authorized,
                    generation: generation,
                    isRecovery: isRecovery
                )
            }
        }
    }

    private func continueStart(authorized: Bool, generation: UInt64, isRecovery: Bool) {
        guard generation == self.generation else { return }
        guard authorized else {
            finishStartFailure("카메라 권한이 필요합니다.", isRecovery: isRecovery)
            return
        }

        transition(to: .starting)
        do {
            try idleSleepPreventer.acquire()
            try pipeline?.start()
        } catch {
            pipeline?.stop()
            idleSleepPreventer.release()
            finishStartFailure(error.localizedDescription, isRecovery: isRecovery)
            return
        }

        camera.start { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                // A stop or a runtime-failure cleanup owns obsolete generations. An old
                // camera callback can arrive after the replacement run starts, so cleaning
                // up here would stop the replacement camera/pipeline as well.
                guard generation == self.generation else { return }

                switch result {
                case let .success(info):
                    self.transition(to: .running(info))
                    self.scheduleRecoveryBudgetReset(generation: generation)
                case let .failure(error):
                    self.pipeline?.stop()
                    self.idleSleepPreventer.release()
                    self.finishStartFailure(
                        error.localizedDescription,
                        isRecovery: isRecovery
                    )
                }
            }
        }
    }

    private func transition(to newState: MonitoringState) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    private func handleRuntimeFailure(_ error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .starting, .running:
                break
            default:
                return
            }
            self.cancelRecoveryBudgetReset()
            self.generation &+= 1
            let failureGeneration = self.generation
            self.transition(to: .stopping)
            self.camera.stop { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    guard self.generation == failureGeneration else { return }
                    self.pipeline?.stop()
                    self.idleSleepPreventer.release()
                    self.scheduleRecovery(after: error.localizedDescription)
                }
            }
        }
    }

    private func finishStartFailure(_ message: String, isRecovery: Bool) {
        if isRecovery {
            scheduleRecovery(after: message)
        } else {
            transition(to: .failed(message))
        }
    }

    /// Restores the full automatic recovery budget once monitoring has stayed up for
    /// `recoveryResetInterval`.
    ///
    /// Without this the budget is a lifetime cap rather than a flapping guard: a single
    /// recovery weeks earlier would leave unattended monitoring with fewer attempts, and
    /// after `recoveryDelays.count` lifetime failures a lone transient fault would stop
    /// monitoring until someone restarted it by hand. Repeated failures inside the interval
    /// still exhaust the budget and surface `.failed`.
    private func scheduleRecoveryBudgetReset(generation: UInt64) {
        cancelRecoveryBudgetReset()
        guard recoveryAttempt > 0, recoveryResetInterval > 0 else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == generation,
                  case .running = self.state else { return }
            self.recoveryBudgetResetWorkItem = nil
            self.recoveryAttempt = 0
        }
        recoveryBudgetResetWorkItem = workItem
        queue.asyncAfter(deadline: .now() + recoveryResetInterval, execute: workItem)
    }

    private func cancelRecoveryBudgetReset() {
        recoveryBudgetResetWorkItem?.cancel()
        recoveryBudgetResetWorkItem = nil
    }

    private func scheduleRecovery(after message: String) {
        cancelRecoveryBudgetReset()
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        guard recoveryAttempt < recoveryDelays.count else {
            transition(to: .failed(message))
            return
        }

        let delay = max(0, recoveryDelays[recoveryAttempt])
        recoveryAttempt += 1
        transition(
            to: .recovering(
                attempt: recoveryAttempt,
                maximum: recoveryDelays.count,
                delaySeconds: Int(delay.rounded(.up))
            )
        )
        let expectedGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  case .recovering = self.state else { return }
            self.recoveryWorkItem = nil
            self.generation &+= 1
            self.beginStart(generation: self.generation, isRecovery: true)
        }
        recoveryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
