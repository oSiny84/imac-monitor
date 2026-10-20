import Foundation
import XCTest
@testable import MacMonitorCore

final class ArchiveAccessControllerTests: XCTestCase {
    func testUnchangedStartAndRefreshKeepExistingWebSessions() {
        let gateway = ArchiveGatewayStub()
        let controller = ArchiveAccessController(gateway: gateway, pollInterval: 0) { Data("config".utf8) }
        let stopped = expectation(description: "all operations complete")
        controller.start()
        controller.start()
        controller.refresh()
        controller.refresh()
        controller.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(gateway.starts, 1, "an unchanged web server must not restart when capture starts again")
        XCTAssertFalse(gateway.isRunning)
    }

    func testFirstSetupReplacementAndRemovalWhileCaptureIsNotRunning() {
        let gateway = ArchiveGatewayStub()
        let configuration = ArchiveConfigurationStub()
        let controller = ArchiveAccessController(gateway: gateway, pollInterval: 0) { configuration.data }
        let unconfigured = expectation(description: "no HTTPS setup")
        let firstRunning = expectation(description: "first setup applied")
        let replacementRunning = expectation(description: "replacement setup applied")
        let removed = expectation(description: "setup removed")
        var runningCount = 0
        var missingCount = 0
        controller.onStateChange = { state in
            if state == .notConfigured {
                missingCount += 1
                if missingCount == 1 { unconfigured.fulfill() } else { removed.fulfill() }
            }
            if state == .running {
                runningCount += 1
                if runningCount == 1 { firstRunning.fulfill() } else { replacementRunning.fulfill() }
            }
        }
        controller.start()
        wait(for: [unconfigured], timeout: 2)
        XCTAssertEqual(gateway.starts, 0)
        configuration.data = Data("first".utf8)
        controller.refresh()
        wait(for: [firstRunning], timeout: 2)
        configuration.data = Data("replacement".utf8)
        controller.refresh()
        wait(for: [replacementRunning], timeout: 2)
        configuration.data = nil
        controller.refresh()
        wait(for: [removed], timeout: 2)
        XCTAssertEqual(gateway.starts, 2)
        XCTAssertFalse(gateway.isRunning)
        stop(controller)
    }

    func testGatewayFailureRecoversAndObsoleteFailureCannotStopReplacement() {
        let gateway = ArchiveGatewayStub()
        let controller = ArchiveAccessController(gateway: gateway, pollInterval: 0) { Data("config".utf8) }
        let firstRunning = expectation(description: "first run")
        let replacementRunning = expectation(description: "replacement run")
        let failed = expectation(description: "independent gateway failure")
        var runningCount = 0
        var failures = 0
        controller.onStateChange = { state in
            if state == .running {
                runningCount += 1
                if runningCount == 1 { firstRunning.fulfill() } else { replacementRunning.fulfill() }
            }
            if case .failed = state { failures += 1; failed.fulfill() }
        }
        controller.start()
        wait(for: [firstRunning], timeout: 2)
        let obsolete = gateway.failureHandler
        obsolete?(ArchiveTestError.failed)
        wait(for: [failed], timeout: 2)
        controller.refresh()
        wait(for: [replacementRunning], timeout: 2)
        obsolete?(ArchiveTestError.failed)
        controller.refresh()
        stop(controller)
        XCTAssertEqual(gateway.starts, 2)
        XCTAssertEqual(failures, 1)
    }

    func testSleepOrQuitStopsRetriesUntilExplicitWakeStart() {
        let gateway = ArchiveGatewayStub()
        let controller = ArchiveAccessController(gateway: gateway, pollInterval: 0) { Data("config".utf8) }
        let running = expectation(description: "web started")
        controller.onStateChange = { state in if state == .running { running.fulfill() } }
        controller.start()
        wait(for: [running], timeout: 2)
        let obsolete = gateway.failureHandler
        controller.onStateChange = nil
        stop(controller)
        controller.refresh()
        obsolete?(ArchiveTestError.failed)
        stop(controller)
        XCTAssertEqual(gateway.starts, 1)
        controller.start()
        stop(controller)
        XCTAssertEqual(gateway.starts, 2, "wake must re-enable web access even if capture stays stopped")
    }

    func testTransientStartupFailureRetriesWithoutStartingCapture() {
        let gateway = ArchiveGatewayStub()
        gateway.failNextStart = true
        let controller = ArchiveAccessController(gateway: gateway, pollInterval: 0.02) { Data("config".utf8) }
        let recovered = expectation(description: "web independently recovered")
        controller.onStateChange = { state in if state == .running { recovered.fulfill() } }
        controller.start()
        wait(for: [recovered], timeout: 2)
        stop(controller)
        XCTAssertEqual(gateway.starts, 2)
    }

    private func stop(_ controller: ArchiveAccessController) {
        let stopped = expectation(description: "web stop complete")
        controller.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
    }
}

private final class ArchiveGatewayStub: ArchiveGatewayControlling {
    private let lock = NSLock()
    private var handler: ((Error) -> Void)?
    private var startCount = 0
    private var running = false
    private var failStart = false
    var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var failNextStart: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failStart }
        set { lock.lock(); defer { lock.unlock() }; failStart = newValue }
    }
    var failureHandler: ((Error) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }
    func startIfConfigured() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        startCount += 1
        if failStart { failStart = false; throw ArchiveTestError.failed }
        running = true
        return true
    }
    func stop() { lock.lock(); defer { lock.unlock() }; running = false }
}

private final class ArchiveConfigurationStub {
    private let lock = NSLock()
    private var value: Data?
    var data: Data? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private enum ArchiveTestError: Error { case failed }
