# HTTP/HTTPS Proxy (Phase 7)

Status: approved, ready for implementation plan.
Date: 2026-05-18.

## Goal

Let each `.dynamic` (SOCKS) connection optionally expose a second listener — a
CONNECT-only HTTP proxy on a separate port — that forwards traffic through the
same SSH tunnel. Browsers and tools that prefer "HTTP proxy" configuration get
a working endpoint without the user having to wire up a separate
`privoxy`/`tinyproxy` daemon. The user picks the HTTP port explicitly or
lets the app find a free one.

## Scope

In:
- Per-connection toggle `httpProxyEnabled` (only meaningful for `.dynamic`).
- Per-connection `httpProxyPort: Int?` (nil = auto-allocate).
- New `HttpProxyServer` component that accepts only `CONNECT` and forwards
  through the existing local SOCKS5 listener on `127.0.0.1`.
- Auto-allocation: scan from `listenPort + 1` upward, up to 100 attempts.
- Display of the actually-bound port in the connection row subtitle.
- Persistence of new fields in `config.json` with backward-compatible decoding.

Out:
- Plain HTTP (`GET http://...`) request rewriting. The CONNECT path covers
  every modern client (browsers, curl, requests with `HTTPS_PROXY`, etc.).
- Proxy authentication (Basic/Digest/etc.). Local 127.0.0.1 listener; no need.
- HTTP proxy support on `.local` / `.remote` tunnels — semantically wrong.
  The toggle is hidden in the editor and never reachable through normal UI.
- Independent byte counting for the HTTP path. Traffic flows through the
  existing SOCKS `ProxyServer` and is already counted there.
- Per-connection auth/ACL on the HTTP port — same logic as SOCKS today.

## Architecture

```
HTTP client ──(plain HTTP CONNECT)──► HttpProxyServer (NWListener on chosen port)
                                              │
                                              │  TCP to 127.0.0.1
                                              ▼
                                       SOCKS ProxyServer
                                              │  (existing — byte counted here)
                                              ▼
                                          ssh -D :NNNNN
                                              │
                                              ▼
                                            remote
```

The HTTP proxy is a TCP client of the local SOCKS5 listener. This is the only
design decision that earns its keep:

