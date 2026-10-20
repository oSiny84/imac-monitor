import AppKit
import AVFoundation
import MacMonitorCore

final class SettingsWindowController: NSWindowController {
    private let cameraPopup = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "로그인 시 실행 (비밀번호 확인 후 감시)",
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
    private let preRollPopup = NSPopUpButton()
    private let postRollPopup = NSPopUpButton()
    private let scheduleCheckbox = NSButton(checkboxWithTitle: "매일 예약 사용", target: nil, action: nil)
    private let restModePopup = NSPopUpButton()
    private let sleepPicker = NSDatePicker()
    private let wakePicker = NSDatePicker()
    private let statusLabel = NSTextField(labelWithString: "")
    private var motionRegions = MotionRegions()
    private var regionEditor: MotionRegionEditor?
    var previewLayerProvider: (() -> AVCaptureVideoPreviewLayer)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
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
        for (popup, values) in [(preRollPopup, [0, 5, 15, 30, 60, 120, 300]), (postRollPopup, [5, 15, 30, 60, 120, 300])] {
            for seconds in values {
                popup.addItem(withTitle: seconds < 60 ? "\(seconds)초" : "\(seconds / 60)분")
                popup.lastItem?.tag = seconds
            }
        }
        for picker in [sleepPicker, wakePicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
        }
        restModePopup.addItem(withTitle: "시스템 잠자기 → 깨운 직후 화면 끄기")
        restModePopup.lastItem?.representedObject = ScheduledRestMode.systemSleep.rawValue
        restModePopup.addItem(withTitle: "시스템 유지 · 화면만 끄기")
        restModePopup.lastItem?.representedObject = ScheduledRestMode.displayOnly.rawValue

        let grid = NSGridView(views: [
            row("카메라", cameraPopup),
            row("앱 실행", launchAtLoginCheckbox),
            row("외부 WebRTC 호스트", hostsField),
            row("비디오 비트레이트 (kbps)", bitrateField),
            row("픽셀 차이 임계값", thresholdField),
            row("변화 픽셀 비율", fractionField),
            row("감지·제외 영역", NSButton(title: "영역 편집…", target: self, action: #selector(editRegions))),
            row("움직임 전 보존", preRollPopup),
            row("마지막 움직임 후 보존", postRollPopup),
            row("보관 기간 (일)", retentionDaysField),
            row("최대 녹화 용량 (GB)", maximumStorageField),
            row("최소 디스크 여유 (GB)", minimumFreeField),
            row("예약 휴식", scheduleCheckbox),
            row("휴식 모드", restModePopup),
            row("휴식 시작 시각", sleepPicker),
            row("깨우기·감시 재개 시각", wakePicker)
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let note = NSTextField(wrappingLabelWithString: "움직임 없는 구간은 임시 버퍼에서 삭제됩니다. 시스템 잠자기는 1분 전 감시를 정리하고, 예약 깨우기 후 화면을 끕니다(잠깐 켜질 수 있음). 화면만 끄기는 시스템을 유지하되 휴식 중 감시는 중단합니다. 두 모드 모두 정해진 시각에 감시를 재개합니다. 앱을 실행·인증한 채 두세요. 키보드·마우스 사용은 우선하며, 로그아웃·재부팅 후에는 재인증이 필요합니다.")
        note.textColor = .secondaryLabelColor

        let save = NSButton(title: "저장", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let openFolder = NSButton(title: "설정 폴더 열기", target: self, action: #selector(openConfigurationFolder))
        let password = NSButton(title: "앱 비밀번호 변경", target: self, action: #selector(changePassword))
        let buttons = NSStackView(views: [openFolder, password, NSView(), save])
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
        motionRegions = configuration.motionRegions
        selectSeconds(configuration.preRollSeconds, in: preRollPopup)
        selectSeconds(configuration.postRollSeconds, in: postRollPopup)
        scheduleCheckbox.state = configuration.sleepSchedule.enabled ? .on : .off
        restModePopup.select(restModePopup.itemArray.first {
            ($0.representedObject as? String) == configuration.sleepSchedule.mode.rawValue
        })
        setMinute(configuration.sleepSchedule.sleepMinute, in: sleepPicker)
        setMinute(configuration.sleepSchedule.wakeMinute, in: wakePicker)
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
            minimumFreeGigabytes: minimumFreeField.doubleValue,
            preRollSeconds: preRollPopup.selectedTag(),
            postRollSeconds: postRollPopup.selectedTag(),
            sleepSchedule: DailySleepSchedule(enabled: scheduleCheckbox.state == .on,
                sleepMinute: minute(in: sleepPicker), wakeMinute: minute(in: wakePicker),
                mode: ScheduledRestMode(rawValue: restModePopup.selectedItem?.representedObject as? String ?? "") ?? .systemSleep),
            motionRegions: motionRegions
        )
        var appliedSystemSchedule = false
        do {
            try configuration.validate()
            let previous = try AppConfiguration.loadOrCreate()
            guard try PowerScheduleSettings.apply(configuration.sleepSchedule, replacing: previous.sleepSchedule) else { return }
            appliedSystemSchedule = configuration.sleepSchedule.requiresSystemUpdate(replacing: previous.sleepSchedule)
            try configuration.save()
            NotificationCenter.default.post(name: .monitoringSettingsChanged, object: nil)
            try LaunchAtLoginManager.setEnabled(launchAtLoginCheckbox.state == .on)
            statusLabel.stringValue = "저장했습니다. 감시 설정은 다음 시작, 자동 실행은 다음 로그인부터 적용됩니다."
        } catch {
            statusLabel.stringValue = (appliedSystemSchedule ? "시스템 전원 예약은 적용되었습니다. 앱 설정 저장 상태를 확인하세요. " : "") + error.localizedDescription
        }
    }

    private func selectSeconds(_ seconds: Int, in popup: NSPopUpButton) {
        if popup.itemArray.allSatisfy({ $0.tag != seconds }) {
            popup.addItem(withTitle: "\(seconds)초")
            popup.lastItem?.tag = seconds
        }
        popup.selectItem(withTag: seconds)
    }

    private func setMinute(_ minute: Int, in picker: NSDatePicker) {
        picker.dateValue = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private func minute(in picker: NSDatePicker) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    @objc private func changePassword() { AppPasswordPrompt.change() }

    @objc private func editRegions() {
        guard let window, regionEditor == nil else { return }
        let editor = MotionRegionEditor(regions: motionRegions, preview: previewLayerProvider?()) { [weak self, weak window] value in
            guard let self, let window else { return }
            if let value { self.motionRegions = value }
            if let sheet = self.regionEditor?.window { window.endSheet(sheet); sheet.orderOut(nil) }
            self.regionEditor = nil
        }
        regionEditor = editor
        if let sheet = editor.window { window.beginSheet(sheet) }
    }

    @objc private func openConfigurationFolder() {
        try? AppDirectories.prepare()
        NSWorkspace.shared.open(AppDirectories.root)
    }
}
