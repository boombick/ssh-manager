# Auto-Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an ssh child dies on its own, automatically retry with exponential backoff (2/5/10/20/30/60s, cap at 60s, max 20 attempts), expose the retry state in the row with a live countdown, and offer "Retry now" + "Stop" buttons during reconnect.

**Architecture:** All reconnect logic lives inside `TunnelEngine` — it already owns the ssh `Process`, the `terminationHandler`, and the `manuallyStopped` flag. A new `.reconnecting(attempt, nextRetryAt, lastError)` state is added to `TunnelState`; `DispatchSourceTimer`s back the retry-delay and the 30s success-uptime reset. The supervisor gains a single `retryNow(id:)` pass-through. The row's single Start/Stop button becomes a state-aware `@ViewBuilder` returning one or two buttons.

**Tech Stack:** Swift 6.0 / SwiftPM (no new deps), AppKit-hosted SwiftUI, `DispatchSourceTimer` for retry scheduling, `TimelineView(.periodic(...))` for the countdown.

**Conventions for this plan:**
- This project is **not a git repo** — "commit" steps become "checkpoint: `swift build` must succeed".
- This project has **no test target**. End-of-task verification is `swift build` plus, for the final integration task, a manual smoke that involves killing the ssh child by hand to trigger the retry path.
- Reference spec: `docs/superpowers/specs/2026-05-14-auto-reconnect-design.md`.

---

## File Structure

**Modify only — no new files:**

- `Sources/SSHManager/Tunnel/TunnelEngine.swift` — extend `TunnelState`; add `currentAttempt`, `retryTimer`, `successUptimeTimer`, backoff constants; reshape `handleTermination` and `stop`; add `retryNow`, `scheduleRetryOrGiveUp`, `armSuccessUptimeTimer`; route synchronous `start()` failures through the same scheduling helper.
- `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` — add `func retryNow(id:)`; extend `recordStateChangeEvent` switch with `case .reconnecting: break`.
- `Sources/SSHManager/UI/ConnectionListView.swift` — replace the single Start/Stop button with a state-aware view; add a status line with countdown for `.reconnecting`; pipe `onRetryNow` through `ConnectionRow`.
- `Sources/SSHManager/UI/MenuBarController.swift` — add `.reconnecting` glyph (`↻`) to the menu title switch.

**Not touched:** `Connection`, `Paths`, `ConfigStore`, `PingMonitor`, `HistoryStore`, `Database`, `StatsView`, `ProxyServer`, `AppDelegate`, `MainWindowController`, `ConnectionEditView`.

---

## Task 1: Extend `TunnelState` with `.reconnecting`

