import Foundation
import CoreGraphics

/// Main-thread owned; never activates the app, unlocks macOS, or repeatedly blanks
/// a screen the user has deliberately woken.
final class DisplaySleepController {
    private var pending: DispatchWorkItem?
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        pending?.cancel()
        pending = nil
    }

    private static var secondsSinceInput: TimeInterval {
        let input: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                   .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        return input.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }

    func turnOffOnce(respectExistingInput: Bool = false) {
        cancel()
        guard !respectExistingInput || Self.secondsSinceInput >= 2 else { return }
        let token = generation
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = nil
            // Allow the click which saved settings, but respect new local input
            // while the wake/display-off request was pending. No event tap needed.
            // Main-queue work may run later than one second (for example, while
            // processing settings). Respect input anywhere in that whole wait.
            let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
            guard Self.secondsSinceInput >= max(0, elapsed) else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { task in
                if task.terminationStatus != 0 {
                    NSLog("MacMonitor: display sleep failed (pmset status %d)", task.terminationStatus)
                }
            }
            do { try process.run() }
            catch { NSLog("MacMonitor: display sleep failed: %@", error.localizedDescription) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    deinit { pending?.cancel() }
}
