import Foundation
import CoreGraphics

/// Main-thread owned; never activates the app, unlocks macOS, or repeatedly blanks
/// a screen the user has deliberately woken.
final class DisplaySleepController {
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    // True while a turn-off after the app's own wake request is pending. A later
    // input-respecting request must not replace it: the wake request reads as fresh input.
    private var forcedPending = false

    func cancel() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        forcedPending = false
    }

    /// Seconds since any keyboard, mouse or tablet input in this login session. Quartz keeps a
    /// combined counter for all input types (kCGAnyInputEventType, raw value ~0); the per-type
    /// list is the fallback should that value ever fail to map. Remote input such as Screen
    /// Sharing counts as presence: it is someone using the Mac.
    static var secondsSinceInput: TimeInterval {
        if let anyInput = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        }
        let input: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                   .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        return input.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }

    func turnOffOnce(respectExistingInput: Bool = false) {
        if respectExistingInput && forcedPending { return }
        cancel()
        if respectExistingInput {
            let idle = Self.secondsSinceInput
            guard idle >= 2 else {
                NSLog("MacMonitor: display off skipped; input %.1f s ago at the request", idle)
                return
            }
        }
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
            let idle = Self.secondsSinceInput
            guard idle >= max(0, elapsed) else {
                NSLog("MacMonitor: display off skipped; input %.1f s ago, %.1f s after the request", idle, elapsed)
                return
            }
            NSLog("MacMonitor: turning the display off (input %.1f s ago)", idle)
            Self.runDisplaySleep()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Turns the display off about a second after the app's own full-wake request, without
    /// the input check: the request itself reads as input. Checks 3 s later that the display
    /// is really asleep and tries once more if not, logging each step.
    func turnOffAfterOwnWake() {
        cancel()
        forcedPending = true
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = nil
            self.forcedPending = false
            NSLog("MacMonitor: turning the display off after the wake request (input %.1f s ago)", Self.secondsSinceInput)
            Self.runDisplaySleep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.generation == token else { return }
                if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
                    NSLog("MacMonitor: display is off after the wake request")
                    return
                }
                NSLog("MacMonitor: display still on 3 s after turning it off; trying once more")
                Self.runDisplaySleep()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.generation == token else { return }
                    NSLog("MacMonitor: display %@ after the second try",
                          CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "is off" : "is still on")
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static func runDisplaySleep() {
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

    deinit { pending?.cancel() }
}
