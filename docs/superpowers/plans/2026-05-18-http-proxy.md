# HTTP Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional CONNECT-only HTTP proxy to each `.dynamic` SSH tunnel, forwarding through the existing local SOCKS5 listener.

**Architecture:** A new `HttpProxyServer` component (~150 lines, `NWListener` + a tiny SOCKS5 client) sits in front of the existing `ProxyServer`. `TunnelEngine` brings it up after ssh is running, only for `.dynamic` connections with `httpProxyEnabled`. Per-connection settings (`httpProxyEnabled: Bool`, `httpProxyPort: Int?`) persist in `config.json` with a backward-compatible custom decoder. The actually-bound port (relevant when the user chose auto-allocation) is published via the supervisor and rendered in the connection-row subtitle.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Network framework (`NWListener`, `NWConnection`), no external dependencies. Target macOS 13+.

## Project conventions

- **Working directory:** `/Users/andreysinitsyn/work/ssh-manager`
- **Not a git repo.** Do not run `git add` / `git commit`. Each task's checkpoint is `swift build` succeeding.
- **No test target.** TDD-style test files are not used. Verification = `swift build` clean + read updated code + final manual smoke test.
- **Build commands:**
  - `swift build` — incremental SwiftPM build (fast, for checkpoint use)
  - `./scripts/build-app.sh` — produces `SSHManager.app` at project root
  - `./scripts/build-pkg.sh` — produces `SSHManager-<version>.pkg`
- **The app is a menu-bar agent (`LSUIElement=true`).** No Dock icon.
- **Existing files you'll be reading or editing:**
  - `Sources/SSHManager/Models/Connection.swift`
  - `Sources/SSHManager/Tunnel/ProxyServer.swift` (reference for style)
  - `Sources/SSHManager/Tunnel/TunnelEngine.swift`
  - `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`
  - `Sources/SSHManager/UI/ConnectionEditView.swift`
  - `Sources/SSHManager/UI/ConnectionListView.swift`
  - `Resources/Info.plist`

## File map

**Create:**
- `Sources/SSHManager/Tunnel/HttpProxyServer.swift` — CONNECT-only HTTP proxy that pipes to a local SOCKS5 listener. ~180 lines.

**Modify:**
- `Sources/SSHManager/Models/Connection.swift` — two new fields + custom `init(from:)`.
- `Sources/SSHManager/Tunnel/TunnelEngine.swift` — bring-up / tear-down hooks; `bringUpHttpProxy`, `handleHttpProxyFailure`; exposed `actualHttpProxyPort`.
- `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` — `@Published var httpPorts: [UUID: Int]`, updated in `pollStats()`.
- `Sources/SSHManager/UI/ConnectionEditView.swift` — toggle + optional port field + validation.
- `Sources/SSHManager/UI/ConnectionListView.swift` — subtitle rendering of HTTP port; new prop on `ConnectionRow`.
- `Resources/Info.plist` — `CFBundleShortVersionString` → `0.4.0`.

---

### Task 1: Extend `Connection` model with HTTP proxy fields

**Files:**
- Modify: `Sources/SSHManager/Models/Connection.swift`

- [ ] **Step 1: Read the current model**

Read `Sources/SSHManager/Models/Connection.swift` fully. Confirm it's a `struct Connection: Codable, Identifiable, Equatable` with synthesized `Codable`, no custom `init(from:)`, no custom `CodingKeys`.

- [ ] **Step 2: Add the two stored properties**

Inside `struct Connection`, after `var extraOptions: [String]` (the last stored property), add:

```swift
    /// When true and `type == .dynamic`, a CONNECT-only HTTP proxy is brought
    /// up alongside the SOCKS listener. No-op for `.local` / `.remote`.
    var httpProxyEnabled: Bool
    /// Explicit HTTP proxy port. When nil and `httpProxyEnabled`, the engine
    /// scans for a free port starting at `listenPort + 1`.
    var httpProxyPort: Int?
```

- [ ] **Step 3: Extend the designated initializer**

The current init signature ends with `extraOptions: [String] = []`. Add the two new parameters with defaults so all existing call sites keep working unchanged:

Current parameter block:

```swift
    init(
        id: UUID = UUID(),
        name: String,
        type: TunnelType,
        host: String,
        sshPort: Int = 22,
        user: String,
        identityFile: String? = nil,
        listenPort: Int,
        remoteHost: String? = nil,
        remotePort: Int? = nil,
        autoReconnect: Bool = true,
        autoStart: Bool = false,
        extraOptions: [String] = []
    ) {
```

Replace with:

```swift
    init(
        id: UUID = UUID(),
        name: String,
        type: TunnelType,
        host: String,
        sshPort: Int = 22,
        user: String,
        identityFile: String? = nil,
        listenPort: Int,
        remoteHost: String? = nil,
        remotePort: Int? = nil,
        autoReconnect: Bool = true,
        autoStart: Bool = false,
        extraOptions: [String] = [],
        httpProxyEnabled: Bool = false,
        httpProxyPort: Int? = nil
    ) {
```

Inside the body, after `self.extraOptions = extraOptions`, add:

```swift
        self.httpProxyEnabled = httpProxyEnabled
        self.httpProxyPort = httpProxyPort
```

- [ ] **Step 4: Update `blank()` template**

