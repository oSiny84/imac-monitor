import Darwin
import Foundation
import XCTest
@testable import MacMonitorCore

final class RecordingProtectionTests: XCTestCase {
    func testProtectedFilesSurviveAgeByteAndFreeSpacePressureAcrossManagerRestarts() throws {
        for reason in ["age", "bytes", "free"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let spool = root.appendingPathComponent("spool")
            let recordings = root.appendingPathComponent("recordings")
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            let important = recordings.appendingPathComponent("motion-important.mp4")
            let ordinary = recordings.appendingPathComponent("motion-ordinary.mp4")
            try Data("important".utf8).write(to: important)
            try Data("ordinary".utf8).write(to: ordinary)
            try addMarker(for: important, in: recordings)
            let policy = RetentionPolicy(maximumAge: reason == "age" ? 0 : 86400,
                maximumBytes: reason == "bytes" ? 0 : 1_000_000,
                minimumFreeBytes: reason == "free" ? Int64.max : 0)
            var warnings: [String?] = []
            let first = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
                policy: policy, onWarning: { warnings.append($0) })
            first.runMaintenance(now: Date().addingTimeInterval(60))
            XCTAssertEqual(try Data(contentsOf: important), Data("important".utf8), reason)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ordinary.path), reason)
            if reason != "age" { XCTAssertNotNil(warnings.last ?? nil, reason) }
            // A fresh manager must honor the same marker without any in-memory state.
            let restarted = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings, policy: policy)
            restarted.runMaintenance(now: Date().addingTimeInterval(120))
            XCTAssertTrue(FileManager.default.fileExists(atPath: important.path), reason)
        }
    }

    func testUnprotectReturnsRecordingToRetentionWithoutImmediateDeletionByMetadataEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("recordings")
        let spool = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let file = recordings.appendingPathComponent("motion-test.mp4")
        try Data("video".utf8).write(to: file)
        try addMarker(for: file, in: recordings)
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 0, maximumBytes: 0, minimumFreeBytes: 0))
        manager.runMaintenance(now: Date().addingTimeInterval(60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try RecordingProtectionStore(directory: recordings).withExclusiveLock {
            try FileManager.default.removeItem(at: marker(for: file, in: recordings))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        manager.runMaintenance(now: Date().addingTimeInterval(120))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnknownMetadataOrBusyLockDefersDeletionThenResumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("recordings")
        let spool = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let file = recordings.appendingPathComponent("motion-test.mp4")
        let metadata = recordings.appendingPathComponent(RecordingProtectionStore.metadataName)
        try Data("video".utf8).write(to: file)
        var warning: String?
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 0, maximumBytes: 0, minimumFreeBytes: 0), onWarning: { warning = $0 })
        try Data("not a directory".utf8).write(to: metadata)
        manager.runMaintenance(now: Date().addingTimeInterval(60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(warning)
        try FileManager.default.removeItem(at: metadata)
        try RecordingProtectionStore(directory: recordings).withExclusiveLock {
            manager.runMaintenance(now: Date().addingTimeInterval(60))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        manager.runMaintenance(now: Date().addingTimeInterval(60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(warning)
    }

    func testMetadataSymlinkIsRejectedAndMarkerSymlinkStillPreservesSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("recordings")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = RecordingProtectionStore(directory: recordings)
        let metadata = recordings.appendingPathComponent(RecordingProtectionStore.metadataName)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
        XCTAssertThrowsError(try store.withExclusiveLock {})
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let video = recordings.appendingPathComponent("motion-test.mp4")
        try FileManager.default.createSymbolicLink(at: marker(for: video, in: recordings), withDestinationURL: outside)
        try store.withExclusiveLock { XCTAssertTrue(try store.isProtected(video)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: recordings.appendingPathComponent(RecordingProtectionStore.lockName).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    private func marker(for file: URL, in directory: URL) -> URL {
        directory.appendingPathComponent(RecordingProtectionStore.metadataName).appendingPathComponent(file.lastPathComponent + ".keep")
    }

    private func addMarker(for file: URL, in directory: URL) throws {
        try RecordingProtectionStore(directory: directory).withExclusiveLock {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(RecordingProtectionStore.metadataName), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: marker(for: file, in: directory))
        }
    }
}