This task changes the enum and fixes every existing exhaustive switch so the project still compiles. The new state behaves like `.stopped` semantically until Task 2 wires the real logic in.

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelEngine.swift`
- Modify: `Sources/SSHManager/UI/MenuBarController.swift`
- Modify: `Sources/SSHManager/UI/ConnectionListView.swift`

- [ ] **Step 1: Extend the enum**

In `Sources/SSHManager/Tunnel/TunnelEngine.swift`, replace:

```swift
enum TunnelState: Equatable {
    case stopped
    case running
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
```

with:

```swift
enum TunnelState: Equatable {
    case stopped
    case running
    case reconnecting(attempt: Int, nextRetryAt: Date, lastError: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
```

- [ ] **Step 2: Add a `.reconnecting` glyph in the menu title**

In `Sources/SSHManager/UI/MenuBarController.swift`, replace the `glyph` switch in `title(for:state:counters:)`:

```swift
        let glyph: String
        switch state {
        case .stopped: glyph = "○"
        case .running: glyph = "●"
        case .failed:  glyph = "⚠"
        }
```

with:

```swift
        let glyph: String
        switch state {
        case .stopped:      glyph = "○"
        case .running:      glyph = "●"
        case .reconnecting: glyph = "↻"
        case .failed:       glyph = "⚠"
        }
```

- [ ] **Step 3: Add a `.reconnecting` colour in the row**

In `Sources/SSHManager/UI/ConnectionListView.swift`, find `private func color(for state: TunnelState) -> Color` inside `ConnectionRow` and replace:

```swift
    private func color(for state: TunnelState) -> Color {
        switch state {
        case .stopped: return .secondary
        case .running: return .green
        case .failed:  return .red
        }
    }
```

with:

```swift
    private func color(for state: TunnelState) -> Color {
        switch state {
        case .stopped:      return .secondary
        case .running:      return .green
        case .reconnecting: return .yellow
        case .failed:       return .red
        }
    }
```

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: `Build complete!`. No exhaustive-switch errors.

---

## Task 2: Engine — retry scheduling and uptime reset

This is the core of the feature. We add the timer fields, constants, the scheduling helper, and reshape `handleTermination` plus the tail of `start()` to call into the helper on failure.

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelEngine.swift`

- [ ] **Step 1: Add fields and constants**

In `Sources/SSHManager/Tunnel/TunnelEngine.swift`, find the existing fields block:

```swift
    private var process: Process?
    private var proxy: ProxyServer?
    private var logHandle: FileHandle?
    private var manuallyStopped = false

    private let statsLock = NSLock()
    private var _bytesUp: UInt64 = 0
    private var _bytesDown: UInt64 = 0
```

Replace with:

```swift
    private var process: Process?
    private var proxy: ProxyServer?
    private var logHandle: FileHandle?
    private var manuallyStopped = false

    private let statsLock = NSLock()
    private var _bytesUp: UInt64 = 0
    private var _bytesDown: UInt64 = 0

    // Reconnect machinery
    private var retryTimer: DispatchSourceTimer?
    private var successUptimeTimer: DispatchSourceTimer?
    private var currentAttempt: Int = 0

    private static let backoffSchedule: [TimeInterval] = [2, 5, 10, 20, 30, 60]
    private static let maxAttempts: Int = 20
    private static let successUptimeThreshold: TimeInterval = 30
```

- [ ] **Step 2: Preserve `currentAttempt` across retry-driven `start()`s; reset it on a manual start**

Find the top of `start()`:

```swift
    func start() {
        guard process == nil else { return }
        manuallyStopped = false
        resetStats()
```

Replace with:

```swift
    func start() {
        guard process == nil else { return }
        manuallyStopped = false
        // currentAttempt is preserved when start() runs as part of a retry
        // (state is .reconnecting at that moment). Any other entry — manual
        // Start from .stopped/.failed — is a fresh series, so we zero it.
        if case .reconnecting = state {
            // keep currentAttempt as the timer / retryNow caller set it
        } else {
            currentAttempt = 0
        }
        // Cancel any pending retry — start() always wins.
        retryTimer?.cancel()
        retryTimer = nil
        resetStats()
```

- [ ] **Step 3: Route synchronous `start()` failures through the scheduler**

In `start()`, find the proxy-bind failure branch:

```swift
        do {
            try proxy.start()
        } catch {
            writeLog("proxy bind failed on port \(plan.proxyListenPort): \(error.localizedDescription)")
            state = .failed("Cannot bind port \(plan.proxyListenPort): \(error.localizedDescription)")
            closeLog()
            return
        }
```

Replace with:

```swift
        do {
            try proxy.start()
        } catch {
            writeLog("proxy bind failed on port \(plan.proxyListenPort): \(error.localizedDescription)")
            let reason = "Cannot bind port \(plan.proxyListenPort): \(error.localizedDescription)"
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
            return
        }
```

Also find the ssh-launch failure branch:

```swift
        do {
            try p.run()
            process = p
            state = .running
        } catch {
            writeLog("failed to launch ssh: \(error.localizedDescription)")
            proxy.stop()
            self.proxy = nil
            state = .failed("Failed to launch ssh: \(error.localizedDescription)")
            closeLog()
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
        }
```

And in the planTunnel-failure branch:

```swift
        let plan: TunnelPlan
        do {
            plan = try planTunnel()
        } catch {
            writeLog("plan failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            closeLog()
            return
        }
```

Replace with:

```swift
        let plan: TunnelPlan
        do {
            plan = try planTunnel()
        } catch {
            writeLog("plan failed: \(error.localizedDescription)")
            let reason = error.localizedDescription
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
            return
        }
```

- [ ] **Step 4: Reshape `handleTermination`**

Replace:

```swift
    private func handleTermination(exitCode: Int32) {
        writeLog("ssh exited with code \(exitCode)")
        proxy?.stop()
        proxy = nil
        process = nil

        if manuallyStopped {
            state = .stopped
        } else {
            state = .failed("ssh exited with code \(exitCode)")
        }
        closeLog()
    }
```

with:

```swift
    private func handleTermination(exitCode: Int32) {
        writeLog("ssh exited with code \(exitCode)")
        proxy?.stop()
        proxy = nil
        process = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil

        if manuallyStopped {
            state = .stopped
            closeLog()
            return
        }
        let reason = "ssh exited with code \(exitCode)"
        closeLog()
        scheduleRetryOrGiveUp(reason: reason)
    }
```

- [ ] **Step 5: Add `scheduleRetryOrGiveUp` and `armSuccessUptimeTimer`**

Add to the `// MARK: - Private` section, after `handleProxyFailure`:

```swift
    // MARK: - Reconnect

    private func scheduleRetryOrGiveUp(reason: String) {
        guard connection.autoReconnect else {
            state = .failed(reason)
            return
        }
        let nextAttempt = currentAttempt + 1
        if nextAttempt > TunnelEngine.maxAttempts {
            state = .failed("Gave up after \(TunnelEngine.maxAttempts) reconnect attempts: \(reason)")
            return
        }
        let idx = min(nextAttempt - 1, TunnelEngine.backoffSchedule.count - 1)
        let delay = TunnelEngine.backoffSchedule[idx]
        let nextAt = Date().addingTimeInterval(delay)
        currentAttempt = nextAttempt
        state = .reconnecting(attempt: nextAttempt, nextRetryAt: nextAt, lastError: reason)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // If the state moved off .reconnecting (user pressed Stop, edited
            // the connection, etc.) the timer's owner is gone; do nothing.
            guard case .reconnecting = self.state else { return }
            self.retryTimer = nil
            self.start()
        }
        retryTimer = timer
        timer.resume()
    }

    private func armSuccessUptimeTimer() {
        successUptimeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + TunnelEngine.successUptimeThreshold)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Only meaningful if we're still .running when it fires.
            if case .running = self.state {
                self.currentAttempt = 0
            }
            self.successUptimeTimer = nil
        }
        successUptimeTimer = timer
        timer.resume()
    }
```

- [ ] **Step 6: Update `handleProxyFailure` to go through the scheduler**

Replace:

```swift
    private func handleProxyFailure(_ error: Error) {
        writeLog("proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true   // suppress "ssh exited" failure message; the proxy failed first
        process?.terminate()
        proxy?.stop()
        proxy = nil
        state = .failed("Proxy: \(error.localizedDescription)")
    }
```

with:

```swift
    private func handleProxyFailure(_ error: Error) {
        writeLog("proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true   // suppress "ssh exited" failure message; the proxy failed first
        process?.terminate()
        proxy?.stop()
        proxy = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil
        let reason = "Proxy: \(error.localizedDescription)"
        // manuallyStopped was set above so handleTermination won't fire retry.
        // We retry from here ourselves, treating proxy failure like ssh death.
        scheduleRetryOrGiveUp(reason: reason)
    }
```

- [ ] **Step 7: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 3: Engine — `stop` and `retryNow`

`stop()` must now also handle the `.reconnecting` case (cancel the pending retry and land in `.stopped`). `retryNow()` is new.

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelEngine.swift`

- [ ] **Step 1: Reshape `stop()`**

Replace:

```swift
    func stop() {
        guard process != nil else {
            // Nothing running. If we're in .failed, reset to stopped so the user can retry.
            if case .failed = state { state = .stopped }
            return
        }
        manuallyStopped = true
        process?.terminate()
        // handleTermination runs on the main queue once the ssh process exits;
        // it will tear down the proxy as well.
    }
```

with:

```swift
    func stop() {
        // Cancel any pending reconnect timer first — Stop always wins.
        retryTimer?.cancel()
        retryTimer = nil

        if case .reconnecting = state {
            // No ssh process is alive; just land in .stopped.
            currentAttempt = 0
            state = .stopped
            return
        }

        guard process != nil else {
            // Nothing running. If we're in .failed, reset to stopped so the user can retry.
            if case .failed = state { state = .stopped }
            return
        }
        manuallyStopped = true
        process?.terminate()
        // handleTermination runs on the main queue once the ssh process exits;
        // it will tear down the proxy as well.
    }
```

- [ ] **Step 2: Add `retryNow()`**

Add immediately after `stop()`:

```swift
    /// User-initiated "skip the backoff" while in `.reconnecting`. Preserves the
    /// attempt counter so we don't allow infinite Retry-now spam to bypass backoff
    /// progression: if this attempt also fails, the next delay grows as usual.
    func retryNow() {
        guard case .reconnecting = state else { return }
        retryTimer?.cancel()
        retryTimer = nil
        start()
    }
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 4: Supervisor — `retryNow` pass-through and event recording

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`

- [ ] **Step 1: Add `retryNow(id:)`**

In `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`, in the `// MARK: - Lifecycle` section, replace:

```swift
    func toggle(id: UUID) {
        guard let e = engines[id] else { return }
        if e.state.isRunning {
            e.stop()
        } else {
            e.start()
        }
    }

    func stopAll() {
        for e in engines.values { e.stop() }
    }
```

with:

```swift
    func toggle(id: UUID) {
        guard let e = engines[id] else { return }
        if e.state.isRunning {
            e.stop()
        } else {
            e.start()
        }
    }

    func retryNow(id: UUID) {
        engines[id]?.retryNow()
    }

    func stopAll() {
        for e in engines.values { e.stop() }
    }
```

- [ ] **Step 2: Handle `.reconnecting` in `recordStateChangeEvent`**

Replace:

```swift
    private func recordStateChangeEvent(connectionId: UUID, newState: TunnelState) {
        guard let history else { return }
        switch newState {
        case .running:
            history.recordEvent(connectionId: connectionId, kind: .started)
        case .stopped:
            history.recordEvent(connectionId: connectionId, kind: .stopped)
        case .failed(let msg):
            history.recordEvent(connectionId: connectionId, kind: .failed, message: msg)
        }
    }
```

with:

```swift
    private func recordStateChangeEvent(connectionId: UUID, newState: TunnelState) {
        guard let history else { return }
        switch newState {
        case .running:
            history.recordEvent(connectionId: connectionId, kind: .started)
        case .stopped:
            history.recordEvent(connectionId: connectionId, kind: .stopped)
        case .failed(let msg):
            history.recordEvent(connectionId: connectionId, kind: .failed, message: msg)
        case .reconnecting:
            // Transient state — the surrounding .failed events already record
            // each death; .reconnecting itself doesn't go into history.
            break
        }
    }
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 5: UI — state-aware buttons and reconnect countdown

**Files:**
- Modify: `Sources/SSHManager/UI/ConnectionListView.swift`

- [ ] **Step 1: Wire `onRetryNow` through from the parent**

In `Sources/SSHManager/UI/ConnectionListView.swift`, find the `ConnectionRow(...)` call inside the `ForEach`:

```swift
                        ConnectionRow(
                            connection: c,
                            state: supervisor.state(for: c.id),
                            counters: supervisor.stats[c.id] ?? ByteCounters(),
                            ping: supervisor.pings[c.id],
                            onToggle: { supervisor.toggle(id: c.id) },
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

Replace with:

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

- [ ] **Step 2: Update `ConnectionRow` property block**

Find the property block of `ConnectionRow`:

```swift
private struct ConnectionRow: View {
    let connection: Connection
    let state: TunnelState
    let counters: ByteCounters
    let ping: PingResult?
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onShowStats: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
```

Replace with:

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

    @State private var confirmingDelete = false
```

- [ ] **Step 3: Replace the failure caption with a state-aware status block**

Find this block inside `ConnectionRow.body`:

```swift
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? "(unnamed)" : connection.name)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let msg) = state {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onShowStats() }
            .help("Click for stats")
```

Replace with:

```swift
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? "(unnamed)" : connection.name)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusLine
            }
            .contentShape(Rectangle())
            .onTapGesture { onShowStats() }
            .help("Click for stats")