The current `Connection.blank()` doesn't pass the new args, so it relies on the defaults — which is what we want. Leave it as-is. (Confirm by reading: `blank()` passes named args up through `extraOptions: []` and does NOT need updating.)

- [ ] **Step 5: Add a backward-compatible custom `init(from:)`**

Old `config.json` files (written before this change) don't have the two new keys. Synthesized `Codable` would treat them as required and fail. Add a custom decoder.

Add this code inside `struct Connection`, immediately after the designated initializer's closing brace and before the closing `}` of the struct:

```swift
    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case host, sshPort, user, identityFile
        case listenPort, remoteHost, remotePort
        case autoReconnect, autoStart
        case extraOptions
        case httpProxyEnabled, httpProxyPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,       forKey: .id)
        self.name            = try c.decode(String.self,     forKey: .name)
        self.type            = try c.decode(TunnelType.self, forKey: .type)
        self.host            = try c.decode(String.self,     forKey: .host)
        self.sshPort         = try c.decode(Int.self,        forKey: .sshPort)
        self.user            = try c.decode(String.self,     forKey: .user)
        self.identityFile    = try c.decodeIfPresent(String.self, forKey: .identityFile)
        self.listenPort      = try c.decode(Int.self,        forKey: .listenPort)
        self.remoteHost      = try c.decodeIfPresent(String.self, forKey: .remoteHost)
        self.remotePort      = try c.decodeIfPresent(Int.self,    forKey: .remotePort)
        self.autoReconnect   = try c.decode(Bool.self,       forKey: .autoReconnect)
        self.autoStart       = try c.decode(Bool.self,       forKey: .autoStart)
        self.extraOptions    = try c.decode([String].self,   forKey: .extraOptions)
        // New in 0.4.0 — default for old configs.
        self.httpProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .httpProxyEnabled) ?? false
        self.httpProxyPort    = try c.decodeIfPresent(Int.self,  forKey: .httpProxyPort)
    }
```

The encoder stays synthesized. New configs will write the two new keys automatically; old configs missing them decode with `false` / `nil`.

- [ ] **Step 6: Build to verify**

Run: `swift build`
Expected: clean build. No warnings related to `Connection`.

If you see errors about missing initializer arguments at call sites (e.g. `ConnectionEditView.commit()` or `Connection.blank()`), the default values weren't picked up — re-check Step 3.

- [ ] **Step 7: Verify backward-compat decoder by visual inspection**

