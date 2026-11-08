import Foundation
import MacMonitorCore

/// Runs the pmset commands slim mode needs. Scheduling or cancelling a wake is root-only, so
/// those go through `sudo -n` and the one rule scripts/enable-slim-mode.sh installs; sleeping
/// and reading the schedule do not. Every call is synchronous and short; the willSleep handler
/// has only seconds.
final class PowerCommandRunner {
    static let owner = "MacMonitor"

    struct Result {
        let status: Int32
        let output: String
    }

    /// Proves the whole path once: sudo accepts the command without a password, pmset accepts
    /// the date format, the event shows up in the schedule, and it can be cancelled again. It
    /// cannot prove that the hardware fires the wake; only the Mac test can. A Mac that fails
    /// this must stay awake, because a bad schedule would be discovered only after it slept.
    func proveWakeScheduling(now: Date = Date()) throws {
        let stamp = try scheduleWake(at: now.addingTimeInterval(86_400))
        guard cancelWake(stamp) else { throw PowerCommandError.cancelFailed(stamp) }
    }

    /// Schedules the wake and reads the schedule back. A rule that stopped matching would
    /// otherwise leave the Mac asleep until someone comes home, with nothing in the menu.
    func scheduleWake(at date: Date) throws -> String {
        let stamp = SlimModePolicy.pmsetDateString(date)
        let result = run(["/usr/bin/sudo", "-n", "/usr/bin/pmset", "schedule", "wake", stamp, Self.owner])
        guard result.status == 0 else { throw PowerCommandError.failed("pmset schedule wake", result) }
        let listing = run(["/usr/bin/pmset", "-g", "sched"])
        guard listing.output.contains(Self.owner) else { throw PowerCommandError.notListed }
        return stamp
    }

    @discardableResult
    func cancelWake(_ stamp: String) -> Bool {
        let result = run(["/usr/bin/sudo", "-n", "/usr/bin/pmset", "schedule", "cancel", "wake", stamp, Self.owner])
        if result.status != 0 {
            NSLog("MacMonitor: cancelling the wake at %@ failed (status %d)", stamp, result.status)
        }
        return result.status == 0
    }

    func sleepNow() throws {
        let result = run(["/usr/bin/pmset", "sleepnow"])
        guard result.status == 0 else { throw PowerCommandError.failed("pmset sleepnow", result) }
    }

    private func run(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        // sudo -n must fail instead of waiting for a password nobody can type.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

enum PowerCommandError: LocalizedError {
    case failed(String, PowerCommandRunner.Result)
    case notListed
    case cancelFailed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, result):
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) 실패 (상태 \(result.status))\(detail.isEmpty ? "" : ": \(detail)")"
        case .notListed:
            return "깨우기 예약이 pmset -g sched에 보이지 않습니다"
        case let .cancelFailed(stamp):
            return "시험 예약(\(stamp))을 취소하지 못했습니다"
        }
    }
}
