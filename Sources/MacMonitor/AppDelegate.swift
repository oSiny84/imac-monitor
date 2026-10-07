import AppKit
import MacMonitorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pipeline: LocalMonitoringPipeline
    private let coordinator: MonitoringCoordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "감시 중지됨", action: nil, keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "감시 시작", action: #selector(startMonitoring), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "감시 중지", action: #selector(stopMonitoring), keyEquivalent: "x")
    private var readyToTerminate = false
    private var settingsWindowController: SettingsWindowController?

    override init() {
        let pipeline = LocalMonitoringPipeline()
        self.pipeline = pipeline
        coordinator = MonitoringCoordinator(
            camera: CameraCaptureService(
                deviceUniqueIDProvider: {
                    (try? AppConfiguration.loadOrCreate())?.cameraUniqueID
                },
                frameHandler: { [weak pipeline] sampleBuffer in
                    pipeline?.consume(sampleBuffer: sampleBuffer)
                }
            ),
            idleSleepPreventer: IdleSleepPreventer(),
            pipeline: pipeline
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "video", accessibilityDescription: "MacMonitor")
            button.toolTip = "MacMonitor"
        }

        startMenuItem.target = self
        stopMenuItem.target = self

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
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
        if LaunchAtLoginManager.isEnabled {
            coordinator.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !readyToTerminate else { return .terminateNow }
        coordinator.stop { [weak self] in
            self?.readyToTerminate = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func startMonitoring() {
        coordinator.start()
    }

    @objc private func stopMonitoring() {
        coordinator.stop()
    }

    @objc private func openDiagnostics() {
        let directory = CameraCaptureService.diagnosticsDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func openSettings() {
        let controller = settingsWindowController ?? SettingsWindowController()
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func render(_ state: MonitoringState) {
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
    }
}