```

- [ ] **Step 4: Add the `statusLine` view**

Inside `ConnectionRow`, add this computed view just before `private var subtitle: String`:

```swift
    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .failed(let msg):
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .reconnecting(let attempt, let nextRetryAt, let lastError):
            VStack(alignment: .leading, spacing: 1) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = max(0, Int(nextRetryAt.timeIntervalSince(ctx.date).rounded(.up)))
                    Text("Reconnecting (attempt \(attempt), retry in \(secs)s)")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text("last: \(lastError)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .stopped, .running:
            EmptyView()
        }
    }
```

- [ ] **Step 5: Replace the single Start/Stop button with a state-aware view**

Find this block inside `ConnectionRow.body`:

```swift
            Button(state.isRunning ? "Stop" : "Start") { onToggle() }
                .frame(minWidth: 60)
```

Replace with:

```swift
            actionButtons
```

Then add this computed view to `ConnectionRow`, placed right before `statusLine`:

```swift
    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .running:
            Button("Stop") { onToggle() }
                .frame(minWidth: 60)
        case .stopped, .failed:
            Button("Start") { onToggle() }
                .frame(minWidth: 60)
        case .reconnecting:
            HStack(spacing: 4) {
                Button("Retry now") { onRetryNow() }
                Button("Stop") { onToggle() }
            }
        }
    }
