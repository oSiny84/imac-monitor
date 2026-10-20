import AppKit
import MacMonitorCore

enum AppPasswordPrompt {
    static func unlock() -> Bool {
        do {
            guard let record = try AppPasswordStore.load() else { return setPassword() }
            for _ in 0..<3 {
                guard let password = request(title: "MacMonitor 잠금 해제", message: "앱 비밀번호를 입력하세요.") else { return false }
                if try record.matches(password) { return true }
                showError("비밀번호가 맞지 않습니다.")
            }
            showError("비밀번호 확인에 3회 실패했습니다. 앱을 종료합니다.")
        } catch { showError(error.localizedDescription) }
        return false
    }

    static func change() {
        guard unlock() else { return }
        _ = setPassword()
    }

    private static func setPassword() -> Bool {
        while true {
            guard let password = request(title: "앱 비밀번호 설정", message: "12자 이상의 앱 비밀번호를 정하세요. 웹 접속 비밀번호와 별개입니다."),
                  let confirmation = request(title: "비밀번호 확인", message: "같은 비밀번호를 한 번 더 입력하세요.") else { return false }
            guard password == confirmation else {
                showError("두 비밀번호가 다릅니다.")
                continue
            }
            do {
                try AppPasswordStore.save(password: password)
                return true
            } catch { showError(error.localizedDescription) }
        }
    }

    private static func request(title: String, message: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacMonitor"
        alert.informativeText = message
        alert.runModal()
    }
}
