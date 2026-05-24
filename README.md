# SSH Manager

Menu bar app for macOS that manages persistent SSH tunnels.

## Status

**Phase 1 (current)** — minimal working tray app:
- Reads connections from `~/Library/Application Support/SSHManager/config.json`
- Start/stop each tunnel from the menu bar
- Logs ssh stderr per connection
- Supports `-D` (dynamic / SOCKS), `-L` (local forward), `-R` (remote forward)

**Not yet:**
- Editor UI (you edit `config.json` by hand, then "Reload Config")
- Byte counters (proxy layer)
- Auto-reconnect with backoff
- Persistent stats / history
- LaunchAgent autostart

## Build

```sh
./scripts/build-app.sh          # produces ./SSHManager.app
open ./SSHManager.app
```

You need Swift 6.0+ (comes with Xcode or Command Line Tools).
No external dependencies. The build is ad-hoc code-signed for local use.

## Sharing

```sh
./scripts/build-pkg.sh          # produces SSHManager-<version>.pkg
```

The package installs the app into `/Applications`. Because the .pkg and the
.app are signed ad-hoc (not with an Apple Developer ID), Gatekeeper will
refuse to open them on a normal double-click on the recipient's Mac.

**Tell the recipient to do this once:**
1. Right-click the `.pkg` → **Open**, then confirm. This installs the app.
2. After install, right-click `/Applications/SSHManager.app` → **Open**.

Or, in Terminal, in one shot:

```sh
xattr -dr com.apple.quarantine /Applications/SSHManager.app
open /Applications/SSHManager.app
```

## Configuration

On first launch the app creates an empty config at:

    ~/Library/Application Support/SSHManager/config.json

Open it via the menu (**Edit config.json…**) and add entries. Then click
**Reload Config**.

### Schema

```json
[
  {
    "id": "11111111-1111-1111-1111-111111111111",
    "name": "Work SOCKS",
    "type": "dynamic",
    "host": "bastion.example.com",
    "sshPort": 22,
    "user": "root",
    "identityFile": "~/.ssh/id_ed25519",
    "listenPort": 1080,
    "autoReconnect": true,
    "autoStart": true,
    "extraOptions": []
  },
  {
    "id": "22222222-2222-2222-2222-222222222222",
    "name": "Postgres on prod",
    "type": "local",
    "host": "bastion.example.com",
    "sshPort": 22,
    "user": "ops",
    "listenPort": 5433,
    "remoteHost": "db-prod.internal",
    "remotePort": 5432,
    "autoReconnect": true,
    "autoStart": false,
    "extraOptions": ["Compression=yes"]
  },
  {
    "id": "33333333-3333-3333-3333-333333333333",
    "name": "Expose local dev",
    "type": "remote",
    "host": "tunnel.example.com",
    "sshPort": 22,
    "user": "me",
    "listenPort": 8080,
    "remoteHost": "localhost",
    "remotePort": 3000,
    "autoReconnect": false,
    "autoStart": false,
    "extraOptions": []
  }
]
```

### Field reference

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Any UUID; used as a stable key (and log file name) |
| `name` | yes | Shown in the menu |
| `type` | yes | `dynamic`, `local`, or `remote` |
| `host` | yes | SSH target hostname |
| `sshPort` | yes | Usually 22 |
| `user` | yes | SSH user |
| `identityFile` | no | Optional, `~/` is expanded. If absent, ssh's default key search is used. |
| `listenPort` | yes | Local port to bind (or remote port for `-R`) |
| `remoteHost` | only `-L`, `-R` | Target host as seen from the remote (or local, for `-R`) side |
| `remotePort` | only `-L`, `-R` | Target port |
| `autoReconnect` | yes | Reserved for phase 5; ignored in phase 1 |
| `autoStart` | yes | If true, start when the app launches |
| `extraOptions` | yes | Extra `ssh -o` strings, e.g. `"TCPKeepAlive=yes"` (no leading `-o`) |

## Authentication

The app shells out to `/usr/bin/ssh` with `BatchMode=yes`. That means **no password
prompts** — auth must work non-interactively. In practice:

- public-key auth via `~/.ssh/id_*` or an explicit `identityFile`
- keys loaded into `ssh-agent` (the agent is inherited from launch)

If a tunnel fails immediately on start, open the log folder via the menu and
check `<connection-id>.log`.

## How it works (phase 1)

For each connection the app spawns `/usr/bin/ssh` with appropriate flags:

```
/usr/bin/ssh -N -T \
  -o BatchMode=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -D 1080 \
  -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes \
  -p 22 \
  root@bastion.example.com
```

The child process lives as long as the menu bar shows it green. When the user
toggles it off the app sends `SIGTERM`. If ssh dies on its own (server timeout,
network drop, auth failure), the menu item turns to `⚠` — phase 5 will add
automatic reconnection.

## Files & directories

```
~/Library/Application Support/SSHManager/
  config.json                  ← edited by you (or, later, the UI)
  logs/<connection-id>.log     ← ssh stderr per run
```

## Project layout

```
Package.swift
Resources/Info.plist
scripts/build-app.sh
Sources/SSHManager/
  main.swift
  AppDelegate.swift
  Models/Connection.swift
  Storage/Paths.swift
  Storage/ConfigStore.swift
  Tunnel/TunnelEngine.swift
  Tunnel/TunnelSupervisor.swift
  UI/MenuBarController.swift
```
