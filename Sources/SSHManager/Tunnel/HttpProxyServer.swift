import Foundation
import Network
import Darwin

/// CONNECT-only HTTP proxy. Accepts plain HTTP `CONNECT host:port HTTP/1.1`
/// requests, performs a SOCKS5 no-auth handshake to a local SOCKS5 listener
/// at `127.0.0.1:socksPort`, replies `200 Connection Established`, then
/// splices bytes in both directions until either side closes.
///
/// Byte counting is intentionally absent — the downstream SOCKS `ProxyServer`
/// already counts every byte that flows through. Adding counters here would
/// double-count for HTTP clients.
final class HttpProxyServer {
    let listenPort: Int
    let socksPort: Int

    /// Called if the NWListener fails (port already bound at start, or fails
    /// mid-run). The engine treats this like an ssh-death event.
    var onListenerFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "ssh-manager.http-proxy", qos: .userInitiated)
    private var listener: NWListener?

    init(listenPort: Int, socksPort: Int) {
        self.listenPort = listenPort
        self.socksPort = socksPort
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let raw = UInt16(exactly: listenPort), raw > 0,
              let port = NWEndpoint.Port(rawValue: raw) else {
            throw HttpProxyError.invalidPort(listenPort)
        }
        // Только loopback: HTTP-прокси не должен быть открыт в локальную сеть.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] client in
            self?.accept(client: client)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onListenerFailure?(error)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Per-connection flow

    private func accept(client: NWConnection) {
        client.start(queue: queue)
        readHttpRequest(client: client, accumulated: Data())
    }

    private static let maxRequestBytes = 8 * 1024

    /// Read until we see `\r\n\r\n` or hit the cap. Then parse + dispatch.
    private func readHttpRequest(client: NWConnection, accumulated: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let err = error {
                self.writeAndClose(client, response: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", logReason: "client receive error: \(err)")
                return
            }
            var buf = accumulated
            if let data, !data.isEmpty { buf.append(data) }

            if let endRange = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: 0..<endRange.lowerBound)
                self.handleRequest(client: client, headerData: headerData)
                return
            }

            if buf.count >= HttpProxyServer.maxRequestBytes {
                self.writeAndClose(client, response: "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n", logReason: "headers exceeded \(HttpProxyServer.maxRequestBytes) bytes")
                return
            }

            if isComplete {
                // Client closed before sending complete headers.
                client.cancel()
                return
            }

            self.readHttpRequest(client: client, accumulated: buf)
        }
    }

    /// Parse the request line. Only `CONNECT host:port HTTP/1.x` is accepted.
    private func handleRequest(client: NWConnection, headerData: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            writeAndClose(client, response: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", logReason: "non-utf8 headers")
            return
        }

        // First line up to the first CRLF (or whole string if none — unlikely
        // because readHttpRequest already saw \r\n\r\n).
        let firstLine = headerString.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? headerString
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)

        guard parts.count == 3 else {
            writeAndClose(client, response: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", logReason: "malformed request line: \(firstLine)")
            return
        }

        let method = parts[0].uppercased()
        let target = parts[1]

        guard method == "CONNECT" else {
            writeAndClose(client, response: "HTTP/1.1 405 Method Not Allowed\r\nAllow: CONNECT\r\nContent-Length: 0\r\n\r\n", logReason: "non-CONNECT method: \(method)")
            return
        }

        guard let (host, port) = parseHostPort(target) else {
            writeAndClose(client, response: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", logReason: "bad CONNECT target: \(target)")
            return
        }

        connectViaSocks(client: client, targetHost: host, targetPort: port)
    }

    /// Parse `host:port`. Host may be IPv4, IPv6 in brackets, or domain.
    private func parseHostPort(_ s: String) -> (host: String, port: UInt16)? {
        // IPv6 literal: [::1]:443
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"),
                  let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        // host:port — split on LAST colon to be tolerant of accidental colons.
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        guard !host.isEmpty,
              let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        return (host, port)
    }

    // MARK: - SOCKS5 client

    /// Open a TCP connection to the local SOCKS5 listener, perform the no-auth
    /// handshake + CONNECT command, then on success reply 200 to the HTTP
    /// client and splice bytes.
    private func connectViaSocks(client: NWConnection, targetHost: String, targetPort: UInt16) {
        let socks = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: UInt16(socksPort))!,
            using: .tcp
        )

        // Both sides cancel together — if either drops, the receive loops unblock.
        client.stateUpdateHandler = { [weak socks] state in
            if case .failed = state { socks?.cancel() }
            if case .cancelled = state { socks?.cancel() }
        }
        socks.stateUpdateHandler = { [weak self, weak client, weak socks] state in
            guard let self, let socks else { return }
            switch state {
            case .ready:
                self.socksHandshake(client: client, socks: socks, targetHost: targetHost, targetPort: targetPort)
            case .failed:
                client?.cancel()
            case .cancelled:
                client?.cancel()
            default:
                break
            }
        }
        socks.start(queue: queue)
    }

    /// Step 1 of SOCKS5: send greeting (VER=05, NMETHODS=01, METHOD=00 no-auth),
    /// expect 2-byte reply `05 00`.
    private func socksHandshake(client: NWConnection?, socks: NWConnection, targetHost: String, targetPort: UInt16) {
        let greeting = Data([0x05, 0x01, 0x00])
        socks.send(content: greeting, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let _ = error {
                self.bail(client: client, socks: socks, reason:"socks send greeting failed")
                return
            }
            socks.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, err in
                guard let self else { return }
                guard err == nil, let d = data, d.count == 2, d[0] == 0x05, d[1] == 0x00 else {
                    self.bail(client: client, socks: socks, reason:"socks greeting rejected")
                    return
                }
                self.socksConnect(client: client, socks: socks, targetHost: targetHost, targetPort: targetPort)
            }
        })
    }

    /// Step 2 of SOCKS5: send CONNECT command with the requested host:port.
    private func socksConnect(client: NWConnection?, socks: NWConnection, targetHost: String, targetPort: UInt16) {
        var req = Data([0x05, 0x01, 0x00])  // VER, CMD=CONNECT, RSV
        req.append(socksAddress(targetHost))
        var pBig = targetPort.bigEndian
        withUnsafeBytes(of: &pBig) { req.append(contentsOf: $0) }

        socks.send(content: req, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let _ = error {
                self.bail(client: client, socks: socks, reason:"socks send connect failed")
                return
            }
            // Read first 4 bytes: VER, REP, RSV, ATYP. Then drain BND.ADDR + BND.PORT.
            socks.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, err in
                guard let self else { return }
                guard err == nil, let h = head, h.count == 4, h[0] == 0x05 else {
                    self.bail(client: client, socks: socks, reason:"socks connect reply malformed")
                    return
                }
                guard h[1] == 0x00 else {
                    self.bail(client: client, socks: socks, reason:"socks connect rejected (rep=\(h[1]))")
                    return
                }
                let atyp = h[3]
                let addrLen: Int
                switch atyp {
                case 0x01: addrLen = 4 + 2          // IPv4 + port
                case 0x03:
                    // Need the length byte first.
                    socks.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] lenData, _, _, err in
                        guard let self else { return }
                        guard err == nil, let l = lenData, l.count == 1 else {
                            self.bail(client: client, socks: socks, reason:"socks reply atyp=domain length read failed")
                            return
                        }
                        let total = Int(l[0]) + 2
                        socks.receive(minimumIncompleteLength: total, maximumLength: total) { [weak self] _, _, _, err in
                            guard let self else { return }
                            if err != nil {
                                self.bail(client: client, socks: socks, reason:"socks reply domain drain failed")
                                return
                            }
                            self.completeHandshakeAndSplice(client: client, socks: socks)
                        }
                    }
                    return
                case 0x04: addrLen = 16 + 2         // IPv6 + port
                default:
                    self.bail(client: client, socks: socks, reason:"socks reply unknown atyp=\(atyp)")
                    return
                }
                socks.receive(minimumIncompleteLength: addrLen, maximumLength: addrLen) { [weak self] _, _, _, err in
                    guard let self else { return }
                    if err != nil {
                        self.bail(client: client, socks: socks, reason:"socks reply addr drain failed")
                        return
                    }
                    self.completeHandshakeAndSplice(client: client, socks: socks)
                }
            }
        })
    }

    private func completeHandshakeAndSplice(client: NWConnection?, socks: NWConnection) {
        guard let client else { socks.cancel(); return }
        let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
        client.send(content: Data(ok.utf8), completion: .contentProcessed { [weak self] err in
            guard let self, err == nil else {
                client.cancel(); socks.cancel(); return
            }
            self.splice(a: client, b: socks)
            self.splice(a: socks, b: client)
        })
    }

    /// Build SOCKS5 address field for IPv4 / IPv6 / domain.
    private func socksAddress(_ host: String) -> Data {
        // Try IPv4
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            var d = Data([0x01])
            withUnsafeBytes(of: &v4) { d.append(contentsOf: $0) }
            return d
        }
        // Try IPv6
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            var d = Data([0x04])
            withUnsafeBytes(of: &v6) { d.append(contentsOf: $0) }
            return d
        }
        // Domain
        let bytes = Array(host.utf8.prefix(255))
        var d = Data([0x03, UInt8(bytes.count)])
        d.append(contentsOf: bytes)
        return d
    }

    // MARK: - Splice + helpers

    /// Recursive read-and-forward, mirroring ProxyServer.pump.
    private func splice(a: NWConnection, b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete {
                b.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            if error != nil {
                a.cancel(); b.cancel(); return
            }
            self?.splice(a: a, b: b)
        }
    }

    /// Send a short HTTP error response then close. `reason` is logged via NSLog.
    private func writeAndClose(_ client: NWConnection, response: String, logReason: String) {
        NSLog("SSHManager HttpProxy: \(logReason)")
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    /// Bail out mid-handshake: write an HTTP status to the client and tear down.
    private func bail(client: NWConnection?, socks: NWConnection, reason: String) {
        NSLog("SSHManager HttpProxy: \(reason)")
        if let client {
            let body = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
            client.send(content: Data(body.utf8), completion: .contentProcessed { _ in
                client.cancel()
            })
        }
        socks.cancel()
    }
}

enum HttpProxyError: LocalizedError {
    case invalidPort(Int)
    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "Invalid HTTP proxy port: \(p)"
        }
    }
}
