# Open at Login (Phase 6)

Status: approved, ready for implementation plan.
Date: 2026-05-14.

## Goal

Let the user opt the app into launching automatically at login through a
checkbox in the Connections window. macOS owns the source of truth — we just
toggle registration with `SMAppService` and reflect its current status in the
UI. Per-connection `autoStart` already decides which tunnels come up once the
app is running; this spec only covers the app launch itself.

## Scope

In:
- New `LoginItem` storage wrapper around `SMAppService.mainApp`.
- A "Open at login" toggle in the Connections window header.
- Error handling for register/unregister failures.
- Surfacing the `.requiresApproval` state with a one-click way into System
  Settings → Login Items.

Out:
- A menu-bar entry for the toggle (Connections window is the home for it).
- Persisting our own copy of the flag in UserDefaults — `SMAppService.status`
  is authoritative.
- Pre-macOS-13 fallback (`SMLoginItemSetEnabled` / helper-bundle plumbing).
  The deployment target is already 13.0.
- Touching `AppDelegate` or the autostart of individual tunnels — those paths
  already do the right thing once the app is running.

## User experience

- The Connections window header gets a small toggle on its trailing edge:
  `[ Connections ............... ☐ Open at login    + Add ]`.
  `.controlSize(.small)` to keep it visually subordinate to the title.
- Default OFF. New installs do not register a login item until the user opts
  in. (A user who reinstalls or moves the app may also need to re-toggle —
  that matches macOS norms.)
- Clicking the toggle calls `LoginItem.setEnabled(true/false)`. On success the
  state stays in sync.
- If register/unregister throws, revert the toggle and show an alert with the
  underlying error message and a hint pointing at System Settings.
- If after a successful register the status is `.requiresApproval`, show an
  alert with an "Open Settings" button that deep-links to
  `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`. Leave
  the toggle on — user just needs to approve.

## Architecture

One new file, one modified view, no changes to app lifecycle wiring.

### `Sources/SSHManager/Storage/LoginItem.swift` (~30 lines)

Pure wrapper around `SMAppService.mainApp`. No state of its own.

```swift
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

Why an enum: there's nothing to instantiate. `SMAppService.mainApp` is the
singleton, our wrapper is stateless.

### `Sources/SSHManager/UI/ConnectionListView.swift`

Header layout currently:

```
HStack { Text("Connections") ; Spacer() ; Button("+ Add") }
```

Becomes:

```
HStack {
    Text("Connections")
    Spacer()
    Toggle("Open at login", isOn: $openAtLogin)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    Button("+ Add") { ... }
}
```

State on the view:

```swift
@State private var openAtLogin: Bool = LoginItem.isEnabled
@State private var loginAlert: LoginAlert?

private struct LoginAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let openSettings: Bool
}
```

`.onChange(of: openAtLogin)` calls `LoginItem.setEnabled(newValue)`. On
throw: revert `openAtLogin` to `!newValue` and populate `loginAlert` with
the error description plus the Login-Items pointer. On success: if
`newValue == true && LoginItem.requiresApproval`, populate `loginAlert`
with the approval-needed copy and `openSettings = true`.

`.alert(item: $loginAlert)` renders title/message + optional "Open Settings"
button (`NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:...")!)`)
and "OK".

`.onAppear { openAtLogin = LoginItem.isEnabled }` — when the user comes back
from Settings and re-opens our window the toggle reflects the truth.

## Edge cases handled

- **User unregisters from System Settings while the app is open.** Our
  `@State` flag is stale until the window re-appears. We accept this — the
  next `.onAppear` resyncs. (Polling `SMAppService.status` every second
  would be overkill for a setting changed maybe twice in a lifetime.)
- **`register()` throws.** Most common cause: the binary lives outside
  `/Applications` and macOS refuses to register a transient location. Alert
  copy points the user at System Settings; the toggle reverts.
- **Status returns `.requiresApproval` after a successful register.** macOS
  registered our intent but the user must flip the master switch. Alert
  with deep-link button; toggle stays on.
- **App moved or replaced.** macOS may invalidate the registration. The
  toggle will read OFF on next launch (`.notRegistered` → `isEnabled = false`)
  and the user can re-toggle.
- **No git repo / no test target.** Smoke test only: toggle on, quit, log
  out / log in, confirm app starts hidden in menu bar. Then toggle off,
  log out / log in, confirm it does not start.

## File changes

**Create:**
- `Sources/SSHManager/Storage/LoginItem.swift` — the enum above.

**Modify:**
- `Sources/SSHManager/UI/ConnectionListView.swift`
  - Add `@State openAtLogin` + `@State loginAlert` to the list view.
  - Add the `Toggle` to the header `HStack`.
  - Add `.onChange(of: openAtLogin)` handler that calls `LoginItem.setEnabled`
    and manages the revert/alert flow.
  - Add `.onAppear` resync.
  - Add `.alert(item:)` modifier.
- `Resources/Info.plist`
  - Bump `CFBundleShortVersionString` to `0.3.1`.

**Not touched:** `AppDelegate`, `MenuBarController`, `TunnelEngine`,
`TunnelSupervisor`, `Connection`, `ConfigStore`, `Paths`. Per-connection
`autoStart` already does the right thing on app launch.

## Versioning

`0.3.0` → `0.3.1`. This is a QoL convenience, not a feature on the level of
auto-reconnect — patch bump fits.

## Open implementation questions

None.
