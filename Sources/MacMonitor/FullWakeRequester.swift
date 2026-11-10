import Foundation
import IOKit.pwr_mgt

/// Turns a dark wake into a full wake by declaring user activity, as `caffeinate -u` does.
/// In a dark wake the display, the camera and the microphone stay off (pmset shows the wake
/// without the V and A capabilities) and PreventUserIdleSystemSleep does not hold the Mac
/// up, so a capture started there gets no frames and the Mac sleeps again within a minute
/// (seen on the target iMac, 2026-11-10). The declaration lights the display; the caller
/// turns it back off.
final class FullWakeRequester {
    // IOKit asks callers to pass the previous id back in on every later call.
    private var assertionID = IOPMAssertionID(0)

    @discardableResult
    func request() -> Bool {
        let result = IOPMAssertionDeclareUserActivity(
            "MacMonitor 원격 카메라 요청: 잠든 Mac을 완전히 깨웁니다." as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        if result != kIOReturnSuccess {
            NSLog("MacMonitor: full wake request failed (IOKit %d)", result)
        }
        return result == kIOReturnSuccess
    }
}
