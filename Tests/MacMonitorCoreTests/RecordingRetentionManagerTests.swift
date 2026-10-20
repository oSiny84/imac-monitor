import XCTest
@testable import MacMonitorCore

final class RecordingRetentionManagerTests: XCTestCase {
    func testNearbyMotionWindowsDoNotConsumeEachOthersSharedSegment() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let merger = MergerStub()
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 86400, maximumBytes: 1_000_000, minimumFreeBytes: 0),
            eventMerger: merger)
        let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let names = stride(from: -5, through: 35, by: 5).map {
            "segment-\(timestamp(base.addingTimeInterval(Double($0)))).mp4"
        }
        for name in names { try Data(name.utf8).write(to: spool.appendingPathComponent(name)) }

        // Windows [-3,17] and [19,39] are disjoint, but both need segment [15,20].
        // Merging them independently used to remove that segment from the second event.
        manager.recordMotion(at: base.addingTimeInterval(2))
        manager.recordMotion(at: base.addingTimeInterval(24))
        manager.runMaintenance(now: base.addingTimeInterval(60))

        XCTAssertEqual(merger.mergeCallCount, 1)
        XCTAssertEqual(merger.receivedSegmentNames, names)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool.path), [])
    }

    func testMinutePreRollAndHalfMinutePostRollExcludeQuietFootage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 86400, maximumBytes: 1_000_000, minimumFreeBytes: 0,
                preRoll: 60, postRoll: 30))
        let base = Date(timeIntervalSince1970: 1_791_417_600)
        let offsets = [-70, -65, -60, -30, 0, 25, 30, 60]
        for offset in offsets {
            let name = "segment-\(timestamp(base.addingTimeInterval(Double(offset)))).mp4"
            try Data("segment".utf8).write(to: spool.appendingPathComponent(name))
        }
        manager.recordMotion(at: base)
        manager.runMaintenance(now: base.addingTimeInterval(150))
        let names = try visibleNames(in: recordings).sorted()
        let expected = [-60, -30, 0, 25].map {
            "segment-\(timestamp(base.addingTimeInterval(Double($0)))).mp4"
        }.sorted()
        XCTAssertEqual(names, expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool.path), [])
    }

    func testNoMotionProducesNoSavedRecording() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let manager = RecordingRetentionManager(spoolDirectory: spool, recordingsDirectory: recordings,
            policy: RetentionPolicy(maximumAge: 86400, maximumBytes: 1_000_000, minimumFreeBytes: 0, preRoll: 60, postRoll: 60))
        let now = Date()
        let name = "segment-\(timestamp(now.addingTimeInterval(-120))).mp4"
        try Data("quiet".utf8).write(to: spool.appendingPathComponent(name))
        manager.runMaintenance(now: now)
        XCTAssertEqual(try visibleNames(in: recordings), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool.path), [])
    }

    func testFinalizationKeepsOnlySegmentsAroundMotion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = RecordingRetentionManager(
            spoolDirectory: spool,
            recordingsDirectory: recordings,
            policy: RetentionPolicy(
                maximumAge: 86_400,
                maximumBytes: 1_000_000,
                minimumFreeBytes: 0
            )
        )
        try manager.start()
        let now = Date()
        let matchingName = "segment-\(timestamp(now)).mp4"
        let oldName = "segment-\(timestamp(now.addingTimeInterval(-120))).mp4"
        try Data("matching".utf8).write(to: spool.appendingPathComponent(matchingName))
        try Data("old".utf8).write(to: spool.appendingPathComponent(oldName))

        manager.recordMotion(at: now)
        manager.stopAndFinalize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.appendingPathComponent(matchingName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.appendingPathComponent(oldName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent(oldName).path))
    }

    func testFinalizationMergesSegmentsIntoOneMotionEvent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let merger = MergerStub()
        let manager = RecordingRetentionManager(
            spoolDirectory: spool,
            recordingsDirectory: recordings,
            policy: RetentionPolicy(
                maximumAge: 86_400,
                maximumBytes: 1_000_000,
                minimumFreeBytes: 0
            ),
            eventMerger: merger
        )
        try manager.start()
        let now = Date()
        let first = "segment-\(timestamp(now)).mp4"
        let second = "segment-\(timestamp(now.addingTimeInterval(5))).mp4"
        try Data("first".utf8).write(to: spool.appendingPathComponent(first))
        try Data("second".utf8).write(to: spool.appendingPathComponent(second))
        manager.recordMotion(at: now.addingTimeInterval(2))

        manager.stopAndFinalize()

        XCTAssertEqual(merger.receivedSegmentCount, 2)
        let output = recordings.appendingPathComponent("motion-test.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.appendingPathComponent(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.appendingPathComponent(second).path))
    }

    func testMergeFailurePreservesOriginalSegments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let merger = MergerStub(shouldFail: true)
        let manager = RecordingRetentionManager(
            spoolDirectory: spool,
            recordingsDirectory: recordings,
            policy: RetentionPolicy(
                maximumAge: 86_400,
                maximumBytes: 1_000_000,
                minimumFreeBytes: 0
            ),
            eventMerger: merger
        )
        try manager.start()
        let now = Date()
        let name = "segment-\(timestamp(now)).mp4"
        try Data("segment".utf8).write(to: spool.appendingPathComponent(name))
        manager.recordMotion(at: now)

        manager.stopAndFinalize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.appendingPathComponent(name).path))
    }

    /// A motion event rarely lines up with the 5 second segment grid, so the segment holding the
    /// end of the post-roll is promoted out of the spool later than the merge used to wait for.
    /// The merge must not run until that segment has arrived, otherwise the event file loses the
    /// tail of its post-roll and the late segment is orphaned in the recordings directory.
    func testTimedMergeWaitsForTheSegmentHoldingTheEndOfThePostRoll() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        let merger = MergerStub()
        let manager = RecordingRetentionManager(
            spoolDirectory: spool,
            recordingsDirectory: recordings,
            policy: RetentionPolicy(
                maximumAge: 86_400,
                maximumBytes: 1_000_000,
                minimumFreeBytes: 0
            ),
            eventMerger: merger
        )

        // Whole seconds only: segment names carry one second of resolution.
        let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let unrelated = "segment-\(timestamp(base.addingTimeInterval(-60))).mp4"
        let overlapping = [-5.0, 0, 5, 10, 15].map {
            "segment-\(timestamp(base.addingTimeInterval($0))).mp4"
        }
        for name in [unrelated] + overlapping {
            try Data(name.utf8).write(to: spool.appendingPathComponent(name))
        }

        // Motion at base+2 makes the window [base-3, base+17]. The last overlapping segment
        // starts at base+15 and is only promoted at base+27.
        manager.recordMotion(at: base.addingTimeInterval(2))

        manager.runMaintenance(now: base.addingTimeInterval(25))

        XCTAssertEqual(merger.mergeCallCount, 0, "merge ran before the final segment was promoted")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: spool.appendingPathComponent(overlapping[4]).path),
            "the segment holding the end of the post-roll should still be in the spool"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent(unrelated).path))

        manager.runMaintenance(now: base.addingTimeInterval(30))

        XCTAssertEqual(merger.mergeCallCount, 1)
        XCTAssertEqual(merger.receivedSegmentNames, overlapping)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recordings.appendingPathComponent("motion-test.mp4").path)
        )
        for name in overlapping {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: recordings.appendingPathComponent(name).path),
                "\(name) was left behind as an orphan instead of being merged"
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool.path), [])
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

private final class MergerStub: RecordingEventMerging {
    let shouldFail: Bool
    private(set) var receivedSegmentCount = 0
    private(set) var mergeCallCount = 0
    private(set) var receivedSegmentNames: [String] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func merge(
        segmentURLs: [URL],
        eventStart: Date,
        destinationDirectory: URL
    ) throws -> URL {
        receivedSegmentCount = segmentURLs.count
        mergeCallCount += 1
        receivedSegmentNames = segmentURLs.map(\.lastPathComponent)
        if shouldFail { throw NSError(domain: "MergerStub", code: 1) }
        let destination = destinationDirectory.appendingPathComponent("motion-test.mp4")
        try Data("merged".utf8).write(to: destination)
        return destination
    }
}
