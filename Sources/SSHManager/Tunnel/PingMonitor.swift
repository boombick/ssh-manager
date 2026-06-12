import Foundation
import Network

struct PingResult: Equatable {
    /// nil means the probe didn't complete (DNS failure, refused, timed out).
    let rttMs: Double?
}

struct PingTarget: Hashable {
    let id: UUID
    let host: String
    let port: Int
}

/// Periodically TCP-handshakes each target's `host:port` and publishes the round-trip time.
///
/// Why TCP and not ICMP: many bastion hosts (cloud, corporate firewalls) drop ICMP but
/// happily accept SSH. A TCP probe to the SSH port reflects what actually matters —
/// the latency to the port we want to tunnel through — and doesn't need any privilege.
final class PingMonitor: ObservableObject {
    @Published private(set) var results: [UUID: PingResult] = [:]

    private var targets: [PingTarget] = []
    private var inflight: Set<UUID> = []
    private var timer: Timer?

    private let queue = DispatchQueue(label: "ssh-manager.ping", qos: .utility)
    private let interval: TimeInterval = 10
    private let timeout: TimeInterval = 3

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Kick off an initial round immediately so the UI fills in quickly.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setTargets(_ new: [PingTarget]) {
        targets = new
        // Drop results for removed targets so the UI doesn't show stale rows.
        let alive = Set(new.map { $0.id })
        for id in results.keys where !alive.contains(id) {
            results.removeValue(forKey: id)
        }
    }

    // MARK: - Private

    private func tick() {
        for target in targets {
            guard !inflight.contains(target.id) else { continue }
            probe(target)
        }
    }

    private func probe(_ target: PingTarget) {
        let id = target.id
        inflight.insert(id)

        guard let port = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
            inflight.remove(id)
            results[id] = PingResult(rttMs: nil)
            return
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: port,
            using: .tcp
        )
        let start = DispatchTime.now()

        // Captured by reference; access only on `queue`, so no lock needed.
        var finished = false

        // Single-shot. `finalize` runs on `queue`.
        let finalize: (Double?) -> Void = { [weak self] rtt in
            if finished { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async {
                self?.inflight.remove(id)
                self?.results[id] = PingResult(rttMs: rtt)
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                finalize(Double(ns) / 1_000_000)
            case .failed, .cancelled:
                finalize(nil)
            default:
                break
            }
        }

        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finalize(nil)
        }
    }
}
