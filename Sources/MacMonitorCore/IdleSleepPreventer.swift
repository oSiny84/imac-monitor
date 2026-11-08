import Foundation
import IOKit.pwr_mgt

public enum IdleSleepPreventerError: LocalizedError {
    case assertionCreationFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case let .assertionCreationFailed(code):
            return "시스템 유휴 잠자기 방지 설정에 실패했습니다 (IOKit \(code))."
        }
    }
}

/// Prevents automatic system idle sleep while intentionally allowing display sleep.
/// It does not prevent sleep requested explicitly from the Apple menu or by other causes.
public final class IdleSleepPreventer: IdleSleepPreventing {
    public enum Kind {
        /// The usual assertion: no idle sleep while the user session is awake.
        case preventUserIdleSystemSleep
        /// Also holds a dark wake open. A scheduled wake may be a dark wake, and only this
        /// assertion keeps the Mac from going straight back to sleep before the gateway and
        /// the chat bot have had their check window.
        case preventSystemSleep
    }

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private let reason: String
    private let kind: Kind

    public init(kind: Kind = .preventUserIdleSystemSleep,
                reason: String = "MacMonitor가 카메라를 사용 중입니다. 디스플레이 절전은 계속 허용됩니다.") {
        self.kind = kind
        self.reason = reason
    }

    public func acquire() throws {
        lock.lock()
        defer { lock.unlock() }

        guard assertionID == nil else { return }

        var newAssertionID = IOPMAssertionID(0)
        let type: CFString
        switch kind {
        case .preventUserIdleSystemSleep: type = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .preventSystemSleep: type = kIOPMAssertionTypePreventSystemSleep as CFString
        }
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            throw IdleSleepPreventerError.assertionCreationFailed(result)
        }
        assertionID = newAssertionID
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }

        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    deinit {
        release()
    }
}
