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
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    public init() {}

    public func acquire() throws {
        lock.lock()
        defer { lock.unlock() }

        guard assertionID == nil else { return }

        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacMonitor가 감시 중입니다. 디스플레이 절전은 계속 허용됩니다." as CFString,
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