```

- [ ] **Step 6: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 6: Smoke test

This task has no code — it just verifies the previous tasks by hand. Auto-reconnect is hard to unit-test inside the app (ssh is an external process), so we trigger it by killing the ssh child.

**Files:** None.

- [ ] **Step 1: Build and launch**

Run: `./scripts/build-app.sh && open ./SSHManager.app`

- [ ] **Step 2: Trigger an external death**

In the app, start a connection that has `autoReconnect: true` (the default for new ones, and most of your existing ones based on `config.json`). Confirm the row is green and `.running`.

In a terminal, find the ssh PID and kill it:

```sh
pgrep -af 'ssh.*BatchMode=yes' | head -5
# pick one matching the connection you just started
kill <pid>
```

- [ ] **Step 3: Observe `.reconnecting`**

Expected within ~2 seconds:
- Row turns yellow.
- Status caption shows `Reconnecting (attempt 1, retry in Ns)` with N ticking down.
- Second caption shows `last: ssh exited with code 255` (or similar).
- Buttons change to `Retry now` and `Stop`.

After the countdown reaches 0 the row should briefly stay yellow then either return to green (`.running`) if the bastion is reachable, or move to attempt 2 with delay 5s.

- [ ] **Step 4: Check history events**

```sh
sqlite3 ~/Library/Application\ Support/SSHManager/history.db \
  'SELECT datetime(ts,"unixepoch","localtime"), kind, message FROM events ORDER BY ts DESC LIMIT 6;'
