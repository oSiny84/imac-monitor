import Foundation
import IOKit.pwr_mgt

/// Turns a dark wake into a full wake by declaring user activity, as `caffeinate -u` does.
/// In a dark wake the display, the camera and the microphone stay off (pmset shows the wake
/// without the V and A capabilities) and PreventUserIdleSystemSleep does not hold the Mac
/// up, so a capture started there gets no frames and the Mac sleeps again within a minute
/// (seen on the target iMac, 2026-11-10). The local declaration lights the display; the caller
/// turns it back off.
///
/// The remote declaration is an experiment (2026-11-27): IOPMLib.h describes it only as
/// "Remote User connected to the system". Whether it brings the camera up without lighting
/// the display is not documented, so the caller checks for frames and falls back to local.
final class FullWakeRequester {
    enum Kind {
        case local
        case remote
    }

    // IOKit asks callers to pass the previous id back in on every later call. The two kinds
    // are separate assertions, so each keeps its own id.
    private var localID = IOPMAssertionID(0)
    private var remoteID = IOPMAssertionID(0)

    @discardableResult
    func request(_ kind: Kind = .local) -> Bool {
        let result: IOReturn
        switch kind {
        case .local:
            result = IOPMAssertionDeclareUserActivity(
                "MacMonitor 원격 카메라 요청: 잠든 Mac을 완전히 깨웁니다." as CFString,
                kIOPMUserActiveLocal,
                &localID
            )
        case .remote:
            result = IOPMAssertionDeclareUserActivity(
                "MacMonitor 원격 카메라 요청: 화면을 켜지 않고 깨웁니다." as CFString,
                kIOPMUserActiveRemote,
                &remoteID
            )
        }
        if result != kIOReturnSuccess {
            NSLog("MacMonitor: %@ wake request failed (IOKit %d)", kind == .local ? "full" : "quiet", result)
        }
        return result == kIOReturnSuccess
    }
}
