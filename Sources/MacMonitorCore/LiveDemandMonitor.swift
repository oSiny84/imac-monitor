import Foundation

/// Decides whether a viewer is present from the lease file the HTTPS gateway keeps renewing.
///
/// Only a change in the file's content counts, timed on a monotonic clock. A file left over
/// from an earlier run therefore never turns the camera on, and a wall-clock change can neither
/// keep the camera on nor turn it off.
struct LiveDemandLease {
    let duration: TimeInterval
    private var observed = false
    private var lastContent: Data?
    private var renewedAt: TimeInterval?

    init(duration: TimeInterval) {
        self.duration = duration
    }

    mutating func observe(content: Data?, at uptime: TimeInterval) -> Bool {
        if let content {
            if observed, content != lastContent { renewedAt = uptime }
            lastContent = content
        }
        observed = true
        guard let renewedAt else { return false }
        return uptime - renewedAt < duration
    }
}

/// Polls the lease so the app can start the camera shortly after a viewer asks and stop it soon
/// after they leave. The gateway runs as a separate process, so this file is their only channel.
public final class LiveDemandMonitor {
    public var onChange: ((Bool) -> Void)?

    private let fileURL: URL
    private let leaseDuration: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.macmonitor.live-demand")
    private var pollTimer: DispatchSourceTimer?
    private var lease: LiveDemandLease
    private var demanded = false

    public init(
        fileURL: URL = AppDirectories.liveDemand,
        leaseDuration: TimeInterval = 20,
        pollInterval: TimeInterval = 1
    ) {
        self.fileURL = fileURL
        self.leaseDuration = leaseDuration
        self.pollInterval = pollInterval
        lease = LiveDemandLease(duration: leaseDuration)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.pollTimer == nil else { return }
            self.lease = LiveDemandLease(duration: self.leaseDuration)
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
            self.publish(false)
        }
    }

    private func poll() {
        let content = try? Data(contentsOf: fileURL)
        publish(lease.observe(content: content, at: ProcessInfo.processInfo.systemUptime))
    }

    private func publish(_ value: Bool) {
        guard value != demanded else { return }
        demanded = value
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }

    deinit {
        pollTimer?.cancel()
    }
}