```

Expected: a `failed` event for each ssh death and a `started` event when reconnect succeeded. No `reconnecting` rows (the state is transient by design).

- [ ] **Step 5: Test the `Retry now` button**

While a connection is in `.reconnecting` (kill the ssh again if needed), click `Retry now`. Expected: countdown disappears, an immediate `start()` runs, state moves to `.running` (or to attempt+1 if it fails again — note the attempt counter does NOT reset, by design).

- [ ] **Step 6: Test the `Stop` button during reconnect**

Kill the ssh again to get back into `.reconnecting`. Click `Stop`. Expected: row turns gray (`.stopped`), buttons revert to a single `Start`. No further retries.

- [ ] **Step 7: Test the success-uptime reset**

Start a connection, let it run for at least 35 seconds (so the 30s uptime timer has fired and reset `currentAttempt`). Then kill ssh. Expected: state moves to `.reconnecting(attempt: 1, ...)` — i.e. the counter started fresh, not from wherever it had drifted in earlier rounds of the same session.

- [ ] **Step 8: Test the `autoReconnect: false` path**

Edit `config.json` to set `"autoReconnect": false` for one connection (or use the Edit sheet). Restart the app for the change to take effect (the supervisor recreates engines on update — but a config-file edit needs Reload Config from the menu). Start the connection; kill its ssh. Expected: row goes straight to red `.failed`, no `.reconnecting` state.

If any of these checks fail, fix before moving on to Task 7.

---

## Task 7: Bump version + rebuild .pkg

**Files:** None (just plist + scripts).

- [ ] **Step 1: Bump the patch version**

Run:
```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.0' Resources/Info.plist
```

- [ ] **Step 2: Build the .pkg**

Run: `./scripts/build-pkg.sh`
Expected: `Built: SSHManager-0.3.0.pkg`.

---

## Self-Review Notes

- **Spec coverage:**
  - New `.reconnecting` state — Task 1.
  - Backoff schedule + cap + max attempts — Task 2, Step 5.
  - `currentAttempt` preserved across retries, reset on manual start — Task 2, Step 2.
  - Success uptime timer (30s ⇒ counter reset) — Task 2, Step 5 (`armSuccessUptimeTimer`).
  - Synchronous start failures (plan / proxy bind / process launch) route through the scheduler — Task 2, Step 3.
  - `handleProxyFailure` retries — Task 2, Step 6.
  - `stop()` cancels timer + lands in `.stopped` from `.reconnecting` — Task 3, Step 1.
  - `retryNow()` preserves attempt — Task 3, Step 2.
  - Supervisor `retryNow(id:)` — Task 4, Step 1.
  - `.reconnecting` not written to history — Task 4, Step 2.
  - Yellow status dot — Task 1, Step 3.
  - "Retry now" + "Stop" during `.reconnecting` — Task 5, Step 5.
  - Live countdown via `TimelineView` — Task 5, Step 4.
  - Menu glyph `↻` — Task 1, Step 2.

- **Placeholders:** none — every step has either exact code or an exact command.

- **Type consistency:** `TunnelState.reconnecting(attempt:nextRetryAt:lastError:)` named the same way in every site that constructs or pattern-matches it. `scheduleRetryOrGiveUp(reason:)`, `armSuccessUptimeTimer()`, `retryNow()` consistent across tasks. `onRetryNow` callback name consistent between parent and `ConnectionRow`.
