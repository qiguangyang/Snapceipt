import Foundation
import Network
import Observation

/// Observes the device's network path and publishes a single `isOnline` flag.
/// `NWPathMonitor` delivers updates on a background queue; we marshal each change
/// onto the MainActor so SwiftUI/`@Observable` consumers (OfflineBanner, SyncEngine)
/// observe it on the main thread.
@Observable
@MainActor
final class Reachability {
    /// True when the current path is `.satisfied`. Optimistically true until the
    /// first path update arrives, so first-launch sync is attempted.
    private(set) var isOnline: Bool = true

    @ObservationIgnored private let monitor: NWPathMonitor
    @ObservationIgnored private let queue = DispatchQueue(label: "sc.reachability")
    @ObservationIgnored private var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        start()
    }

    /// Begin monitoring. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring (e.g. on teardown).
    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
