import AppKit
import MacMonitorCore

final class SettingsWindowController: NSWindowController {
    private let cameraPopup = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "다음 로그인부터 앱 실행 및 감시 시작",
        target: nil,
        action: nil
    )
    private let hostsField = NSTextField()
    private let bitrateField = NSTextField()
    private let thresholdField = NSTextField()
    private let fractionField = NSTextField()
    private let retentionDaysField = NSTextField()
    private let maximumStorageField = NSTextField()
    private let minimumFreeField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacMonitor 설정"
        window.center()
        self.init(window: window)
        buildUI()
        load()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: "감시 및 네트워크 설정")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let grid = NSGridView(views: [
            row("카메라", cameraPopup),
            row("앱 실행", launchAtLoginCheckbox),
            row("외부 WebRTC 호스트", hostsField),
            row("비디오 비트레이트 (kbps)", bitrateField),
            row("픽셀 차이 임계값", thresholdField),
            row("변화 픽셀 비율", fractionField),
            row("보관 기간 (일)", retentionDaysField),
            row("최대 녹화 용량 (GB)", maximumStorageField),
            row("최소 디스크 여유 (GB)", minimumFreeField)
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let note = NSTextField(wrappingLabelWithString: "호스트는 쉼표로 구분합니다. 변경사항은 다음 감시 시작부터 적용됩니다. HTTPS 인증서와 비밀번호는 scripts/configure-gateway.sh로 설정합니다.")
        note.textColor = .secondaryLabelColor

        let save = NSButton(title: "저장", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let openFolder = NSButton(title: "설정 폴더 열기", target: self, action: #selector(openConfigurationFolder))
        let buttons = NSStackView(views: [openFolder, NSView(), save])
        buttons.orientation = .horizontal

        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, grid, note, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func row(_ title: String, _ field: NSView) -> [NSView] {
        (field as? NSTextField)?.alignment = .right
        return [NSTextField(labelWithString: title), field]
    }

    private func load() {
        let configuration = (try? AppConfiguration.loadOrCreate()) ?? AppConfiguration()
        cameraPopup.removeAllItems()
        cameraPopup.addItem(withTitle: "시스템 기본 카메라")
        cameraPopup.lastItem?.representedObject = ""
        for device in CameraCaptureService.availableDevices() {
            cameraPopup.addItem(withTitle: device.name)
            cameraPopup.lastItem?.representedObject = device.uniqueID
        }
        if let selected = configuration.cameraUniqueID,
           let item = cameraPopup.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
            cameraPopup.select(item)
        } else {
            cameraPopup.selectItem(at: 0)
        }
        hostsField.stringValue = configuration.externalWebRTCHosts.joined(separator: ", ")
        launchAtLoginCheckbox.state = LaunchAtLoginManager.isEnabled ? .on : .off
        bitrateField.integerValue = configuration.videoBitrateKbps
        thresholdField.doubleValue = configuration.motionPixelThreshold
        fractionField.doubleValue = configuration.motionChangedFraction
        retentionDaysField.integerValue = configuration.retentionDays
        maximumStorageField.doubleValue = configuration.retentionMaxGigabytes
        minimumFreeField.doubleValue = configuration.minimumFreeGigabytes
        statusLabel.stringValue = FileManager.default.fileExists(atPath: AppDirectories.gatewayConfiguration.path)
            ? "HTTPS 게이트웨이 설정 파일이 있습니다."
            : "HTTPS 게이트웨이는 아직 설정되지 않았습니다. 로컬 녹화는 사용할 수 있습니다."
    }

    @objc private func save() {
        let hosts = hostsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let configuration = AppConfiguration(
            cameraUniqueID: (cameraPopup.selectedItem?.representedObject as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            externalWebRTCHosts: hosts,
            videoBitrateKbps: bitrateField.integerValue,
            motionPixelThreshold: thresholdField.doubleValue,
            motionChangedFraction: fractionField.doubleValue,
            retentionDays: retentionDaysField.integerValue,
            retentionMaxGigabytes: maximumStorageField.doubleValue,
            minimumFreeGigabytes: minimumFreeField.doubleValue
        )
        do {
            try configuration.save()
            try LaunchAtLoginManager.setEnabled(launchAtLoginCheckbox.state == .on)
            statusLabel.stringValue = "저장했습니다. 감시 설정은 다음 시작, 자동 실행은 다음 로그인부터 적용됩니다."
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func openConfigurationFolder() {
        try? AppDirectories.prepare()
        NSWorkspace.shared.open(AppDirectories.root)
    }
}
