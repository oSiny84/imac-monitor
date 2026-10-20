import CoreMedia
import Foundation

final class CaptureProbeLogger {
    private struct Event: Encodable {
        let timestamp: String
        let uptimeSeconds: TimeInterval
        let kind: String
        let device: String?
        let totalFrames: UInt64?
        let width: Int32?
        let height: Int32?
    }

    static let diagnosticsDirectoryURL: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("MacMonitor", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    static let defaultLogURL = diagnosticsDirectoryURL
        .appendingPathComponent("capture-probe.jsonl", isDirectory: false)

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let heartbeatInterval: TimeInterval
    private let fileHandle: FileHandle
    private var totalFrames: UInt64 = 0
    private var lastHeartbeatUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(heartbeatInterval: TimeInterval = 10) throws {
        self.heartbeatInterval = heartbeatInterval

        try AppDirectories.prepare()
        try FileManager.default.createDirectory(
            at: Self.diagnosticsDirectoryURL,
            withIntermediateDirectories: true
        )
        try LogFileRotator.rotateIfNeeded(at: Self.defaultLogURL)
        if !FileManager.default.fileExists(atPath: Self.defaultLogURL.path) {
            FileManager.default.createFile(atPath: Self.defaultLogURL.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: Self.defaultLogURL)
        fileHandle.seekToEndOfFile()
    }

    func recordStarted(deviceName: String) {
        write(
            Event(
                timestamp: Self.timestamp(),
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                kind: "capture_started",
                device: deviceName,
                totalFrames: 0,
                width: nil,
                height: nil
            )
        )
    }

    func recordFrame(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        totalFrames += 1
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastHeartbeatUptime >= heartbeatInterval else { return }
        lastHeartbeatUptime = uptime

        let dimensions: CMVideoDimensions?
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        } else {
            dimensions = nil
        }

        writeUnlocked(
            Event(
                timestamp: Self.timestamp(),
                uptimeSeconds: uptime,
                kind: "frame_heartbeat",
                device: nil,
                totalFrames: totalFrames,
                width: dimensions?.width,
                height: dimensions?.height
            )
        )
    }

    func recordStopped() {
        lock.lock()
        defer { lock.unlock() }
        writeUnlocked(
            Event(
                timestamp: Self.timestamp(),
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                kind: "capture_stopped",
                device: nil,
                totalFrames: totalFrames,
                width: nil,
                height: nil
            )
        )
    }

    private func write(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        writeUnlocked(event)
    }

    private func writeUnlocked(_ event: Event) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        // The legacy write(_:) raises an Objective-C exception on an I/O failure (for
        // example a disk filling up). Diagnostic logging must not crash monitoring.
        try? fileHandle.write(contentsOf: data)
        try? fileHandle.synchronize()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    deinit {
        try? fileHandle.close()
    }
}
