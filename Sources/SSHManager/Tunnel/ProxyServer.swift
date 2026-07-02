import Foundation
import Network

/// Point-in-time health snapshot of a ProxyServer, cheap enough to keep
/// always-on. Answers "did the user's traffic ever reach us at all" — the
/// first question when byte counters read zero.
struct ProxyDiagnostics: Equatable {
    var listenerState: String = "not started"
    var acceptedTotal: UInt64 = 0
    var activePairs: Int = 0
    var onBytesCalls: UInt64 = 0
}

/// A tiny in-process TCP proxy: accepts on `listenPort`, dials `targetHost:targetPort`,
/// and shovels bytes in both directions while counting them.
///
/// The TunnelEngine inserts a ProxyServer between the user's client and ssh's own listener
/// (for `-D` / `-L`) or between ssh and the local service (for `-R`). This is the only place
/// that sees plaintext byte volume — ssh itself doesn't tell us how much went through.
final class ProxyServer {
    let listenPort: Int
    let targetHost: String
    let targetPort: Int

    /// Connection this proxy serves; used to route DebugTrace lines. Nil in tests.
    let connectionId: UUID?

    /// Called from the proxy queue whenever bytes are copied.
    /// `deltaProxyToTarget` = bytes received from the accepted client and forwarded to the target.
    /// `deltaTargetToProxy` = bytes received from the target and forwarded back to the client.
    /// Interpretation as "upload" / "download" is the caller's responsibility (depends on tunnel type).
    var onBytes: ((_ deltaProxyToTarget: Int, _ deltaTargetToProxy: Int) -> Void)?

    /// Called when the listener fails (e.g. port already in use, or unexpected failure mid-run).
    var onListenerFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "ssh-manager.proxy", qos: .userInitiated)
    private var listener: NWListener?

    /// Live connection pairs, keyed by their PumpPair identity. Only touched
    /// on the proxy `queue`. Needed so the master port can hard-switch: drop
    /// everything mid-flight instead of letting old flows drain.
    private var livePairs: [ObjectIdentifier: (src: NWConnection, dst: NWConnection)] = [:]

    private let diagLock = NSLock()
    private var diag = ProxyDiagnostics()

    init(listenPort: Int, targetHost: String, targetPort: Int, connectionId: UUID? = nil) {
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.connectionId = connectionId
    }

    /// Thread-safe snapshot of listener state and traffic counters.
    func diagnostics() -> ProxyDiagnostics {
        diagLock.lock(); defer { diagLock.unlock() }
        return diag
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let raw = UInt16(exactly: listenPort), raw > 0,
              let port = NWEndpoint.Port(rawValue: raw) else {
            throw ProxyError.invalidPort(listenPort)
        }
        // Только loopback: иначе SOCKS/форвард открыт всей локальной сети.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] client in
            self?.accept(client: client)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.mutateDiag { $0.listenerState = "\(state)" }
            self.trace("listener state: \(state) (port \(self.listenPort))")
            switch state {
            case .failed(let error):
                self.onListenerFailure?(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Cancel every in-flight connection pair. stop() leaves accepted
    /// connections draining (right for tunnels); the master port calls this
    /// on switch so no traffic keeps flowing to the previous target.
    func cancelActivePairs() {
        queue.async { [self] in
            trace("cancelling \(livePairs.count) active pair(s)")
            for (_, pair) in livePairs {
                pair.src.cancel()
                pair.dst.cancel()
            }
            // reportClosed fires from the pumps' error/cancel paths and
            // clears livePairs / activePairs per pair.
        }
    }

    // MARK: - Private

    private func mutateDiag(_ change: (inout ProxyDiagnostics) -> Void) {
        diagLock.lock()
        change(&diag)
        diagLock.unlock()
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard let connectionId else { return }
        DebugTrace.shared.trace(connectionId, "proxy", message())
    }

    private func accept(client: NWConnection) {
        guard let raw = UInt16(exactly: targetPort), raw > 0,
              let targetNWPort = NWEndpoint.Port(rawValue: raw) else {
            client.cancel()
            return
        }
        mutateDiag { $0.acceptedTotal += 1; $0.activePairs += 1 }
        trace("accepted \(client.endpoint) → \(targetHost):\(targetPort)")

        let target = NWConnection(
            host: NWEndpoint.Host(targetHost),
            port: targetNWPort,
            using: .tcp
        )

        // If either side fails to come up, tear both down so receive() unblocks.
        client.stateUpdateHandler = { [weak target] state in
            if case .failed = state { target?.cancel() }
            if case .cancelled = state { target?.cancel() }
        }
        target.stateUpdateHandler = { [weak client] state in
            if case .failed = state { client?.cancel() }
            if case .cancelled = state { client?.cancel() }
        }

        client.start(queue: queue)
        target.start(queue: queue)

        let pair = PumpPair()
        livePairs[ObjectIdentifier(pair)] = (src: client, dst: target)
        pump(from: client, to: target, direction: .proxyToTarget, pair: pair)
        pump(from: target, to: client, direction: .targetToProxy, pair: pair)
    }

    private enum Direction {
        case proxyToTarget
        case targetToProxy
    }

    /// Tracks how many of the two pump directions for a connection-pair have
    /// finished, plus per-pair byte totals for tracing. Only touched on the
    /// proxy `queue`, so no locking is needed.
    private final class PumpPair {
        var finished = 0
        var closedReported = false
        var bytesProxyToTarget: UInt64 = 0
        var bytesTargetToProxy: UInt64 = 0
    }

    /// Mark the pair closed exactly once (both directions done, or an error path).
    /// Runs on the proxy queue (from pump callbacks), so livePairs is safe to touch.
    private func reportClosed(_ pair: PumpPair, reason: String) {
        guard !pair.closedReported else { return }
        pair.closedReported = true
        livePairs.removeValue(forKey: ObjectIdentifier(pair))
        mutateDiag { $0.activePairs -= 1 }
        trace("pair closed (\(reason)): →target \(pair.bytesProxyToTarget) B, target→ \(pair.bytesTargetToProxy) B")
    }

    /// Recursive read-then-forward loop. Each `receive` callback is dispatched on the proxy queue,
    /// so recursion does not grow the call stack.
    private func pump(from src: NWConnection, to dst: NWConnection, direction: Direction, pair: PumpPair) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.mutateDiag { $0.onBytesCalls += 1 }
                switch direction {
                case .proxyToTarget:
                    pair.bytesProxyToTarget += UInt64(data.count)
                    self?.trace("chunk →target \(data.count) B")
                    self?.onBytes?(data.count, 0)
                case .targetToProxy:
                    pair.bytesTargetToProxy += UInt64(data.count)
                    self?.trace("chunk target→ \(data.count) B")
                    self?.onBytes?(0, data.count)
                }
                dst.send(content: data, completion: .contentProcessed { _ in })
            }

            if isComplete {
                // The peer closed write side. Half-close the corresponding write on dst.
                dst.send(content: nil,
                         contentContext: .finalMessage,
                         isComplete: true,
                         completion: .contentProcessed { _ in })
                pair.finished += 1
                if pair.finished == 2 {
                    src.cancel()
                    dst.cancel()
                    self?.reportClosed(pair, reason: "both directions complete")
                }
                return
            }

            if error != nil {
                src.cancel()
                dst.cancel()
                self?.reportClosed(pair, reason: "error: \(error!)")
                return
            }

            self?.pump(from: src, to: dst, direction: direction, pair: pair)
        }
    }
}

enum ProxyError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "Invalid port: \(p)"
        }
    }
}
