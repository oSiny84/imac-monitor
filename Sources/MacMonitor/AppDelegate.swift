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
    private let stopTimedRecordingMenuItem = NSMenuItem(title: "원격 녹화 중지", action: #selector(stopTimedRecording), keyEquivalent: "")
    private var readyToTerminate = false
    private var settingsWindowController: SettingsWindowController?
    private var authenticated = false
    private var terminating = false
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
    // The remote "record for N hours" request, read from the gateway's file like the viewer lease.
    private let recordingDemand = RecordingDemandMonitor()
    private var timedRecording: RecordingDemand?
    // The mode the running capture was started with. Stays .off while no capture is requested.
    private var activeMode: CaptureMode = .off
    private var lastState: MonitoringState = .idle
    private var lastFailureUptime: TimeInterval = 0
    private var archiveState: ArchiveAccessState = .stopped
    // Separate from the coordinator: waiting for a viewer must keep the Mac reachable with the camera off.
    private let remoteStandbySleepPreventer = IdleSleepPreventer(reason: "MacMonitor 원격 시청 대기: 시스템은 깨어 있고 화면 절전은 허용됩니다.")
    // A scheduled wake can be a dark wake that ends in seconds; this stronger assertion keeps
    // it open for the check window so the gateway can fetch a pending chat request.
    private let checkWindowPreventer = IdleSleepPreventer(kind: .preventSystemSleep,
        reason: "MacMonitor 슬림 모드 확인 창: 깨어난 뒤 요청을 확인하는 동안 잠들지 않습니다.")
    private var wokeFromSleep = false
    // Set when a wake was found from the clock gap with no wake notification, which is how a
    // dark wake looks from here. A capture request in that state asks for a full wake.
    private var darkWakeSuspected = false
    private let fullWake = FullWakeRequester()
    private var remoteActivity: NSObjectProtocol?
    private var reportedStandbyPowerError = false
    // Slim mode: the Mac may sleep between requests and wakes itself on a schedule.
    private var slimMode = SlimModeSettings()
    private let slimPolicy = SlimModePolicy()
    private let power = PowerCommandRunner()
    private var canScheduleWake = false
    private var wakeUptime = ProcessInfo.processInfo.systemUptime
    private var captureEndedUptime: TimeInterval?
    private var lastDesired: CaptureMode = .off
    private var lastTickDate = Date()
    private var lastTickUptime = ProcessInfo.processInfo.systemUptime
    private var pendingWake: (stamp: String, date: Date)?
    private var sleepRequestedUptime: TimeInterval?
    private var slimStatus: String?
    private var lastSlimExplanation: String?

    override init() {
        let healthReporter = MonitoringHealthReporter()
        self.healthReporter = healthReporter
        let pipeline = LocalMonitoringPipeline(healthReporter: healthReporter)
        self.pipeline = pipeline
        let camera = CameraCaptureService(
                deviceUniqueIDProvider: {
                    (try? AppConfiguration.loadOrCreate())?.cameraUniqueID
                },
                audioEnabledProvider: {
                    (try? AppConfiguration.loadOrCreate())?.audioEnabled ?? true
                },
                frameHandler: { [weak pipeline, weak healthReporter] sampleBuffer in
                    healthReporter?.recordFrame()
                    pipeline?.consume(sampleBuffer: sampleBuffer)
                },
                audioHandler: { [weak pipeline] sampleBuffer in
                    pipeline?.consume(audioSampleBuffer: sampleBuffer)
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

        stopTimedRecordingMenuItem.target = self
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
        menu.addItem(stopTimedRecordingMenuItem)
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
        center.addObserver(self, selector: #selector(didFullWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .monitoringSettingsChanged, object: nil)
        do {
            let configuration = try AppConfiguration.loadOrCreate()
            schedule = configuration.sleepSchedule
            slimMode = configuration.slimMode
            liveStandby = configuration.liveStandby
        } catch {
            // The defaults leave slim mode off; the menu must say why instead of looking normal.
            slimStatus = "설정 파일 오류 — \(error.localizedDescription)"
            AppPasswordPrompt.showError(error.localizedDescription)
        }
        refreshWakeCapability()
        liveDemand.onChange = { [weak self] demanded in
            self?.liveDemanded = demanded
            self?.reconcileMonitoring()
        }
        recordingDemand.onChange = { [weak self] demand in
            self?.timedRecording = demand
            self?.reconcileMonitoring()
        }
        recordingDemand.start()
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
        cancelPendingWake()
        displaySleep.cancel()
        displayOnlySleepPreventer.release()
        checkWindowPreventer.release()
        liveDemand.stop()
        recordingDemand.stop()
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
            }
            slimMode = configuration.slimMode
            refreshWakeCapability()
            if configuration.liveStandby != liveStandby {
                liveStandby = configuration.liveStandby
                applyLiveStandby()
            }
            evaluateSchedule()
            archiveAccess.refresh()
        } catch { AppPasswordPrompt.showError(error.localizedDescription) }
    }

    @objc private func willSleep() {
        NSLog("MacMonitor slim: system is going to sleep")
        displaySleep.cancel()
        scheduleWakeIfNeeded()
        // Taken now, before the sleep, so it is already held when the scheduled wake arrives:
        // a dark wake can end within seconds, before the ten-second tick has noticed it. The
        // assertion does not stop this sleep, and the check-window logic releases it 90 s
        // after the wake.
        if slimMode.enabled && canScheduleWake { try? checkWindowPreventer.acquire() }
        sleepStartedAt = Date()
        systemSleeping = true
        darkWakeSuspected = false
        archiveAccess.stop()
        // Uptime stops during sleep, so a lease must not look fresh again after waking.
        liveDemand.stop()
        reconcileMonitoring()
    }

    /// The notification is posted for full wakes only, so the camera can be used as it is.
    @objc private func didFullWake() {
        darkWakeSuspected = false
        didWake()
    }

    private func didWake() {
        guard authenticated, !terminating else { return }
        systemSleeping = false
        let wokeOnSchedule = noteWake()
        NSLog("MacMonitor slim: woke up (%@)", wokeOnSchedule ? "our scheduled wake" : "other cause")
        archiveAccess.start()
        applyLiveStandby()
        sleepStartedAt = nil
        evaluateSchedule()
        if wokeOnSchedule || schedule.isNearScheduledWake(at: Date()) ||
            (schedule.enabled && schedule.mode == .displayOnly && schedule.isRestTime(at: Date())) {
            displaySleep.turnOffOnce(respectExistingInput: true)
        }
    }

    private func evaluateSchedule() {
        guard authenticated, !terminating else { return }
        detectSleepGap()
        // The display-only rest keeps the system up only during the rest itself; holding the
        // assertion all day would keep slim mode's Energy Saver fallback off for no reason.
        if schedule.enabled && schedule.mode == .displayOnly &&
            schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes) {
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
        wasRestTime = resting
        // A viewer cannot press retry at the Mac. The decision covers a failed recording too,
        // because recording wins the capture mode and its failure would otherwise block the viewer.
        if CaptureModePolicy.shouldRetryFailedCapture(
            state: lastState,
            viewerWaiting: liveStandby && liveDemanded,
            captureRequested: monitoringRequested,
            stopping: stoppingForPower,
            secondsSinceFailure: ProcessInfo.processInfo.systemUptime - lastFailureUptime
        ) {
            monitoringRequested = false
            activeMode = .off
        }
        reconcileMonitoring()
    }

    private func reconcileMonitoring() {
        guard authenticated, !terminating else { return }
        let resting = schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes)
        let desired = CaptureModePolicy.desiredMode(
            timedRecording: timedRecording?.isActive(at: Date()) ?? false,
            resting: resting,
            systemSleeping: systemSleeping,
            liveStandby: liveStandby,
            liveDemanded: liveDemanded
        )
        if lastDesired != .off, desired == .off { captureEndedUptime = ProcessInfo.processInfo.systemUptime }
        lastDesired = desired
        if desired != .off, darkWakeSuspected {
            // One request per wake. The display lights for about a second: requirement 7
            // gives way here by the owner's decision (2026-11-11), because the camera does
            // not run in a dark wake. A display that sleeps while the Mac stays fully awake
            // never takes this path.
            darkWakeSuspected = false
            NSLog("MacMonitor: capture requested in a dark wake; asking for a full wake")
            if fullWake.request() { displaySleep.turnOffOnce(respectExistingInput: true) }
        }
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
                pipeline.setCaptureMode(desired)
                monitoringRequested = true
                coordinator.start()
            } else if activeMode != desired {
                // Recording and live-only are different encoder outputs, so switching restarts
                // the capture. The reconcile after the stop starts the new mode, and a viewer's
                // player reconnects on its own.
                stopCapture()
            }
        }
        healthReporter.setRemoteState(captureMode: activeMode, liveStandby: liveStandby, slimMode: slimMode.enabled)
        updateRemotePower(resting: resting, captureWanted: desired != .off)
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
    /// Slim mode adds one exception: with nobody watching and nothing recording, the Mac may
    /// sleep, and the wake written in willSleep brings it back for the next check.
    private func updateRemotePower(resting: Bool, captureWanted: Bool) {
        let gatewayExpected: Bool
        switch archiveState {
        case .starting, .running, .failed:
            gatewayExpected = true
        case .stopped, .notConfigured:
            gatewayExpected = false
        }
        let reachable = liveStandby && gatewayExpected && !systemSleeping && !(schedule.usesSystemSchedule && resting)
        let uptime = ProcessInfo.processInfo.systemUptime
        let inputs = SlimModePolicy.Inputs(
            enabled: slimMode.enabled,
            canScheduleWake: canScheduleWake,
            captureWanted: captureWanted || monitoringRequested,
            uptime: uptime,
            wakeUptime: wakeUptime,
            captureEndedUptime: captureEndedUptime,
            secondsSinceInput: DisplaySleepController.secondsSinceInput,
            wokeFromSleep: wokeFromSleep
        )
        let decision = slimPolicy.decide(inputs)
        if slimMode.enabled, wokeFromSleep, uptime - wakeUptime < slimPolicy.checkWindow {
            try? checkWindowPreventer.acquire()
        } else {
            checkWindowPreventer.release()
        }
        // The owner can only see this decision through the status board and Telegram, and the
        // Mac test can only judge it from Console, so every change is written to both.
        var explanation = slimPolicy.explain(inputs)
        if let slimStatus, slimStatus.hasPrefix("잠자기 실패") { explanation += " · \(slimStatus)" }
        if explanation != lastSlimExplanation {
            lastSlimExplanation = explanation
            NSLog("MacMonitor slim: %@ (reachable %d, input %.0fs ago, since wake %.0fs)",
                  explanation, reachable ? 1 : 0, inputs.secondsSinceInput, uptime - wakeUptime)
        }
        healthReporter.setSlimDetail(slimMode.enabled ? explanation : nil)
        let standing = reachable && decision == .holdAwake
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
        let needsPromptTimers = reachable || monitoringRequested
        if needsPromptTimers, remoteActivity == nil {
            remoteActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "MacMonitor 원격 시청 대기"
            )
        } else if !needsPromptTimers, let activity = remoteActivity {
            ProcessInfo.processInfo.endActivity(activity)
            remoteActivity = nil
        }
        // Energy Saver alone would sleep much later or never, so slim mode asks itself. One
        // request per wake, retried after two minutes if the Mac is somehow still up. The
        // display-only rest is the user's own "keep the system up", so it is never overridden.
        let keepingSystemUpForRest = schedule.enabled && schedule.mode == .displayOnly && resting
        if decision == .sleepNow, !systemSleeping, !terminating, !keepingSystemUpForRest,
           sleepRequestedUptime.map({ uptime - $0 > 120 }) ?? true {
            sleepRequestedUptime = uptime
            NSLog("MacMonitor slim: requesting sleep (pmset sleepnow)")
            do {
                try power.sleepNow()
            } catch {
                NSLog("MacMonitor: sleep request failed: %@", error.localizedDescription)
                slimStatus = "잠자기 실패 — \(error.localizedDescription)"
            }
        }
    }

    // MARK: Slim mode

    /// Whether this Mac can schedule its own wake-ups, proven by scheduling and cancelling one a
    /// day out. Asked whenever the settings change and never assumed, because a Mac that cannot
    /// wake itself must stay awake; a problem found at willSleep would be found too late.
    private func refreshWakeCapability() {
        if slimStatus?.hasPrefix("슬림 모드 대기") == true { slimStatus = nil }
        guard slimMode.enabled else {
            canScheduleWake = false
            return
        }
        do {
            try power.proveWakeScheduling()
            canScheduleWake = true
        } catch {
            canScheduleWake = false
            NSLog("MacMonitor: wake scheduling probe failed: %@", error.localizedDescription)
            if slimMode.enabled {
                slimStatus = "슬림 모드 대기 — 깨우기 예약 확인 실패: \(error.localizedDescription) · scripts/enable-slim-mode.sh"
            }
        }
    }

    /// Runs right before sleep, whatever caused it. The daily rest's repeat schedule wakes the
    /// Mac in the morning on its own, so no periodic wake is added during that rest.
    private func scheduleWakeIfNeeded() {
        guard canScheduleWake, slimMode.enabled else { return }
        let now = Date()
        if schedule.usesSystemSchedule, schedule.isRestTime(at: now, preparationMinutes: schedule.preparationMinutes) { return }
        guard let target = slimPolicy.nextWake(after: now, interval: slimMode.wakeInterval) else { return }
        cancelPendingWake()
        do {
            let stamp = try power.scheduleWake(at: target)
            pendingWake = (stamp, target)
            slimStatus = nil
            NSLog("MacMonitor slim: wake scheduled for %@", stamp)
        } catch {
            NSLog("MacMonitor: wake scheduling failed: %@", error.localizedDescription)
            slimStatus = "깨우기 예약 실패 — \(error.localizedDescription)"
        }
    }

    private func cancelPendingWake() {
        guard let pending = pendingWake else { return }
        pendingWake = nil
        power.cancelWake(pending.stamp)
    }

    /// Opens the check window for this wake. Returns whether it is the wake we scheduled, in
    /// which case the display may be turned back off.
    private func noteWake() -> Bool {
        wakeUptime = ProcessInfo.processInfo.systemUptime
        wokeFromSleep = true
        sleepRequestedUptime = nil
        let onSchedule = SlimModePolicy.isNear(Date(), scheduled: pendingWake?.date)
        cancelPendingWake()
        return onSchedule
    }

    /// A scheduled wake can be a dark wake that posts no notification. The ten-second tick
    /// compares wall-clock progress with uptime, which pauses during sleep.
    private func detectSleepGap() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let slept = slimPolicy.slept(wallClockElapsed: now.timeIntervalSince(lastTickDate), uptimeElapsed: uptime - lastTickUptime)
        lastTickDate = now
        lastTickUptime = uptime
        guard slept else { return }
        NSLog("MacMonitor: sleep detected from the clock gap")
        if systemSleeping {
            // willSleep ran but didWake never came; finish the wake ourselves.
            darkWakeSuspected = true
            didWake()
        } else if noteWake() {
            displaySleep.turnOffOnce(respectExistingInput: true)
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
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The web started this recording; the owner at the Mac may end it. Removing the gateway's
    /// file is the same thing the web's 녹화 중지 does.
    @objc private func stopTimedRecording() {
        guard authenticated else { return }
        do {
            try recordingDemand.cancel()
        } catch {
            AppPasswordPrompt.showError("원격 녹화 요청을 지우지 못했습니다: \(error.localizedDescription)")
        }
        timedRecording = nil
        reconcileMonitoring()
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
            if let slimStatus {
                title += " · \(slimStatus)"
            } else if slimMode.enabled {
                title += " · 슬림 모드"
            }
        case .running:
            symbol = "video.fill"
            if activeMode == .timed, let until = timedRecording?.until {
                title += " · \(Self.clockText(until))까지"
            }
            if case let .running(info) = lastState {
                if let problem = pipeline.audioProblem {
                    title += " · 소리 없음 — \(problem)"
                } else if let reason = info.audio.reason {
                    title += " · 소리 없음 — \(reason)"
                }
            }
        case .failed:
            symbol = "video.slash"
        case .requestingCameraPermission, .starting, .recovering, .stopping:
            symbol = "video"
        }
        if activeMode != .live, schedule.enabled,
           schedule.isRestTime(at: Date(), preparationMinutes: schedule.preparationMinutes) {
            title = "예약 휴식 중 — \(DailySleepSchedule.timeString(schedule.wakeMinute)) 재개"
        }
        statusMenuItem.title = title
        statusItem.button?.toolTip = title
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        stopTimedRecordingMenuItem.isEnabled = timedRecording != nil
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: date)
    }
}
