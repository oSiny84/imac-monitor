import Foundation

/// A remote request to record continuously until a wall-clock time. The HTTPS gateway writes
/// `Runtime/recording-demand.json` when the viewer presses 녹화 시작 and removes it when they
/// press 녹화 중지. Unlike the viewer lease this is an explicit end time, so the wall clock is
/// the right reference: the owner asked for "four hours", not "while I watch".
public struct RecordingDemand: Equatable {
    /// Length of each clip written while recording. Ten minutes keeps a crash from losing more
    /// than that and keeps the file count manageable for a day of recording.
    public static let clipDuration: TimeInterval = 600
    public static let maximumHours = 24

    public let until: Date
    public let hours: Int

    public init(until: Date, hours: Int) {
        self.until = until
        self.hours = hours
    }

    public func isActive(at now: Date) -> Bool { until > now }

    /// Reads the gateway's file. A missing, malformed or oversized file means no request: a
    /// wrong file must never start the camera.
    public static func read(from url: URL) -> RecordingDemand? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return decode(data)
    }

    /// The wire format is `{"schemaVersion":1,"until":"2026-11-08T13:00:00Z","hours":4,...}`.
    /// `until` is RFC 3339 without fractional seconds, which the default ISO 8601 parser reads.
    static func decode(_ data: Data) -> RecordingDemand? {
        struct Wire: Decodable {
            let schemaVersion: Int
            let until: String
            let hours: Int
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.schemaVersion == 1,
              (1...maximumHours).contains(wire.hours),
              let until = ISO8601DateFormatter().date(from: wire.until) else { return nil }
        return RecordingDemand(until: until, hours: wire.hours)
    }

    /// Ends a request from the Mac. The gateway treats a missing file as "not recording".
    public static func clear(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Polls the request file so the app starts recording within seconds of the button press and
/// stops at the end time. Same channel as the viewer lease: the gateway is another process.
public final class RecordingDemandMonitor {
    /// Called on the main queue with the active request, or nil once it ends or is cleared.
    public var onChange: ((RecordingDemand?) -> Void)?

    private let fileURL: URL
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.macmonitor.recording-demand")
    private var pollTimer: DispatchSourceTimer?
    private var current: RecordingDemand?

    public init(fileURL: URL = AppDirectories.recordingDemand, pollInterval: TimeInterval = 2) {
        self.fileURL = fileURL
        self.pollInterval = pollInterval
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.pollTimer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now(), repeating: self.pollInterval, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.poll() }
            self.pollTimer = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.publish(nil)
        }
    }

    /// Ends the request from the Mac and reports the change at once instead of on the next poll.
    public func cancel() throws {
        try RecordingDemand.clear(at: fileURL)
        queue.async { [weak self] in self?.publish(nil) }
    }

    private func poll() {
        let demand = RecordingDemand.read(from: fileURL)
        publish(demand.flatMap { $0.isActive(at: Date()) ? $0 : nil })
    }

    private func publish(_ value: RecordingDemand?) {
        guard value != current else { return }
        current = value
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }

    deinit {
        pollTimer?.cancel()
    }
}
