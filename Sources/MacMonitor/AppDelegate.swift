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
    private let statusMenuItem = NSMenuItem(title: "감시 중지됨", action: nil, keyEquivalent: "")
    private let archiveMenuItem = NSMenuItem(title: "원격 녹화 — 확인 중", action: nil, keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "감시 시작", action: #selector(startMonitoring), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "감시 중지", action: #selector(stopMonitoring), keyEquivalent: "x")
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

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        archiveMenuItem.isEnabled = false
        menu.addItem(archiveMenuItem)
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
            schedule = try AppConfiguration.loadOrCreate().sleepSchedule
        } catch {
            AppPasswordPrompt.showError(error.localizedDescription)
        }
        monitoringWanted = LaunchAtLoginManager.isEnabled || schedule.enabled
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
        monitoringRequested = false
        evaluateSchedule()
    }

    @objc private func stopMonitoring() {
        monitoringWanted = false
        reconcileMonitoring()
    }

    @objc private func settingsChanged() {
        do {
            let next = try AppConfiguration.loadOrCreate().sleepSchedule
            if next != schedule {
                displaySleep.cancel()
                schedule = next
                wasRestTime = nil
                if schedule.enabled { monitoringWanted = true }
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
        reconcileMonitoring()
    }

    @objc private func didWake() {
        guard authenticated, !terminating else { return }
        systemSleeping = false
        archiveAccess.start()
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
        reconcileMonitoring()
    }

    private func reconcileMonitoring() {
        guard authenticated, !terminating else { return }
        let resting = schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes)
        healthReporter.setPauseReason(systemSleeping ? .systemSleep : resting ? .scheduledRest : monitoringWanted ? nil : .manualStop)
        let shouldRun = monitoringWanted && !systemSleeping &&
            !resting
        if shouldRun {
            guard !stoppingForPower, !monitoringRequested else { return }
            monitoringRequested = true
            coordinator.start()
        } else if monitoringRequested && !stoppingForPower {
            stoppingForPower = true
            coordinator.stop { [weak self] in
                guard let self else { return }
                self.monitoringRequested = false
                self.stoppingForPower = false
                self.reconcileMonitoring()
            }
        }
        if schedule.enabled && schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes) {
            statusMenuItem.title = "예약 휴식 중 — \(DailySleepSchedule.timeString(schedule.wakeMinute)) 감시 재개"
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
        switch state {
        case .stopped: archiveMenuItem.title = "원격 녹화 — 중지됨"
        case .notConfigured: archiveMenuItem.title = "원격 녹화 — HTTPS 설정 필요"
        case .starting: archiveMenuItem.title = "원격 녹화 — 연결 준비 중"
        case .running: archiveMenuItem.title = "원격 녹화 — 웹 서버 실행 중"
        case let .failed(message): archiveMenuItem.title = "원격 녹화 오류 — \(message)"
        }
    }

    private func render(_ state: MonitoringState) {
        healthReporter.updateState(state)
        statusMenuItem.title = state.displayText

        switch state {
        case .idle, .failed:
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(
                systemSymbolName: "video.slash",
                accessibilityDescription: state.displayText
            )
        case .running:
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            statusItem.button?.image = NSImage(
                systemSymbolName: "video.fill",
                accessibilityDescription: state.displayText
            )
        case .requestingCameraPermission, .starting, .recovering, .stopping:
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = state != .stopping
        }
        statusItem.button?.toolTip = state.displayText
        if schedule.enabled && schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes) {
            statusMenuItem.title = "예약 휴식 중 — \(DailySleepSchedule.timeString(schedule.wakeMinute)) 감시 재개"
        }
    }
}
