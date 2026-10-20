import AppKit
import MacMonitorCore

extension Notification.Name {
    static let monitoringSettingsChanged = Notification.Name("local.macmonitor.settingsChanged")
}

enum PowerScheduleSettings {
    /// pmset repeat is machine-wide. Always show the existing schedule before replacing it.
    static func apply(_ schedule: DailySleepSchedule, replacing previous: DailySleepSchedule) throws -> Bool {
        try schedule.validate()
        guard schedule.requiresSystemUpdate(replacing: previous) else { return true }
        let current = try currentSchedule()
        let alert = NSAlert()
        alert.messageText = schedule.usesSystemSchedule ? "Mac의 매일 잠자기·깨우기 예약 적용" : "Mac의 반복 전원 예약 해제"
        let change = schedule.usesSystemSchedule
            ? "매일 \(DailySleepSchedule.timeString(schedule.sleepMinute)) 잠자기 → \(DailySleepSchedule.timeString(schedule.wakeMinute)) 깨우기"
            : "현재 Mac의 반복 잠자기·깨우기 예약을 취소합니다."
        alert.informativeText = "\(change)\n\n이 설정은 Mac 전체에 적용되며 기존 반복 전원 예약을 교체합니다. 앱을 종료해도 시스템 예약은 남습니다. 관리자 비밀번호가 필요합니다.\n\n현재 예약:\n\(current)"
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let command: String
        if schedule.usesSystemSchedule {
            command = "/usr/bin/pmset repeat sleep MTWRFSU \(DailySleepSchedule.timeString(schedule.sleepMinute)) wake MTWRFSU \(DailySleepSchedule.timeString(schedule.wakeMinute))"
        } else {
            command = "/usr/bin/pmset repeat cancel"
        }
        // Only validated integers and fixed command fragments enter this script.
        guard let script = NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges") else {
            throw AppConfigurationError.invalid("전원 예약 스크립트")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            throw AppPasswordError.message("전원 예약을 적용하지 못했습니다: \(error[NSAppleScript.errorMessage] ?? error)")
        }
        return true
    }

    private static func currentSchedule() throws -> String {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "sched"]
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw AppPasswordError.message("현재 전원 예약을 읽을 수 없습니다.")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