1. All byte counting stays in one place (`ProxyServer.swift`'s `onBytes`),
   whether the user connected via SOCKS directly or via HTTP. No double-count,
   no duplicated state.
2. `HttpProxyServer` only needs to speak SOCKS5 to a fixed `127.0.0.1:NN`
   target — no plumbing into the ssh process or its lifecycle.
3. During reconnect the HTTP listener is torn down alongside the SOCKS
   listener, so HTTP clients see TCP refused — same UX as if they were
   pointing at the SOCKS port directly.

## Components

### New: `Sources/SSHManager/Tunnel/HttpProxyServer.swift` (~150 lines)

Single-purpose CONNECT-only HTTP proxy. Mirrors the shape of the existing
`ProxyServer`: an `NWListener` on a serial dispatch queue, `start()` /
`stop()`, `onListenerFailure: ((Error) -> Void)?` callback.

Protocol flow per accepted client:

1. Read up to 8 KiB or until `\r\n\r\n` is found.
2. Parse first line `CONNECT host:port HTTP/1.1`.
   - Any other method → reply `HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n`, close.
   - Malformed CONNECT (no host:port, bad port number) → `HTTP/1.1 400 Bad Request\r\n...`, close.
   - Headers between request line and blank line are read and ignored.
3. Open `NWConnection` to `127.0.0.1:<socksPort>`.
4. SOCKS5 no-auth handshake:
   - Send `05 01 00`. Read 2 bytes. Expect `05 00`. Anything else → reply
     `HTTP/1.1 502 Bad Gateway\r\n...` to the client, close both.
   - Send CONNECT request: `05 01 00 <ATYP> <ADDR> <PORT>` where:
     - `ATYP=03` (domain) + length byte + UTF-8 host bytes, OR
     - `ATYP=01` (IPv4) + 4 bytes if `host` parses as IPv4, OR
     - `ATYP=04` (IPv6) + 16 bytes if `host` parses as IPv6.
   - Read response (10 bytes for IPv4 BND, but we only care about first 2
     bytes: VER=05, REP). REP=00 → success. Anything else → `502`. Drain
     remaining BND.ADDR/PORT bytes before closing on success path (need
     correct framing).
5. Reply to HTTP client: `HTTP/1.1 200 Connection Established\r\n\r\n`.
6. Splice both directions with the same recursive-receive pattern used in
   `ProxyServer.pump`. No additional byte counting here.

Idle timeouts: do not add. The existing SOCKS path doesn't time out either;
ssh's `ServerAliveInterval` handles dead tunnels at the transport layer.

### Modified: `Sources/SSHManager/Models/Connection.swift`

Add stored properties:

```swift
var httpProxyEnabled: Bool   // default false
var httpProxyPort: Int?      // nil = auto-allocate
```

Add to the designated initializer with defaults `false` / `nil` and to
`Connection.blank()` (both fields off).

Replace the synthesized `Codable` conformance with a custom `init(from:)`
that uses `decodeIfPresent` for the two new fields and defaults them when
absent. (All existing fields keep `decode(...)` with their current required
semantics.) The encoder stays synthesized — new fields write through with
their current values.

Why custom decoder, not optional fields with computed defaults: the
synthesized decoder treats missing required fields as a hard error, but only
`Optional<T>` properties are auto-defaulted-to-nil. We don't want to make
`httpProxyEnabled` Optional<Bool> in the model just to satisfy the decoder;
that pushes Optional handling onto every call site. Custom decoder is the
clean fix and localized.

### Modified: `Sources/SSHManager/Tunnel/TunnelEngine.swift`

New private fields:

```swift
private var httpProxy: HttpProxyServer?
private(set) var actualHttpProxyPort: Int?
```

In `start()`, after `ssh` has been launched and state is `.running`:

```swift
if connection.type == .dynamic, connection.httpProxyEnabled {
    do {
        let (port, server) = try bringUpHttpProxy(socksPort: connection.listenPort)
        actualHttpProxyPort = port
        httpProxy = server
    } catch {
        writeLog("http proxy failed: \(error.localizedDescription)")
        let reason = "HTTP proxy: \(error.localizedDescription)"
        // Tear ssh + SOCKS down so the user isn't stranded with a half-up tunnel.
        proxy?.stop(); proxy = nil
        process?.terminate(); process = nil
        successUptimeTimer?.cancel(); successUptimeTimer = nil
        closeLog()
        scheduleRetryOrGiveUp(reason: reason)
        return
    }
}
```

In `handleTermination`, `handleProxyFailure`, and the `stop()` cleanup paths,
add a single line: `httpProxy?.stop(); httpProxy = nil; actualHttpProxyPort = nil`
in the same places that `proxy?.stop()` runs.

New private helper:

```swift
private func bringUpHttpProxy(socksPort: Int) throws -> (port: Int, server: HttpProxyServer) {
    if let explicit = connection.httpProxyPort {
        let server = HttpProxyServer(listenPort: explicit, socksPort: socksPort)
        server.onListenerFailure = { [weak self] err in
            DispatchQueue.main.async { self?.handleHttpProxyFailure(err) }
        }
        try server.start()
        return (explicit, server)
    }
    // Auto: scan from socksPort+1 upward up to 100 attempts.
    var port = socksPort + 1
    let maxAttempts = 100
    for _ in 0..<maxAttempts {
        guard port <= 65535 else { break }
        let server = HttpProxyServer(listenPort: port, socksPort: socksPort)
        do {
            try server.start()
            server.onListenerFailure = { [weak self] err in
                DispatchQueue.main.async { self?.handleHttpProxyFailure(err) }
            }
            return (port, server)
        } catch {
            port += 1
        }
    }
    throw HttpProxyAllocError.noFreePort
}
```

`handleHttpProxyFailure(_:)`: same shape as `handleProxyFailure` — log,
`manuallyStopped = true`, terminate ssh, stop SOCKS proxy, stop HTTP proxy,
clear `actualHttpProxyPort`, `scheduleRetryOrGiveUp("HTTP proxy: \(err)")`.

### Modified: `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`

New `@Published var httpPorts: [UUID: Int] = [:]` — published parallel to
`stats` / `pings`. A connection's entry is present only when its HTTP proxy
is bound; absence = unbound. Updated alongside the existing stats polling:
in `pollStats()` build a fresh map from each engine's `actualHttpProxyPort`
(skipping nil) and assign only if different (avoid SwiftUI churn).

### Modified: `Sources/SSHManager/UI/ConnectionEditView.swift`

In the "Forwarding (SOCKS)" section, only when `draft.type == .dynamic`,
append:

```swift
Toggle("Enable HTTP proxy", isOn: $draft.httpProxyEnabled)
if draft.httpProxyEnabled {
    TextField("HTTP port (leave blank for auto)", text: $httpProxyPortText)
}
```

`httpProxyPortText: String` is a new local `@State` initialized from
`initial.httpProxyPort.map(String.init) ?? ""`. `commit()` sets
`draft.httpProxyPort = httpProxyPortText` parsed as `Int?` (whitespace-trimmed
empty string → nil). When `draft.type` is not `.dynamic` at save time,
`commit()` forces `httpProxyEnabled = false` and `httpProxyPort = nil`
(parallel to how it nukes `remoteHost`/`remotePort` today).

Validation in `validationError`:

```swift
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
```

### Modified: `Sources/SSHManager/UI/ConnectionListView.swift`

`ConnectionRow` gets a new param `httpPort: Int?` (current actual port from
supervisor; nil when not bound). Rendered subtitle changes:

Current:
```
SOCKS :1080  ·  via user@host:22
```

New (when `httpProxyEnabled` true):
```
SOCKS :1080 · HTTP :1081  ·  via user@host:22
```

Specifically: in the `.dynamic` branch of `subtitle`, if
`connection.httpProxyEnabled`, append ` · HTTP :\(httpPort ?? "auto")`
where the value is the actual bound port if known, otherwise the literal
`auto` placeholder (when configured port is nil and tunnel is stopped) or
the configured port (when explicit and tunnel is stopped).

Concrete fallback ladder for the displayed text:
1. `httpPort` from supervisor (non-nil) → use it.
2. else `connection.httpProxyPort` (explicit, but tunnel not running) → use it.
3. else → literal `auto`.

The `ConnectionListView` body passes `httpPort: supervisor.httpPorts[c.id]`
to each `ConnectionRow`.

### Modified: `Resources/Info.plist`

`CFBundleShortVersionString` → `0.4.0`.

## Errors

```swift
enum HttpProxyAllocError: LocalizedError {
    case noFreePort
    var errorDescription: String? {
        "Could not find a free HTTP proxy port in the range scanned (100 tries)."
    }
}
```

`HttpProxyServer` does not need its own error type — `NWListener` start
failure (port busy) bubbles up as `NWError` via `try server.start()` and
`onListenerFailure` for mid-run faults. Inside the proxy, malformed-request
and SOCKS-handshake-failure paths write a small HTTP error response to the
client and close — no thrown errors propagate out.

## Edge cases

- **User toggles HTTP off in editor and saves while tunnel is running.**
  `updateConnection` already does stop + rebuild engine. New engine sees
  `httpProxyEnabled = false`, doesn't bring up HTTP. Old `httpProxy` was
  torn down in `stop()`. No special handling.
- **User changes HTTP port while running.** Same: stop + rebuild. New port
  is bound on next start.
- **Auto-allocated port differs across reconnects.** Acceptable. The UI
  subtitle always reflects `actualHttpProxyPort` from the supervisor, which
  updates on the stats-polling tick after a successful restart. Clients
  hard-coded to a specific port should set `httpProxyPort` explicitly.
- **Port conflict between SOCKS and HTTP at save time.** Caught by
  `validationError`; Save button is disabled.
- **Port conflict between two connections' HTTP ports.** Same failure mode
  as duplicate SOCKS ports today — second tunnel's HTTP bind fails, retry
  schedule kicks in. The user sees an `HTTP proxy: ... address already in use`
  reason in the row's `.failed` / `.reconnecting` status.
- **Connection imported from old config.json.** Custom decoder defaults
  `httpProxyEnabled = false`, `httpProxyPort = nil`. Saved-back JSON gets
  the new keys.
- **Connection type changed from `.dynamic` to `.local`/`.remote`.** `commit()`
  in the editor clears both HTTP fields. Engine on rebuild does not bring up
  HTTP because of the `type == .dynamic` guard.

## File changes summary

**Create:**
- `Sources/SSHManager/Tunnel/HttpProxyServer.swift`

**Modify:**
- `Sources/SSHManager/Models/Connection.swift` — new fields + custom decoder.
- `Sources/SSHManager/Tunnel/TunnelEngine.swift` — bring-up, tear-down, retry, exposed port.
- `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` — published `httpPorts` map.
- `Sources/SSHManager/UI/ConnectionEditView.swift` — toggle + port field + validation.
- `Sources/SSHManager/UI/ConnectionListView.swift` — subtitle rendering, pass-through prop.
- `Resources/Info.plist` — version `0.4.0`.

**Not touched:** `ProxyServer.swift`, `PingMonitor.swift`, `HistoryStore.swift`,
`StatsView.swift`, `MenuBarController.swift`, `AppDelegate.swift`, `LoginItem.swift`,
`MainWindowController.swift`, `ConfigStore.swift`, `Paths.swift`.

## Versioning

`0.3.1` → `0.4.0`. New user-visible feature, minor bump.

## Open implementation questions

None.
