import AppKit
import AVFoundation
import MacMonitorCore

final class SettingsWindowController: NSWindowController {
    private let cameraPopup = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "로그인 시 실행 (비밀번호 확인 후 원격 대기)",
        target: nil,
        action: nil
    )
    private let audioCheckbox = NSButton(checkboxWithTitle: "소리 녹음·전송 (마이크, 다음 카메라 시작부터)", target: nil, action: nil)
    private let hostsField = NSTextField()
    private let bitrateField = NSTextField()
    private let retentionDaysField = NSTextField()
    private let maximumStorageField = NSTextField()
    private let minimumFreeField = NSTextField()
    private let scheduleCheckbox = NSButton(checkboxWithTitle: "매일 예약 사용", target: nil, action: nil)
    private let restModePopup = NSPopUpButton()
    private let sleepPicker = NSDatePicker()
    private let wakePicker = NSDatePicker()
    private let slimModeCheckbox = NSButton(checkboxWithTitle: "슬림 모드 (대기 중 Mac 잠자기 허용, 주기적으로 깨어나 확인)", target: nil, action: nil)
    private let wakeIntervalPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
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
        let title = NSTextField(labelWithString: "원격 시청 및 녹화 설정")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        for picker in [sleepPicker, wakePicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
        }
        restModePopup.addItem(withTitle: "시스템 잠자기 → 깨운 직후 화면 끄기")
        restModePopup.lastItem?.representedObject = ScheduledRestMode.systemSleep.rawValue
        restModePopup.addItem(withTitle: "시스템 유지 · 화면만 끄기")
        restModePopup.lastItem?.representedObject = ScheduledRestMode.displayOnly.rawValue
        for minutes in [5, 10, 15, 30, 60] {
            wakeIntervalPopup.addItem(withTitle: "\(minutes)분마다")
            wakeIntervalPopup.lastItem?.tag = minutes
        }
        let grid = NSGridView(views: [
            row("카메라", cameraPopup),
            row("소리", audioCheckbox),
            row("앱 실행", launchAtLoginCheckbox),
            row("외부 WebRTC 호스트", hostsField),
            row("비디오 비트레이트 (kbps)", bitrateField),
            row("보관 기간 (일)", retentionDaysField),
            row("최대 녹화 용량 (GB)", maximumStorageField),
            row("최소 디스크 여유 (GB)", minimumFreeField),
            row("예약 휴식", scheduleCheckbox),
            row("휴식 모드", restModePopup),
            row("휴식 시작 시각", sleepPicker),
            row("깨우기·녹화 재개 시각", wakePicker),
            row("슬림 모드", slimModeCheckbox),
            row("깨어나 확인 간격", wakeIntervalPopup)
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let note = NSTextField(wrappingLabelWithString: "원격 시청은 메뉴의 원격 시청 대기로 켜고 끕니다. 원격 녹화는 웹의 실시간 화면에서 시간을 골라 시작하며, 접속을 끊어도 그 시간까지 10분 단위 파일로 계속 저장합니다. 1,200kbps에서 시간당 약 0.5GB이고 최대 녹화 용량을 넘으면 보호하지 않은 오래된 파일부터 지웁니다. 소리는 다음 카메라 시작부터 적용됩니다. 슬림 모드는 scripts/enable-slim-mode.sh로 깨우기 예약 권한을 넣은 뒤 켭니다. 켜면 시청자·녹화가 없고 깨어난 뒤 입력이 없거나 입력이 5분 없을 때 Mac이 잠들고, 확인 간격마다 약 1분 30초 깨어나 텔레그램 요청을 확인합니다. 매일 예약 휴식의 시스템 잠자기는 1분 전 녹화를 정리하고 예약 깨우기 후 화면을 끕니다(잠깐 켜질 수 있음). 화면만 끄기는 시스템을 유지하되 휴식 중 카메라는 끕니다. 앱을 실행·인증한 채 두세요. 키보드·마우스 사용은 우선하며, 로그아웃·재부팅 후에는 재인증이 필요합니다.")
        note.textColor = .secondaryLabelColor

        let saveButton = NSButton(title: "저장", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let openFolderButton = NSButton(title: "설정 폴더 열기", target: self, action: #selector(openConfigurationFolder))
        let passwordButton = NSButton(title: "앱 비밀번호 변경", target: self, action: #selector(changePassword))
        let buttons = NSStackView(views: [openFolderButton, passwordButton, NSView(), saveButton])
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
        let configuration = (try? AppConfiguration.loadOrCreateForEditing()) ?? AppConfiguration()
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
        audioCheckbox.state = configuration.audioEnabled ? .on : .off
        launchAtLoginCheckbox.state = LaunchAtLoginManager.isEnabled ? .on : .off
        bitrateField.integerValue = configuration.videoBitrateKbps
        retentionDaysField.integerValue = configuration.retentionDays
        maximumStorageField.doubleValue = configuration.retentionMaxGigabytes
        minimumFreeField.doubleValue = configuration.minimumFreeGigabytes
        scheduleCheckbox.state = configuration.sleepSchedule.enabled ? .on : .off
        restModePopup.select(restModePopup.itemArray.first {
            ($0.representedObject as? String) == configuration.sleepSchedule.mode.rawValue
        })
        setMinute(configuration.sleepSchedule.sleepMinute, in: sleepPicker)
        setMinute(configuration.sleepSchedule.wakeMinute, in: wakePicker)
        slimModeCheckbox.state = configuration.slimMode.enabled ? .on : .off
        let wakeMinutes = configuration.slimMode.wakeIntervalMinutes
        if wakeIntervalPopup.itemArray.allSatisfy({ $0.tag != wakeMinutes }) {
            wakeIntervalPopup.addItem(withTitle: "\(wakeMinutes)분마다")
            wakeIntervalPopup.lastItem?.tag = wakeMinutes
        }
        wakeIntervalPopup.selectItem(withTag: wakeMinutes)
        statusLabel.stringValue = FileManager.default.fileExists(atPath: AppDirectories.gatewayConfiguration.path)
            ? "HTTPS 게이트웨이 설정 파일이 있습니다."
            : "HTTPS 게이트웨이가 아직 설정되지 않아 원격 시청과 원격 녹화를 쓸 수 없습니다. docs/SETUP_MAC.md를 참고하세요."
    }

    @objc private func save() {
        let hosts = hostsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var configuration = AppConfiguration(
            cameraUniqueID: (cameraPopup.selectedItem?.representedObject as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            externalWebRTCHosts: hosts,
            videoBitrateKbps: bitrateField.integerValue,
            retentionDays: retentionDaysField.integerValue,
            retentionMaxGigabytes: maximumStorageField.doubleValue,
            minimumFreeGigabytes: minimumFreeField.doubleValue,
            sleepSchedule: DailySleepSchedule(enabled: scheduleCheckbox.state == .on,
                sleepMinute: minute(in: sleepPicker), wakeMinute: minute(in: wakePicker),
                mode: ScheduledRestMode(rawValue: restModePopup.selectedItem?.representedObject as? String ?? "") ?? .systemSleep),
            slimMode: SlimModeSettings(enabled: slimModeCheckbox.state == .on, wakeIntervalMinutes: wakeIntervalPopup.selectedTag()),
            audioEnabled: audioCheckbox.state == .on
        )
        var appliedSystemSchedule = false
        do {
            try configuration.validate()
            let previous = try AppConfiguration.loadOrCreateForEditing()
            // The menu owns this choice, and this window may have been open since before it changed.
            configuration.liveStandby = previous.liveStandby
            guard try PowerScheduleSettings.apply(configuration.sleepSchedule, replacing: previous.sleepSchedule) else {
                statusLabel.stringValue = "취소했습니다. 설정은 저장되지 않았습니다."
                load()
                return
            }
            appliedSystemSchedule = configuration.sleepSchedule.requiresSystemUpdate(replacing: previous.sleepSchedule)
            try configuration.save()
            NotificationCenter.default.post(name: .monitoringSettingsChanged, object: nil)
            try LaunchAtLoginManager.setEnabled(launchAtLoginCheckbox.state == .on)
            statusLabel.stringValue = "저장했습니다. 카메라·네트워크 설정은 다음 카메라 시작, 자동 실행은 다음 로그인부터 적용됩니다."
        } catch {
            statusLabel.stringValue = (appliedSystemSchedule ? "시스템 전원 예약은 적용되었습니다. 앱 설정 저장 상태를 확인하세요. " : "") + error.localizedDescription
        }
    }

    private func setMinute(_ minute: Int, in picker: NSDatePicker) {
        picker.dateValue = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private func minute(in picker: NSDatePicker) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    @objc private func changePassword() { AppPasswordPrompt.change() }

    @objc private func openConfigurationFolder() {
        try? AppDirectories.prepare()
        NSWorkspace.shared.open(AppDirectories.root)
    }
}
