import AppKit
import AVFoundation
import MacMonitorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pipeline: LocalMonitoringPipeline
    private let coordinator: MonitoringCoordinator
    private let healthReporter: MonitoringHealthReporter
    private let camera: CameraCaptureService
    private let archiveAccess = ArchiveAccessController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "상태 확인 중", action: nil, keyEquivalent: "")
    private let archiveMenuItem = NSMenuItem(title: "원격 접속 — 확인 중", action: nil, keyEquivalent: "")
    private let liveStandbyMenuItem = NSMenuItem(title: "원격 시청 대기", action: #selector(toggleLiveStandby), keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "움직임 녹화 시작", action: #selector(startMonitoring), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "움직임 녹화 중지", action: #selector(stopMonitoring), keyEquivalent: "x")
    private var readyToTerminate = false
    private var settingsWindowController: SettingsWindowController?
    private var authenticated = false
    private var terminating = false
    private var monitoringWanted = false
    private var monitoringRequested = false
    private var stoppingForPower = false
    private var systemSleeping = false
    private var sleepStartedAt: Date?
    private var schedule = DailySleepSchedule()
    private var wasRestTime: Bool?
    private var scheduleTimer: Timer?
    private let displaySleep = DisplaySleepController()
    // Separate from the coordinator: stopping capture must not release this assertion.
    private let displayOnlySleepPreventer = IdleSleepPreventer(reason: "MacMonitor 화면만 끄기 예약: 시스템은 깨어 있고 화면 절전은 허용됩니다.")
    private var reportedPowerError = false
    private let liveDemand = LiveDemandMonitor()
    private var liveStandby = true
    private var liveDemanded = false
    // The mode the running capture was started with. Stays .off while no capture is requested.
    private var activeMode: CaptureMode = .off
    private var lastState: MonitoringState = .idle
    private var lastFailureUptime: TimeInterval = 0
    private var archiveState: ArchiveAccessState = .stopped
    // Separate from the coordinator: waiting for a viewer must keep the Mac reachable with the camera off.
    private let remoteStandbySleepPreventer = IdleSleepPreventer(reason: "MacMonitor 원격 시청 대기: 시스템은 깨어 있고 화면 절전은 허용됩니다.")
    private var remoteActivity: NSObjectProtocol?
    private var reportedStandbyPowerError = false

    override init() {
        let healthReporter = MonitoringHealthReporter()
        self.healthReporter = healthReporter
        let pipeline = LocalMonitoringPipeline(healthReporter: healthReporter)
        self.pipeline = pipeline
        let camera = CameraCaptureService(
                deviceUniqueIDProvider: {
                    (try? AppConfiguration.loadOrCreate())?.cameraUniqueID
                },
                frameHandler: { [weak pipeline, weak healthReporter] sampleBuffer in
                    healthReporter?.recordFrame()
                    pipeline?.consume(sampleBuffer: sampleBuffer)
                }
            )
        self.camera = camera
        coordinator = MonitoringCoordinator(
            camera: camera,
            idleSleepPreventer: IdleSleepPreventer(),
            pipeline: pipeline
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard AppPasswordPrompt.unlock() else {
            readyToTerminate = true
            NSApp.terminate(nil)
            return
        }
        authenticated = true
        healthReporter.start()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "video", accessibilityDescription: "MacMonitor")
            button.toolTip = "MacMonitor"
        }

        startMenuItem.target = self
        stopMenuItem.target = self
        liveStandbyMenuItem.target = self

        let menu = NSMenu()
        // updateStatusPresentation decides which recording item is available.
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        archiveMenuItem.isEnabled = false
        menu.addItem(archiveMenuItem)
        menu.addItem(.separator())
        menu.addItem(liveStandbyMenuItem)
        menu.addItem(.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "설정…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let restartWebItem = NSMenuItem(title: "원격 웹 다시 시작", action: #selector(restartWeb), keyEquivalent: "")
        restartWebItem.target = self
        menu.addItem(restartWebItem)

        let openLogsItem = NSMenuItem(
            title: "진단 로그 폴더 열기",
            action: #selector(openDiagnostics),
            keyEquivalent: "l"
        )
        openLogsItem.target = self
        menu.addItem(openLogsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "MacMonitor 종료",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        coordinator.onStateChange = { [weak self] state in
            self?.render(state)
        }
        render(.idle)
        archiveAccess.onStateChange = { [weak self] state in self?.renderArchiveAccess(state) }
        archiveAccess.start()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .monitoringSettingsChanged, object: nil)
        do {
            let configuration = try AppConfiguration.loadOrCreate()
            schedule = configuration.sleepSchedule
            liveStandby = configuration.liveStandby
        } catch {
            AppPasswordPrompt.showError(error.localizedDescription)
        }
        // With standby on, logging in means "be reachable", not "start recording".
        monitoringWanted = schedule.enabled || (LaunchAtLoginManager.isEnabled && !liveStandby)
        liveDemand.onChange = { [weak self] demanded in
            self?.liveDemanded = demanded
            self?.reconcileMonitoring()
        }
        applyLiveStandby()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.evaluateSchedule() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        scheduleTimer = timer
        evaluateSchedule()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !readyToTerminate else { return .terminateNow }
        terminating = true
        scheduleTimer?.invalidate()
        displaySleep.cancel()
        displayOnlySleepPreventer.release()
        liveDemand.stop()
        remoteStandbySleepPreventer.release()
        if let activity = remoteActivity {
            ProcessInfo.processInfo.endActivity(activity)
            remoteActivity = nil
        }
        healthReporter.setPauseReason(.manualStop)
        let stopped = DispatchGroup()
        stopped.enter()
        coordinator.stop { [healthReporter = self.healthReporter] in healthReporter.stop { stopped.leave() } }
        stopped.enter()
        archiveAccess.stop { stopped.leave() }
        stopped.notify(queue: .main) { [weak self] in
            self?.readyToTerminate = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func startMonitoring() {
        guard authenticated else { return }
        archiveAccess.refresh()
        monitoringWanted = true
        // Also allows an explicit retry after the coordinator exhausted recovery attempts.
        if case .failed = lastState {
            monitoringRequested = false
            activeMode = .off
        }
        evaluateSchedule()
    }

    @objc private func stopMonitoring() {
        monitoringWanted = false
        reconcileMonitoring()
    }

    @objc private func toggleLiveStandby() {
        guard authenticated else { return }
        do {
            var configuration = try AppConfiguration.loadOrCreateForEditing()
            configuration.liveStandby.toggle()
            try configuration.save()
            NotificationCenter.default.post(name: .monitoringSettingsChanged, object: nil)
        } catch { AppPasswordPrompt.showError(error.localizedDescription) }
    }

    private func applyLiveStandby() {
        liveStandbyMenuItem.state = liveStandby ? .on : .off
        if liveStandby && !systemSleeping {
            liveDemand.start()
        } else {
            liveDemand.stop()
        }
    }

    @objc private func settingsChanged() {
        do {
            let configuration = try AppConfiguration.loadOrCreate()
            let next = configuration.sleepSchedule
            if next != schedule {
                displaySleep.cancel()
                schedule = next
                wasRestTime = nil
                if schedule.enabled { monitoringWanted = true }
            }
            if configuration.liveStandby != liveStandby {
                liveStandby = configuration.liveStandby
                applyLiveStandby()
            }
            evaluateSchedule()
            archiveAccess.refresh()
        } catch { AppPasswordPrompt.showError(error.localizedDescription) }
    }

    @objc private func willSleep() {
        displaySleep.cancel()
        sleepStartedAt = Date()
        systemSleeping = true
        archiveAccess.stop()
        // Uptime stops during sleep, so a lease must not look fresh again after waking.
        liveDemand.stop()
        reconcileMonitoring()
    }

    @objc private func didWake() {
        guard authenticated, !terminating else { return }
        systemSleeping = false
        archiveAccess.start()
        applyLiveStandby()
        let now = Date()
        if let start = sleepStartedAt, schedule.crossesResumeTime(from: start, to: now) {
            monitoringWanted = true
        }
        sleepStartedAt = nil
        evaluateSchedule()
        if schedule.isNearScheduledWake(at: Date()) ||
            (schedule.enabled && schedule.mode == .displayOnly && schedule.isRestTime(at: Date())) {
            displaySleep.turnOffOnce(respectExistingInput: true)
        }
    }

    private func evaluateSchedule() {
        guard authenticated, !terminating else { return }
        if schedule.enabled && schedule.mode == .displayOnly {
            do {
                try displayOnlySleepPreventer.acquire()
                reportedPowerError = false
            } catch {
                if !reportedPowerError {
                    NSLog("MacMonitor: display-only idle sleep prevention failed: %@", error.localizedDescription)
                    reportedPowerError = true
                }
            }
        } else {
            displayOnlySleepPreventer.release()
            reportedPowerError = false
        }
        let resting = schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes)
        if resting && wasRestTime != true && schedule.mode == .displayOnly && !systemSleeping {
            displaySleep.turnOffOnce()
        } else if !resting && wasRestTime == true && schedule.mode == .displayOnly {
            displaySleep.cancel()
        }
        if wasRestTime == true && !resting && schedule.enabled {
            monitoringWanted = true
        }
        wasRestTime = resting
        // Nobody is at the Mac to press retry for a remote viewer, and an exhausted recovery
        // budget must not make the camera unreachable until someone returns.
        if case .failed = lastState, activeMode == .live, liveDemanded, monitoringRequested, !stoppingForPower,
           ProcessInfo.processInfo.systemUptime - lastFailureUptime >= 30 {
            monitoringRequested = false
            activeMode = .off
        }
        reconcileMonitoring()
    }

    private func reconcileMonitoring() {
        guard authenticated, !terminating else { return }
        let resting = schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes)
        let desired = CaptureModePolicy.desiredMode(
            recordingWanted: monitoringWanted,
            resting: resting,
            systemSleeping: systemSleeping,
            liveStandby: liveStandby,
            liveDemanded: liveDemanded
        )
        if systemSleeping {
            healthReporter.setPauseReason(.systemSleep)
        } else if desired != .off {
            healthReporter.setPauseReason(nil)
        } else if resting {
            healthReporter.setPauseReason(.scheduledRest)
        } else {
            healthReporter.setPauseReason(liveStandby ? .remoteStandby : .manualStop)
        }
        if !stoppingForPower {
            if desired == .off {
                if monitoringRequested { stopCapture() }
            } else if !monitoringRequested {
                activeMode = desired
                pipeline.setRecordingEnabled(desired == .recording)
                monitoringRequested = true
                coordinator.start()
            } else if activeMode != desired {
                // Recording and live-only are different encoder outputs, so switching restarts
                // the capture. The reconcile after the stop starts the new mode, and a viewer's
                // player reconnects on its own.
                stopCapture()
            }
        }
        healthReporter.setRemoteState(captureMode: activeMode, liveStandby: liveStandby)
        updateRemotePower(resting: resting)
        updateStatusPresentation()
    }

    private func stopCapture() {
        stoppingForPower = true
        coordinator.stop { [weak self] in
            guard let self else { return }
            self.monitoringRequested = false
            self.stoppingForPower = false
            self.activeMode = .off
            self.reconcileMonitoring()
        }
    }

    /// A viewer can only reach a Mac that is awake, and only a responsive app can start the camera
    /// in time. Display sleep stays allowed; a scheduled system sleep is the user's explicit choice.
    private func updateRemotePower(resting: Bool) {
        let gatewayExpected: Bool
        switch archiveState {
        case .starting, .running, .failed:
            gatewayExpected = true
        case .stopped, .notConfigured:
            gatewayExpected = false
        }
        let standing = liveStandby && gatewayExpected && !systemSleeping && !(schedule.usesSystemSchedule && resting)
        if standing {
            do {
                try remoteStandbySleepPreventer.acquire()
                reportedStandbyPowerError = false
            } catch {
                if !reportedStandbyPowerError {
                    NSLog("MacMonitor: remote standby idle sleep prevention failed: %@", error.localizedDescription)
                    reportedStandbyPowerError = true
                }
            }
        } else {
            remoteStandbySleepPreventer.release()
            reportedStandbyPowerError = false
        }
        // A menu bar app with no visible window is otherwise eligible for App Nap, which would
        // delay the lease poll and the status file the web page reads.
        let needsPromptTimers = standing || monitoringRequested
        if needsPromptTimers, remoteActivity == nil {
            remoteActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "MacMonitor 원격 시청 대기"
            )
        } else if !needsPromptTimers, let activity = remoteActivity {
            ProcessInfo.processInfo.endActivity(activity)
            remoteActivity = nil
        }
    }

    @objc private func openDiagnostics() {
        guard authenticated else { return }
        let directory = CameraCaptureService.diagnosticsDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func openSettings() {
        guard authenticated else { return }
        let controller = settingsWindowController ?? SettingsWindowController()
        controller.previewLayerProvider = { [weak camera = self.camera] in camera?.makePreviewLayer() ?? AVCaptureVideoPreviewLayer() }
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func restartWeb() {
        guard authenticated, !terminating, !systemSleeping else { return }
        archiveAccess.restart()
    }

    private func renderArchiveAccess(_ state: ArchiveAccessState) {
        archiveState = state
        switch state {
        case .stopped: archiveMenuItem.title = "원격 접속 — 중지됨"
        case .notConfigured: archiveMenuItem.title = "원격 접속 — HTTPS 설정 필요"
        case .starting: archiveMenuItem.title = "원격 접속 — 연결 준비 중"
        case .running:
            archiveMenuItem.title = "원격 접속 — 웹 서버 실행 중"
            // Ask while the owner is at the Mac. A remote viewer cannot answer the system prompt.
            if liveStandby { camera.requestAuthorization { _ in } }
        case let .failed(message): archiveMenuItem.title = "원격 접속 오류 — \(message)"
        }
        reconcileMonitoring()
    }

    private func render(_ state: MonitoringState) {
        lastState = state
        if case .failed = state { lastFailureUptime = ProcessInfo.processInfo.systemUptime }
        healthReporter.updateState(state)
        updateStatusPresentation()
    }

    private func updateStatusPresentation() {
        var title = lastState.displayText(for: activeMode)
        var failed = false
        let symbol: String
        switch lastState {
        case .idle:
            symbol = liveStandby ? "video" : "video.slash"
            if liveStandby {
                if case .notConfigured = archiveState {
                    title = "원격 시청 대기 — HTTPS 설정 필요"
                } else {
                    title = "원격 시청 대기 중 — 접속하면 카메라가 켜집니다"
                }
            }
        case .running:
            symbol = "video.fill"
        case .failed:
            symbol = "video.slash"
            failed = true
        case .requestingCameraPermission, .starting, .recovering, .stopping:
            symbol = "video"
        }
        if activeMode != .live, schedule.enabled,
           schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes) {
            title = "예약 휴식 중 — \(DailySleepSchedule.timeString(schedule.wakeMinute)) 녹화 재개"
        }
        statusMenuItem.title = title
        statusItem.button?.toolTip = title
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        startMenuItem.isEnabled = !monitoringWanted || failed
        stopMenuItem.isEnabled = monitoringWanted
    }
}
