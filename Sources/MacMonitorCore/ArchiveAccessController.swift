import Foundation

protocol ArchiveGatewayControlling: AnyObject {
    var failureHandler: ((Error) -> Void)? { get set }
    func startIfConfigured() throws -> Bool
    func stop()
}

public enum ArchiveAccessState: Equatable {
    case stopped
    case notConfigured
    case starting
    case running
    case failed(String)
}

/// Owns HTTPS access for the authenticated app session, independently of capture.
/// All process operations and retries run on one queue, never the UI thread.
public final class ArchiveAccessController {
    public var onStateChange: ((ArchiveAccessState) -> Void)?

    private let gateway: ArchiveGatewayControlling
    private let configurationProvider: () throws -> Data?
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.macmonitor.archive-access")
    private var timer: DispatchSourceTimer?
    private var enabled = false
    private var running = false
    private var generation: UInt64 = 0
    private var activeConfiguration: Data?
    private var state: ArchiveAccessState = .stopped

    public convenience init() {
        self.init(gateway: GatewaySupervisor(), pollInterval: 10) {
            guard FileManager.default.fileExists(atPath: AppDirectories.gatewayConfiguration.path) else { return nil }
            return try Data(contentsOf: AppDirectories.gatewayConfiguration)
        }
    }

    init(gateway: ArchiveGatewayControlling, pollInterval: TimeInterval,
         configurationProvider: @escaping () throws -> Data?) {
        self.gateway = gateway
        self.pollInterval = pollInterval
        self.configurationProvider = configurationProvider
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.enabled = true
            if self.timer == nil, self.pollInterval > 0 {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
                timer.setEventHandler { [weak self] in self?.reconcile() }
                self.timer = timer
                timer.resume()
            }
            self.reconcile()
        }
    }

    /// Detect first-time setup or an atomically replaced gateway.json without
    /// restarting an unchanged gateway (and invalidating its browser sessions).
    public func refresh() {
        queue.async { [weak self] in self?.reconcile() }
    }

    public func restart() {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            self.stopGateway()
            self.reconcile()
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            if let self {
                self.enabled = false
                self.timer?.cancel()
                self.timer = nil
                self.stopGateway()
                self.publish(.stopped)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func reconcile() {
        guard enabled else { return }
        do {
            guard let configuration = try configurationProvider() else {
                if running || activeConfiguration != nil { stopGateway() }
                publish(.notConfigured)
                return
            }
            if running, activeConfiguration == configuration { return }
            stopGateway()
            publish(.starting)
            let expectedGeneration = generation
            gateway.failureHandler = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, self.enabled, self.generation == expectedGeneration else { return }
                    self.stopGateway()
                    self.publish(.failed(error.localizedDescription))
                }
            }
            if try gateway.startIfConfigured() {
                activeConfiguration = configuration
                running = true
                publish(.running)
            } else {
                stopGateway()
                publish(.notConfigured)
            }
        } catch {
            stopGateway()
            publish(.failed(error.localizedDescription))
        }
    }

    private func stopGateway() {
        generation &+= 1
        gateway.failureHandler = nil
        gateway.stop()
        running = false
        activeConfiguration = nil
    }

    private func publish(_ next: ArchiveAccessState) {
        guard next != state else { return }
        state = next
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(next) }
    }

    deinit {
        timer?.cancel()
        gateway.failureHandler = nil
        gateway.stop()
    }
}
