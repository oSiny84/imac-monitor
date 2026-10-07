import XCTest
@testable import MacMonitorCore

final class LogFileRotatorTests: XCTestCase {
    func testRotatesAtLimitAndKeepsConfiguredGenerations() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let log = directory.appendingPathComponent("service.log")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data("first".utf8).write(to: log)
        try LogFileRotator.rotateIfNeeded(at: log, maximumBytes: 5, backupCount: 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: "\(log.path).1")), "first")

        try Data("second".utf8).write(to: log)
        try LogFileRotator.rotateIfNeeded(at: log, maximumBytes: 5, backupCount: 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: "\(log.path).1")), "second")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: "\(log.path).2")), "first")

        try Data("third".utf8).write(to: log)
        try LogFileRotator.rotateIfNeeded(at: log, maximumBytes: 5, backupCount: 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: "\(log.path).2")), "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
}
