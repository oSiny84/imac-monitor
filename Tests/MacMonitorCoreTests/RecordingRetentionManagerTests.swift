import XCTest
@testable import MacMonitorCore

final class RecordingRetentionManagerTests: XCTestCase {
    private func makeDirectories() throws -> (root: URL, spool: URL, recordings: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let spool = root.appendingPathComponent("spool")
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        return (root, spool, recordings)
    }

    func testEveryClosedClipIsPromotedAndReportedAndStoppingFinalizesTheLast() throws {
        let (root, spool, recordings) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        var promoted: [String] = []
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 86400, maximumBytes: 1_000_000, minimumFreeBytes: 0, segmentDuration: 600),
            onPromoted: { promoted.append($0.lastPathComponent) })
        // stopAndFinalize applies the age limit against the real clock, so the clip names must
        // be recent; a fixed date older than maximumAge would be deleted at the finalize step.
        let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let names = [0, 600, 1200].map { "remote-\(timestamp(base.addingTimeInterval(Double($0)))).mp4" }
        for name in names { try Data(name.utf8).write(to: spool.appendingPathComponent(name)) }

        // The first clip closed at +600 s and is promoted ten seconds later; the others wait.
        manager.runMaintenance(now: base.addingTimeInterval(1205))
        XCTAssertEqual(try visibleNames(in: recordings).sorted(), [names[0]])
        XCTAssertEqual(promoted, [names[0]])
        manager.runMaintenance(now: base.addingTimeInterval(1215))
        XCTAssertEqual(try visibleNames(in: recordings).sorted(), Array(names[0...1]))
        // Stopping finalizes the clip FFmpeg just closed, so the end of a recording loses nothing.
        manager.stopAndFinalize()
        XCTAssertEqual(try visibleNames(in: recordings).sorted(), names)
        XCTAssertEqual(promoted, names)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool.path), [])
    }

    func testTheSizeLimitRemovesTheOldestRecordingsFirstAndClearsTheWarningOnceWithinBounds() throws {
        let (root, spool, recordings) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings: [String?] = []
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 86400, maximumBytes: 25, minimumFreeBytes: 0),
            onWarning: { warnings.append($0) })
        let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let names = [0, 600, 1200].map { "remote-\(timestamp(base.addingTimeInterval(Double($0)))).mp4" }
        for name in names { try Data(repeating: 0x41, count: 10).write(to: recordings.appendingPathComponent(name)) }

        manager.runMaintenance(now: base.addingTimeInterval(1800))
        XCTAssertEqual(try visibleNames(in: recordings).sorted(), Array(names[1...]), "the oldest clip goes first")
        XCTAssertEqual(warnings, [nil], "twenty bytes fit under the limit, so there is nothing to warn about")
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    private func visibleNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .map(\.lastPathComponent)
    }
}