Re-read the file and confirm:
- Both new properties declared.
- Designated init accepts both with defaults.
- `CodingKeys` enum lists both new cases.
- `init(from:)` uses `decodeIfPresent` for both new fields with sensible defaults.
- Existing fields (`identityFile`, `remoteHost`, `remotePort`) are also `decodeIfPresent` (they're `Optional<T>` in the model so this is correct).

---

### Task 2: New `HttpProxyServer` component

**Files:**
- Create: `Sources/SSHManager/Tunnel/HttpProxyServer.swift`

- [ ] **Step 1: Read `ProxyServer.swift` for style reference**

Read `Sources/SSHManager/Tunnel/ProxyServer.swift` end-to-end. Note the patterns:
- `NWListener` on a dedicated serial dispatch queue.
- `start()` throws `ProxyError.invalidPort` if the port doesn't fit `UInt16`.
- `stop()` cancels the listener.
- `accept(client:)` opens a target connection, wires symmetric `stateUpdateHandler`s, then calls `pump` in both directions.
- `pump` is the recursive read-and-forward loop using `receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024)`.

Your `HttpProxyServer` follows the same shape but:
1. Targets `127.0.0.1:<socksPort>` always.
2. Before splicing bytes, it must (a) read+parse the HTTP `CONNECT` request from the client, (b) perform a SOCKS5 handshake to the target, (c) send the 200 response to the client.
3. No `onBytes` callback — byte counting happens in the downstream `ProxyServer` (which sees this proxy as just another client).

- [ ] **Step 2: Create the file with the listener / lifecycle scaffolding**

Write the following to `Sources/SSHManager/Tunnel/HttpProxyServer.swift`:

```swift
import Foundation
import Network

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

        guard let port = NWEndpoint.Port(rawValue: UInt16(listenPort)) else {
            throw HttpProxyError.invalidPort(listenPort)
        }

        let listener = try NWListener(using: params, on: port)
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
}

enum HttpProxyError: LocalizedError {
    case invalidPort(Int)
    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "Invalid HTTP proxy port: \(p)"
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build. Listener scaffolding only; nothing calls it yet.

- [ ] **Step 4: Add the `accept` flow and HTTP-request reader**

Append the following to `HttpProxyServer.swift` (inside the class, after the `stop()` method). It adds the accept handler and a buffered HTTP request reader that finds `\r\n\r\n` or hits the 8 KiB cap.

```swift
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
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: clean build. Compiler will warn about unused functions until Step 6 is added, but it should not error. (Swift doesn't typically warn on private unused methods.)

- [ ] **Step 6: Add request parsing and dispatch**

Append the following to the class:

```swift
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
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: clean build. `connectViaSocks` is not yet defined — but the call site only resolves at runtime, the compiler will error. If it errors with "cannot find connectViaSocks in scope", proceed to Step 8.

If Swift errors out on the `connectViaSocks` reference, that's expected — go straight to Step 8 and rebuild after.

- [ ] **Step 8: Add the SOCKS5 client flow**

Append to the class:

```swift
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
        socks.stateUpdateHandler = { [weak self, weak client] state in
            guard let self else { return }
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
                self.bail(client: client, socks: socks, code: 502, reason: "socks send greeting failed")
                return
            }
            socks.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, err in
                guard let self else { return }
                guard err == nil, let d = data, d.count == 2, d[0] == 0x05, d[1] == 0x00 else {
                    self.bail(client: client, socks: socks, code: 502, reason: "socks greeting rejected")
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
                self.bail(client: client, socks: socks, code: 502, reason: "socks send connect failed")
                return
            }
            // Read first 4 bytes: VER, REP, RSV, ATYP. Then drain BND.ADDR + BND.PORT.
            socks.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, err in
                guard let self else { return }
                guard err == nil, let h = head, h.count == 4, h[0] == 0x05 else {
                    self.bail(client: client, socks: socks, code: 502, reason: "socks connect reply malformed")
                    return
                }
                guard h[1] == 0x00 else {
                    self.bail(client: client, socks: socks, code: 502, reason: "socks connect rejected (rep=\(h[1]))")
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
                            self.bail(client: client, socks: socks, code: 502, reason: "socks reply atyp=domain length read failed")
                            return
                        }
                        let total = Int(l[0]) + 2
                        socks.receive(minimumIncompleteLength: total, maximumLength: total) { [weak self] _, _, _, err in
                            guard let self else { return }
                            if err != nil {
                                self.bail(client: client, socks: socks, code: 502, reason: "socks reply domain drain failed")
                                return
                            }
                            self.completeHandshakeAndSplice(client: client, socks: socks)
                        }
                    }
                    return
                case 0x04: addrLen = 16 + 2         // IPv6 + port
                default:
                    self.bail(client: client, socks: socks, code: 502, reason: "socks reply unknown atyp=\(atyp)")
                    return
                }
                socks.receive(minimumIncompleteLength: addrLen, maximumLength: addrLen) { [weak self] _, _, _, err in
                    guard let self else { return }
                    if err != nil {
                        self.bail(client: client, socks: socks, code: 502, reason: "socks reply addr drain failed")
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
```

- [ ] **Step 9: Add the byte-splicing loop and helper close functions**

Append to the class:

```swift
    // MARK: - Splice + helpers

    /// Recursive read-and-forward, mirroring ProxyServer.pump.
    private func splice(a: NWConnection, b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
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
            self.splice(a: a, b: b)
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
    private func bail(client: NWConnection?, socks: NWConnection, code: Int, reason: String) {
        NSLog("SSHManager HttpProxy: \(reason)")
        if let client {
            let body = "HTTP/1.1 \(code) Bad Gateway\r\nContent-Length: 0\r\n\r\n"
            client.send(content: Data(body.utf8), completion: .contentProcessed { _ in
                client.cancel()
            })
        }
        socks.cancel()
    }
```

- [ ] **Step 10: Build**

Run: `swift build`
Expected: clean build. No warnings about unused symbols related to `HttpProxyServer`.

If you see "`inet_pton` was not found": add `import Darwin` at the top of the file. (Usually `Foundation` re-exports it on macOS, but worth knowing.)

If you see "`splice` is not unique" or similar shadowing warnings, rename to `pump(from:to:)` to mirror `ProxyServer`'s naming.

- [ ] **Step 11: Read the entire file end-to-end**

Confirm visually:
- `init(listenPort:socksPort:)`, `start() throws`, `stop()` are public.
- `onListenerFailure` callback declared.
- All other methods are `private`.
- HTTP method validation: anything other than `CONNECT` → `405`.
- Malformed `CONNECT host:port` → `400`.
- SOCKS handshake failure paths → `502`.
- Success path: `200 Connection Established` then splice.
- `inet_pton` is called for IPv4 / IPv6 address-type detection.

---

### Task 3: Wire `HttpProxyServer` into `TunnelEngine`

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelEngine.swift`

- [ ] **Step 1: Re-read `TunnelEngine.swift` end-to-end**

Read the file to refresh context. Note where SOCKS proxy lifecycle happens:
- `proxy: ProxyServer?` field at line ~45.
- `start()` brings up proxy before ssh (line ~100), sets `process = p; state = .running` on success (line ~143).
- `handleTermination` stops proxy (line ~192).
- `handleProxyFailure` stops proxy (line ~223).
- `stop()` indirectly stops proxy via `process?.terminate()` → `handleTermination`.

You'll add a parallel `httpProxy` lifecycle that hooks in at the same points.

- [ ] **Step 2: Add the storage fields**

Find the existing storage block:

```swift
    private var process: Process?
    private var proxy: ProxyServer?
    private var logHandle: FileHandle?
    private var manuallyStopped = false
```

Replace with (adds two fields):

```swift
    private var process: Process?
    private var proxy: ProxyServer?
    private var httpProxy: HttpProxyServer?
    private(set) var actualHttpProxyPort: Int?
    private var logHandle: FileHandle?
    private var manuallyStopped = false
```

`actualHttpProxyPort` is `private(set)` so the supervisor can read it but only the engine can write.

- [ ] **Step 3: Add the `HttpProxyAllocError` type at the bottom of the file**

After the closing `}` of the class (the very last line of the file is currently the class's `}`), append:

```swift

enum HttpProxyAllocError: LocalizedError {
    case noFreePort(startedAt: Int, tried: Int)
    var errorDescription: String? {
        switch self {
        case .noFreePort(let start, let tried):
            return "Could not find a free HTTP proxy port (scanned \(tried) ports starting at \(start))."
        }
    }
}
```

- [ ] **Step 4: Add `bringUpHttpProxy` helper**

In `TunnelEngine`, find the `// MARK: - Reconnect` section. Add a NEW `// MARK: - HTTP proxy` section between `// MARK: - Private` and `// MARK: - Reconnect`. Place the following methods there:

```swift
    // MARK: - HTTP proxy

    /// Bring up an HTTP proxy listener that forwards via the local SOCKS5
    /// listener on `socksPort`. Honors `connection.httpProxyPort` (explicit)
    /// or auto-allocates by scanning upward from `socksPort + 1`.
    /// On success returns the bound port and a running server.
    private func bringUpHttpProxy(socksPort: Int) throws -> (port: Int, server: HttpProxyServer) {
        if let explicit = connection.httpProxyPort {
            let server = HttpProxyServer(listenPort: explicit, socksPort: socksPort)
            server.onListenerFailure = { [weak self] err in
                DispatchQueue.main.async { self?.handleHttpProxyFailure(err) }
            }
            try server.start()
            return (explicit, server)
        }
        // Auto: scan from socksPort+1 upward, up to 100 attempts.
        let startAt = socksPort + 1
        let maxAttempts = 100
        var port = startAt
        for attempt in 0..<maxAttempts {
            guard port <= 65535 else { break }
            let server = HttpProxyServer(listenPort: port, socksPort: socksPort)
            do {
                try server.start()
                server.onListenerFailure = { [weak self] err in
                    DispatchQueue.main.async { self?.handleHttpProxyFailure(err) }
                }
                return (port, server)
            } catch {
                _ = attempt
                port += 1
            }
        }
        throw HttpProxyAllocError.noFreePort(startedAt: startAt, tried: maxAttempts)
    }

    private func handleHttpProxyFailure(_ error: Error) {
        writeLog("http proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true
        process?.terminate()
        proxy?.stop(); proxy = nil
        httpProxy?.stop(); httpProxy = nil
        actualHttpProxyPort = nil
        successUptimeTimer?.cancel(); successUptimeTimer = nil
        scheduleRetryOrGiveUp(reason: "HTTP proxy: \(error.localizedDescription)")
    }
```

- [ ] **Step 5: Bring up the HTTP proxy from `start()`**

Find this block in `start()`:

```swift
        do {
            try p.run()
            process = p
            state = .running
            armSuccessUptimeTimer()
        } catch {
            writeLog("failed to launch ssh: \(error.localizedDescription)")
            proxy.stop()
            self.proxy = nil
            let reason = "Failed to launch ssh: \(error.localizedDescription)"
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
        }
    }
```

Replace with:

```swift
        do {
            try p.run()
            process = p
            state = .running
            armSuccessUptimeTimer()
        } catch {
            writeLog("failed to launch ssh: \(error.localizedDescription)")
            proxy.stop()
            self.proxy = nil
            let reason = "Failed to launch ssh: \(error.localizedDescription)"
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
            return
        }

        // Optional HTTP proxy — only for .dynamic with the toggle on.
        if connection.type == .dynamic, connection.httpProxyEnabled {
            do {
                let (port, server) = try bringUpHttpProxy(socksPort: connection.listenPort)
                actualHttpProxyPort = port
                httpProxy = server
                writeLog("http proxy: listen 127.0.0.1:\(port) → SOCKS 127.0.0.1:\(connection.listenPort)")
            } catch {
                writeLog("http proxy bring-up failed: \(error.localizedDescription)")
                let reason = "HTTP proxy: \(error.localizedDescription)"
                // Tear down ssh + SOCKS so we don't leave a half-up tunnel.
                manuallyStopped = true   // suppress termination-handler retry; we retry here ourselves.
                process?.terminate()
                proxy.stop()
                self.proxy = nil
                successUptimeTimer?.cancel(); successUptimeTimer = nil
                state = .running   // about to be overwritten by scheduleRetryOrGiveUp
                closeLog()
                scheduleRetryOrGiveUp(reason: reason)
            }
        }
    }
```

Note: the `return` after `scheduleRetryOrGiveUp(reason: reason)` in the catch is required so we don't fall through to the HTTP proxy block after a failed ssh launch.

- [ ] **Step 6: Tear down the HTTP proxy in `handleTermination`**

Find:

```swift
    private func handleTermination(exitCode: Int32) {
        writeLog("ssh exited with code \(exitCode)")
        proxy?.stop()
        proxy = nil
        process = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil
```

Replace with:

```swift
    private func handleTermination(exitCode: Int32) {
        writeLog("ssh exited with code \(exitCode)")
        proxy?.stop()
        proxy = nil
        httpProxy?.stop()
        httpProxy = nil
        actualHttpProxyPort = nil
        process = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil
```

- [ ] **Step 7: Tear down the HTTP proxy in `handleProxyFailure`**

Find:

```swift
    private func handleProxyFailure(_ error: Error) {
        writeLog("proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true   // suppress "ssh exited" failure message; the proxy failed first
        process?.terminate()
        proxy?.stop()
        proxy = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil
```

Replace with:

```swift
    private func handleProxyFailure(_ error: Error) {
        writeLog("proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true   // suppress "ssh exited" failure message; the proxy failed first
        process?.terminate()
        proxy?.stop()
        proxy = nil
        httpProxy?.stop()
        httpProxy = nil
        actualHttpProxyPort = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil
```

- [ ] **Step 8: Build**

Run: `swift build`
Expected: clean build, no warnings.

If you see "value of type 'TunnelEngine' has no member 'handleHttpProxyFailure'", you put the `// MARK: - HTTP proxy` section in the wrong place — methods must be inside the class. Re-check Step 4.

- [ ] **Step 9: Read the file end-to-end**

Confirm visually:
- `httpProxy` field declared next to `proxy`.
- `actualHttpProxyPort` declared `private(set)`.
- `bringUpHttpProxy` and `handleHttpProxyFailure` exist inside the class.
- `start()` brings up HTTP proxy after `state = .running`, only for `.dynamic` + `httpProxyEnabled`.
- All three tear-down paths (`handleTermination`, `handleProxyFailure`, `handleHttpProxyFailure`) stop both `proxy` and `httpProxy` and clear `actualHttpProxyPort`.
- `HttpProxyAllocError` declared after the class.

---

### Task 4: Publish HTTP ports through `TunnelSupervisor`

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`

- [ ] **Step 1: Add the published property**

Find the existing block:

```swift
    @Published private(set) var connections: [Connection]
    @Published private(set) var stats: [UUID: ByteCounters] = [:]
    @Published private(set) var pings: [UUID: PingResult] = [:]
```

Replace with (add the new map):

```swift
    @Published private(set) var connections: [Connection]
    @Published private(set) var stats: [UUID: ByteCounters] = [:]
    @Published private(set) var pings: [UUID: PingResult] = [:]
    @Published private(set) var httpPorts: [UUID: Int] = [:]
```

- [ ] **Step 2: Update `pollStats` to also publish HTTP ports**

Find:

```swift
    private func pollStats() {
        var fresh: [UUID: ByteCounters] = [:]
        for (id, e) in engines {
            fresh[id] = e.snapshotStats()
        }
        // Avoid SwiftUI churn when nothing changed.
        if fresh != stats {
            stats = fresh
            onChange?()
        }
    }
```

Replace with:

```swift
    private func pollStats() {
        var fresh: [UUID: ByteCounters] = [:]
        var freshHttp: [UUID: Int] = [:]
        for (id, e) in engines {
            fresh[id] = e.snapshotStats()
            if let p = e.actualHttpProxyPort {
                freshHttp[id] = p
            }
        }
        var notify = false
        if fresh != stats {
            stats = fresh
            notify = true
        }
        if freshHttp != httpPorts {
            httpPorts = freshHttp
            notify = true
        }
        if notify { onChange?() }
    }
```

- [ ] **Step 3: Clean up `httpPorts` on connection delete**

Find:

```swift
    func deleteConnection(id: UUID) throws {
        if let e = engines[id] {
            e.stop()
            engines.removeValue(forKey: id)
        }
        connections.removeAll { $0.id == id }
        lastByteSnapshot.removeValue(forKey: id)
        try store.save(connections)
        notifyChanged()
    }
```

Add one line:

```swift
    func deleteConnection(id: UUID) throws {
        if let e = engines[id] {
            e.stop()
            engines.removeValue(forKey: id)
        }
        connections.removeAll { $0.id == id }
        lastByteSnapshot.removeValue(forKey: id)
        httpPorts.removeValue(forKey: id)
        try store.save(connections)
        notifyChanged()
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 5: Re-read to confirm**

The supervisor now exposes `httpPorts: [UUID: Int]`, populated on every 0.5 s poll tick by reading each engine's `actualHttpProxyPort`. The `pollStats` `notify` flag fires `onChange` if either map changed.

---

### Task 5: Add toggle + port field to `ConnectionEditView`

**Files:**
- Modify: `Sources/SSHManager/UI/ConnectionEditView.swift`

- [ ] **Step 1: Re-read the file**

Read the file. Note:
- Local string-backed `@State`s (`identityText`, `remoteHostText`, `remotePortText`, `extraOptionsText`) shadow optional/numeric fields.
- The forwarding section uses `if draft.type != .dynamic { ... }` for the L/R-only fields.
- `validationError` walks every constraint; `Save` button is disabled while non-nil.
- `commit()` clears L/R fields when type is `.dynamic`, then calls `onSave`.

You'll add a string-backed `@State httpProxyPortText`, render the new fields inside a NEW `if draft.type == .dynamic` block in the forwarding section, validate, and clear in `commit()` when type isn't `.dynamic`.

- [ ] **Step 2: Add the new `@State` and init it**

Find:

```swift
    @State private var draft: Connection
    @State private var identityText: String
    @State private var remoteHostText: String
    @State private var remotePortText: String
    @State private var extraOptionsText: String
```

Replace with:

```swift
    @State private var draft: Connection
    @State private var identityText: String
    @State private var remoteHostText: String
    @State private var remotePortText: String
    @State private var extraOptionsText: String
    @State private var httpProxyPortText: String
```

Find the `init(initial:title:onSave:)` body:

```swift
    init(initial: Connection, title: String, onSave: @escaping (Connection) -> Void) {
        self._draft = State(initialValue: initial)
        self._identityText = State(initialValue: initial.identityFile ?? "")
        self._remoteHostText = State(initialValue: initial.remoteHost ?? "")
        self._remotePortText = State(initialValue: initial.remotePort.map(String.init) ?? "")
        self._extraOptionsText = State(initialValue: initial.extraOptions.joined(separator: "\n"))
        self.title = title
        self.onSave = onSave
    }
```

Replace with:

```swift
    init(initial: Connection, title: String, onSave: @escaping (Connection) -> Void) {
        self._draft = State(initialValue: initial)
        self._identityText = State(initialValue: initial.identityFile ?? "")
        self._remoteHostText = State(initialValue: initial.remoteHost ?? "")
        self._remotePortText = State(initialValue: initial.remotePort.map(String.init) ?? "")
        self._extraOptionsText = State(initialValue: initial.extraOptions.joined(separator: "\n"))
        self._httpProxyPortText = State(initialValue: initial.httpProxyPort.map(String.init) ?? "")
        self.title = title
        self.onSave = onSave
    }
```

- [ ] **Step 3: Render the new fields in the forwarding section**

Find the forwarding section:

```swift
                Section(forwardingSectionTitle) {
                    TextField("Local listen port", value: $draft.listenPort, format: .number)
                    if draft.type != .dynamic {
                        TextField("Remote host", text: $remoteHostText)
                        TextField("Remote port", text: $remotePortText)
                    }
                }
```

Replace with:

```swift
                Section(forwardingSectionTitle) {
                    TextField("Local listen port", value: $draft.listenPort, format: .number)
                    if draft.type != .dynamic {
                        TextField("Remote host", text: $remoteHostText)
                        TextField("Remote port", text: $remotePortText)
                    }
                    if draft.type == .dynamic {
                        Toggle("Enable HTTP proxy", isOn: $draft.httpProxyEnabled)
                        if draft.httpProxyEnabled {
                            TextField("HTTP port (leave blank for auto)", text: $httpProxyPortText)
                        }
                    }
                }
```

- [ ] **Step 4: Add validation**

Find:

```swift
    private var validationError: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required" }
        if draft.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host is required" }
        if draft.user.trimmingCharacters(in: .whitespaces).isEmpty { return "User is required" }
        if !(1...65535).contains(draft.sshPort) { return "SSH port must be 1–65535" }
        if !(1...65535).contains(draft.listenPort) { return "Listen port must be 1–65535" }
        if draft.type != .dynamic {
            if remoteHostText.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Remote host is required"
            }
            guard let p = Int(remotePortText.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(p) else {
                return "Remote port must be 1–65535"
            }
        }
        return nil
    }
```

Replace with (extends the same function with HTTP-port validation):

```swift
    private var validationError: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required" }
        if draft.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host is required" }
        if draft.user.trimmingCharacters(in: .whitespaces).isEmpty { return "User is required" }
        if !(1...65535).contains(draft.sshPort) { return "SSH port must be 1–65535" }
        if !(1...65535).contains(draft.listenPort) { return "Listen port must be 1–65535" }
        if draft.type != .dynamic {
            if remoteHostText.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Remote host is required"
            }
            guard let p = Int(remotePortText.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(p) else {
                return "Remote port must be 1–65535"
            }
        }
        if draft.type == .dynamic, draft.httpProxyEnabled {
            let trimmed = httpProxyPortText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                guard let p = Int(trimmed), (1...65535).contains(p) else {
                    return "HTTP port must be 1–65535"
                }
                if p == draft.listenPort {
                    return "HTTP port must differ from SOCKS port"
                }
            }
        }
        return nil
    }
```

- [ ] **Step 5: Update `commit()` to persist HTTP fields**

Find:

```swift
    private func commit() {
        var c = draft
        c.identityFile = identityText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : identityText.trimmingCharacters(in: .whitespaces)
        if draft.type == .dynamic {
            c.remoteHost = nil
            c.remotePort = nil
        } else {
            c.remoteHost = remoteHostText.trimmingCharacters(in: .whitespaces)
            c.remotePort = Int(remotePortText.trimmingCharacters(in: .whitespaces))
        }
        c.extraOptions = extraOptionsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(c)
    }
```

Replace with:

```swift
    private func commit() {
        var c = draft
        c.identityFile = identityText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : identityText.trimmingCharacters(in: .whitespaces)
        if draft.type == .dynamic {
            c.remoteHost = nil
            c.remotePort = nil
        } else {
            c.remoteHost = remoteHostText.trimmingCharacters(in: .whitespaces)
            c.remotePort = Int(remotePortText.trimmingCharacters(in: .whitespaces))
        }
        // HTTP proxy fields are only meaningful for .dynamic; nuke them otherwise.
        if draft.type != .dynamic {
            c.httpProxyEnabled = false
            c.httpProxyPort = nil
        } else if c.httpProxyEnabled {
            let trimmed = httpProxyPortText.trimmingCharacters(in: .whitespaces)
            c.httpProxyPort = trimmed.isEmpty ? nil : Int(trimmed)
        } else {
            c.httpProxyPort = nil
        }
        c.extraOptions = extraOptionsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(c)
    }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 7: Re-read to confirm**

Confirm the editor:
- Shows "Enable HTTP proxy" toggle only when `draft.type == .dynamic`.
- Shows the port text field only when toggle is on.
- Validates the port (1–65535, ≠ SOCKS port).
- `commit()` clears HTTP fields for non-dynamic types, and stores `nil` port for blank-means-auto.

---

### Task 6: Show HTTP port in `ConnectionListView`

**Files:**
- Modify: `Sources/SSHManager/UI/ConnectionListView.swift`

- [ ] **Step 1: Re-read the relevant pieces**

Read the file. Key landmarks:
- `ConnectionListView.body` constructs `ConnectionRow` for each connection (around line 91), passing several callbacks/values.
- `ConnectionRow` has properties at the top (`connection`, `state`, `counters`, `ping`, `onToggle`, `onRetryNow`, `onEdit`, `onShowStats`, `onDelete`).
- `private var subtitle: String` builds the secondary line. The `.dynamic` branch currently returns `"SOCKS :\(connection.listenPort)  ·  via \(target)"`.

- [ ] **Step 2: Add `httpPort` to `ConnectionRow` props**

Find the property block at the top of `private struct ConnectionRow: View`:

```swift
private struct ConnectionRow: View {
    let connection: Connection
    let state: TunnelState
    let counters: ByteCounters
    let ping: PingResult?
    let onToggle: () -> Void
    let onRetryNow: () -> Void
    let onEdit: () -> Void
    let onShowStats: () -> Void
    let onDelete: () -> Void
```

Replace with (adds `httpPort` after `ping`):

```swift
private struct ConnectionRow: View {
    let connection: Connection
    let state: TunnelState
    let counters: ByteCounters
    let ping: PingResult?
    let httpPort: Int?
    let onToggle: () -> Void
    let onRetryNow: () -> Void
    let onEdit: () -> Void
    let onShowStats: () -> Void
    let onDelete: () -> Void
```

- [ ] **Step 3: Pass `httpPort` from the parent view**

Find the `ConnectionRow(...)` call inside `ConnectionListView.content`:

```swift
                        ConnectionRow(
                            connection: c,
                            state: supervisor.state(for: c.id),
                            counters: supervisor.stats[c.id] ?? ByteCounters(),
                            ping: supervisor.pings[c.id],
                            onToggle: { supervisor.toggle(id: c.id) },
                            onRetryNow: { supervisor.retryNow(id: c.id) },
                            onEdit: { editing = c },
                            onShowStats: { statsFor = c },
                            onDelete: {
                                do {
                                    try supervisor.deleteConnection(id: c.id)
                                } catch {
                                    errorMessage = "Failed to delete: \(error.localizedDescription)"
                                }
                            }
                        )
```

Replace with (adds `httpPort:` after `ping:`):

```swift
                        ConnectionRow(
                            connection: c,
                            state: supervisor.state(for: c.id),
                            counters: supervisor.stats[c.id] ?? ByteCounters(),
                            ping: supervisor.pings[c.id],
                            httpPort: supervisor.httpPorts[c.id],
                            onToggle: { supervisor.toggle(id: c.id) },
                            onRetryNow: { supervisor.retryNow(id: c.id) },
                            onEdit: { editing = c },
                            onShowStats: { statsFor = c },
                            onDelete: {
                                do {
                                    try supervisor.deleteConnection(id: c.id)
                                } catch {
                                    errorMessage = "Failed to delete: \(error.localizedDescription)"
                                }
                            }
                        )
```

- [ ] **Step 4: Update `subtitle` for the `.dynamic` branch**

Find the current `subtitle`:

```swift
    private var subtitle: String {
        let target = "\(connection.user)@\(connection.host):\(connection.sshPort)"
        switch connection.type {
        case .dynamic:
            return "SOCKS :\(connection.listenPort)  ·  via \(target)"
        case .local:
            return "L :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0)  ·  via \(target)"
        case .remote:
            return "R :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0)  ·  via \(target)"
        }
    }
```

Replace with:

```swift
    private var subtitle: String {
        let target = "\(connection.user)@\(connection.host):\(connection.sshPort)"
        switch connection.type {
        case .dynamic:
            var base = "SOCKS :\(connection.listenPort)"
            if connection.httpProxyEnabled {
                let portText: String
                if let live = httpPort {
                    portText = "\(live)"
                } else if let configured = connection.httpProxyPort {
                    portText = "\(configured)"
                } else {
                    portText = "auto"
                }
                base += " · HTTP :\(portText)"
            }
            return "\(base)  ·  via \(target)"
        case .local:
            return "L :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0)  ·  via \(target)"
        case .remote:
            return "R :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0)  ·  via \(target)"
        }
    }
```

The fallback ladder:
1. Live `httpPort` from supervisor — use it (tunnel is running).
2. Else `connection.httpProxyPort` — use the configured port (tunnel is stopped but the port is known).
3. Else literal `auto` (tunnel is stopped and the user opted into auto-allocation).

- [ ] **Step 5: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 6: Re-read to confirm**

The connection row's subtitle now shows `... · HTTP :<port>` when HTTP proxy is enabled, with the right value across all three states (running / stopped-explicit / stopped-auto).

---

### Task 7: Version bump and build the installer

**Files:**
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Edit `CFBundleShortVersionString`**

In `Resources/Info.plist`, find:

```xml
		<key>CFBundleShortVersionString</key>
		<string>0.3.1</string>
```

Change to:

```xml
		<key>CFBundleShortVersionString</key>
		<string>0.4.0</string>
```

`CFBundleVersion` stays at `1`.

- [ ] **Step 2: Build the .app**

Run: `./scripts/build-app.sh`
Expected: script completes; `SSHManager.app` is rebuilt at the project root.

Run: `/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" SSHManager.app/Contents/Info.plist`
Expected: `0.4.0`.

---

### Task 8: Manual smoke test

This task is operator-driven — the implementer must walk through it personally. There is no test target.

Recommended setup: a `.dynamic` connection to any SSH host you control, e.g. `ssh -D 1080` style. Pick a SOCKS port the user actually has available.

- [ ] **Step 1: Launch the new build**

Run: `open SSHManager.app`
Expected: menu-bar icon appears.

- [ ] **Step 2: Verify config backward-compat**

Open the Connections window. All previously-saved connections should still appear with their fields intact. None should have HTTP proxy enabled (default is off).

- [ ] **Step 3: Verify the editor — toggle visibility per type**

Open an existing `.dynamic` connection in the editor.
Expected: "Enable HTTP proxy" toggle is visible in the "Forwarding (SOCKS)" section, unchecked.

Switch the Type picker to "Local (-L)".
Expected: the toggle disappears.

Switch back to "SOCKS (-D)".
Expected: the toggle reappears, still unchecked.

- [ ] **Step 4: Auto port mode**

Tick "Enable HTTP proxy". Leave the port field blank. Save.
Open the connection row.
Expected: subtitle reads `SOCKS :<X> · HTTP :auto · via ...`.

Start the tunnel.
Expected: within ~1 second the subtitle updates to `... · HTTP :<actual_port>` — almost certainly `SOCKS_port + 1`.

Run from terminal:
`curl -x http://127.0.0.1:<actual_port> https://api.ipify.org`
Expected: the response is your **remote** host's public IP, not your local one. (Confirms HTTP→SOCKS5→ssh→remote.)

- [ ] **Step 5: Explicit port mode**

Stop the tunnel. Edit, set HTTP port to e.g. `8888`. Save.
Subtitle now reads `... · HTTP :8888`.
Start.
`curl -x http://127.0.0.1:8888 https://api.ipify.org` — same result as before.

- [ ] **Step 6: Port conflict**

Edit, set HTTP port to the same value as the SOCKS port. Save attempt.
Expected: "HTTP port must differ from SOCKS port" appears in red, Save is disabled.

- [ ] **Step 7: Method not allowed**

With the tunnel running and HTTP proxy at `<actual_port>`:

`curl -v --proxy http://127.0.0.1:<actual_port> http://example.com/ 2>&1 | head -40`

curl will issue a plain `GET http://example.com/` to the proxy.
Expected: HTTP/1.1 405 Method Not Allowed (we only accept CONNECT).

(This is the explicit "we don't do plain HTTP" path.)

- [ ] **Step 8: Tear-down on stop**

While the tunnel is running and HTTP proxy is bound:
`lsof -iTCP:<actual_port> -sTCP:LISTEN`
Expected: SSHManager listed.

Click Stop on the connection.
Re-run the `lsof`.
Expected: no output (HTTP listener torn down with the tunnel).

- [ ] **Step 9: Build installer**

Run: `./scripts/build-pkg.sh`
Expected: `SSHManager-0.4.0.pkg` appears at the project root.

If all smoke-test steps pass and the .pkg builds, the feature is done.

---

## Self-review

**Spec coverage:**
- Spec § "Architecture" + "Components → HttpProxyServer" → Task 2 (full file).
- Spec § "Components → Connection.swift" → Task 1.
- Spec § "Components → TunnelEngine.swift" (bring-up, tear-down, `HttpProxyAllocError`) → Task 3.
- Spec § "Components → TunnelSupervisor.swift" (`httpPorts`, `pollStats`) → Task 4.
- Spec § "Components → ConnectionEditView.swift" (toggle, port field, validation, commit) → Task 5.
- Spec § "Components → ConnectionListView.swift" (subtitle, prop pass-through) → Task 6.
- Spec § "Versioning" + .pkg → Task 7.
- Spec § "Edge cases" (auto re-allocation across reconnects, port conflict at save, type change clears HTTP fields, old config backward-compat) → covered by Tasks 1, 3, 5, 6 + verified in Task 8.

**Placeholder scan:** No TBD / TODO / "fill in details". Every code step shows verbatim code. Every command has an expected outcome.

**Type consistency:**
- `HttpProxyServer.init(listenPort:socksPort:)` declared in Task 2, called from Task 3.
- `HttpProxyServer.onListenerFailure: ((Error) -> Void)?` declared in Task 2, set in Task 3.
- `TunnelEngine.actualHttpProxyPort: Int?` declared in Task 3, read from Task 4.
- `TunnelSupervisor.httpPorts: [UUID: Int]` declared in Task 4, read in Task 6.
- `Connection.httpProxyEnabled: Bool` / `Connection.httpProxyPort: Int?` declared in Task 1, used in Tasks 3, 5, 6.
- `HttpProxyAllocError.noFreePort(startedAt:tried:)` declared in Task 3, thrown by `bringUpHttpProxy`.
