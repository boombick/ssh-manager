import Foundation
import Network

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

    /// Called from the proxy queue whenever bytes are copied.
    /// `deltaProxyToTarget` = bytes received from the accepted client and forwarded to the target.
    /// `deltaTargetToProxy` = bytes received from the target and forwarded back to the client.
    /// Interpretation as "upload" / "download" is the caller's responsibility (depends on tunnel type).
    var onBytes: ((_ deltaProxyToTarget: Int, _ deltaTargetToProxy: Int) -> Void)?

    /// Called when the listener fails (e.g. port already in use, or unexpected failure mid-run).
    var onListenerFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "ssh-manager.proxy", qos: .userInitiated)
    private var listener: NWListener?

    init(listenPort: Int, targetHost: String, targetPort: Int) {
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
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
            switch state {
            case .failed(let error):
                self?.onListenerFailure?(error)
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

    // MARK: - Private

    private func accept(client: NWConnection) {
        guard let raw = UInt16(exactly: targetPort), raw > 0,
              let targetNWPort = NWEndpoint.Port(rawValue: raw) else {
            client.cancel()
            return
        }
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
        pump(from: client, to: target, direction: .proxyToTarget, pair: pair)
        pump(from: target, to: client, direction: .targetToProxy, pair: pair)
    }

    private enum Direction {
        case proxyToTarget
        case targetToProxy
    }

    /// Tracks how many of the two pump directions for a connection-pair have
    /// finished. Only touched on the proxy `queue`, so no locking is needed.
    private final class PumpPair { var finished = 0 }

    /// Recursive read-then-forward loop. Each `receive` callback is dispatched on the proxy queue,
    /// so recursion does not grow the call stack.
    private func pump(from src: NWConnection, to dst: NWConnection, direction: Direction, pair: PumpPair) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                switch direction {
                case .proxyToTarget:
                    self?.onBytes?(data.count, 0)
                case .targetToProxy:
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
                }
                return
            }

            if error != nil {
                src.cancel()
                dst.cancel()
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
