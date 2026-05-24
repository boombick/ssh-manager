# Auto-Reconnect (Phase 5)

Status: approved, ready for implementation plan.
Date: 2026-05-14.

## Goal

When a tunnel's ssh child dies on its own (not via user-initiated Stop),
automatically try to bring it back up with exponential backoff, capped on both
delay and attempt count. Surface the retry state in the connection row so the
user knows the tunnel is being held up rather than silently broken.

## Scope

In:
- New `.reconnecting(attempt, nextRetryAt, lastError)` state on
  `TunnelEngine`.
- Backoff schedule and attempt cap.
- Manual override: "Retry now" bypasses the timer, "Stop" cancels reconnect
  entirely.
- History event recording stays the way it is for `failed` and `started` — no
  new event kinds.
- Per-connection `autoReconnect` flag (already exists on `Connection`)
  controls whether the loop runs.

Out:
- Network reachability gating (the backoff already handles "host is down" by
  spacing retries).
- Per-connection backoff customisation (no UI for it, schedule is hard-coded).
- A "give up forever" persistent flag — when we hit the attempt cap we land in
  `.failed`, and the user re-arms by clicking Start.

## State machine

```
enum TunnelState: Equatable {
    case stopped
    case running
    case reconnecting(attempt: Int, nextRetryAt: Date, lastError: String)
    case failed(String)
}
```

`isRunning` is true only for `.running`. The status-dot colours map as:

- `.stopped`      → secondary (gray)
- `.running`      → green
- `.reconnecting` → yellow
- `.failed`       → red

### Transitions

| From                  | Trigger                                     | To                                                |
|-----------------------|---------------------------------------------|---------------------------------------------------|
| `.stopped`/`.failed`  | user clicks Start                           | `.running` (or `.failed` if start fails)          |
| `.running`            | ssh exits AND `autoReconnect` AND not manualStop AND attempt < cap | `.reconnecting(attempt: 1, ...)`         |
| `.running`            | ssh exits, `autoReconnect` off              | `.failed(reason)`                                 |
| `.running`            | user clicks Stop                            | `.stopped`                                        |
| `.reconnecting`       | retry timer fires → `start()` succeeds      | `.running`                                        |
| `.reconnecting`       | retry timer fires → `start()` fails synchronously, OR ssh exits quickly after timer fired | `.reconnecting(attempt: n+1, ...)` (or `.failed` if cap hit) |
| `.reconnecting`       | user clicks Retry now                       | immediate `start()` attempt — same as timer firing, but with `attempt` unchanged |
| `.reconnecting`       | user clicks Stop                            | `.stopped`                                        |
| `.running`            | held `.running` for ≥30s                    | (stays `.running`) — successUptimeTimer fires, resets `attempt` counter to 0 |

The successUptimeTimer is a one-shot. It is scheduled when state enters
`.running` and cancelled when state leaves `.running`. If it fires, the engine
zeros its `attempt` counter so the next failure starts the backoff schedule
from the top.

## Backoff schedule

Hard-coded delay table:

```
attempt 1 → 2s
attempt 2 → 5s
attempt 3 → 10s
attempt 4 → 20s
attempt 5 → 30s
attempt ≥ 6 → 60s
```

Cap: `maxAttempts = 20`. When attempt would become 21 we don't schedule a new
timer — we transition to
`.failed("Gave up after 20 reconnect attempts: <lastError>")`.

Rationale: the schedule rises fast enough that an auth-broken tunnel stops
making 6+ attempts per minute within the first ~80 seconds; the cap of 20 at
60s spacing gives the system about 17 minutes to keep trying before giving
up. The user always has Start to rearm.

## History recording

No new event kinds.

- Each death of an ssh child writes a `failed` event with the exit reason.
  This includes every failing retry — so the events list reads as
  `failed, failed, failed, started` when the third retry finally took.
- Each successful entry into `.running` writes a `started` event.
- The `.reconnecting` state itself is NOT written to history. It's transient
  scaffolding around the `failed` event that's already there.
- The "gave up" transition writes a `failed` event with the "Gave up after N
  attempts" message — same kind as other failures; it's just the final one.

The `lastByteSnapshot` reset that happens implicitly when the engine restarts
its counters is fine — every restart already resets `_bytesUp`/`_bytesDown`
to zero in `resetStats()`, and `writeHistorySamples` already handles the wrap
case (`current < prev` → emit `current` as the delta).

## UI

### ConnectionRow status text

```
● running             →  (no extra status text)
● stopped             →  (no extra status text)
● failed              →  red caption line with message (unchanged)
● reconnecting        →  caption line:
                         "Reconnecting (attempt 3, retry in 7s)"
                         + smaller caption2: "last: ssh exited with code 255"
```

The "retry in Ns" countdown is updated locally by wrapping the status-text
view in `TimelineView(.periodic(from: .now, by: 1))`. No new supervisor
timer.

### ConnectionRow buttons

| State            | Buttons shown                       |
|------------------|-------------------------------------|
| `.stopped`       | `Start`                             |
| `.failed`        | `Start`                             |
| `.running`       | `Stop`                              |
| `.reconnecting`  | `Retry now` + `Stop`                |

"Retry now": cancel the pending retry timer and call `start()` immediately.
Does NOT reset `attempt` — if it fails again the next backoff uses
`attempt+1`. (Otherwise you could spam Retry now to bypass backoff forever.)

"Stop" during reconnect: cancel timer, set `manuallyStopped = true`, transition
to `.stopped`.

Wiring: the existing single `Button(state.isRunning ? "Stop" : "Start")` is
replaced by a small `@ViewBuilder` that switches on state and emits one or
two buttons.

## TunnelEngine changes

New private fields:

```swift
private var retryTimer: DispatchSourceTimer?
private var successUptimeTimer: DispatchSourceTimer?
private var currentAttempt: Int = 0
```

New constants:

```swift
private static let backoffSchedule: [TimeInterval] = [2, 5, 10, 20, 30, 60]
private static let maxAttempts: Int = 20
private static let successUptimeThreshold: TimeInterval = 30
```

`handleTermination(exitCode:)` becomes the decision point. Pseudocode:

```
proxy.stop(); proxy = nil; process = nil; close uptime timer.

if manuallyStopped:
    state = .stopped
    return
write "ssh exited with code X" to log
let reason = "ssh exited with code X"

if !connection.autoReconnect:
    state = .failed(reason)
    closeLog()
    return

if currentAttempt + 1 > maxAttempts:
    state = .failed("Gave up after \(maxAttempts) reconnect attempts: \(reason)")
    closeLog()
    return

let nextAttempt = currentAttempt + 1
let delay = backoffSchedule[min(nextAttempt - 1, backoffSchedule.count - 1)]
let nextAt = Date().addingTimeInterval(delay)
state = .reconnecting(attempt: nextAttempt, nextRetryAt: nextAt, lastError: reason)
closeLog()
scheduleRetry(after: delay, attempt: nextAttempt)
```

`scheduleRetry` creates a DispatchSourceTimer on a dedicated serial queue (or
on `DispatchQueue.main` — fine since work is light) that fires once. On fire
it sets `currentAttempt = attempt` and calls `start()`.

`start()` itself doesn't need to know about the attempt counter — it just
brings up proxy + ssh as today. The engine fields `currentAttempt` and
`retryTimer` are owned outside the `start()` flow.

When `start()` succeeds and state becomes `.running`, schedule the
`successUptimeTimer` for `successUptimeThreshold` seconds. Its handler resets
`currentAttempt = 0`. When state leaves `.running` (any transition) the
timer is cancelled.

`stop()` becomes:

```
if let t = retryTimer { t.cancel(); retryTimer = nil }
if case .reconnecting = state {
    state = .stopped
    return
}
// existing behaviour for .running:
manuallyStopped = true
process?.terminate()
```

A new `retryNow()` method on the engine:

```
guard case .reconnecting(let attempt, _, _) = state else { return }
retryTimer?.cancel(); retryTimer = nil
currentAttempt = attempt
start()
```

Supervisor exposes `retryNow(id:)` mirroring `toggle(id:)`.

## TunnelSupervisor changes

- `toggle(id:)` already handles Stop and Start. During `.reconnecting`,
  toggling Start would hit the `start()` path — but `start()` guards on
  `process == nil` and will work correctly, so `toggle` doesn't need to
  change. The UI doesn't call `toggle` during `.reconnecting` though; it
  calls `retryNow` or `stop` explicitly via two distinct buttons.
- Expose:
  ```swift
  func retryNow(id: UUID) { engines[id]?.retryNow() }
  ```
- The existing `onStateChange` hook records `started`/`failed` events. With
  the new `.reconnecting` state we record nothing (per spec) — add a `case
  .reconnecting:` that falls through to no-op.

## File changes

**Modify only — no new files:**

- `Sources/SSHManager/Tunnel/TunnelEngine.swift`
  - Extend `TunnelState`.
  - Add timer fields, attempt counter, schedule constants.
  - Reshape `handleTermination`, `stop`, plus new `retryNow`,
    `scheduleRetry`, `scheduleSuccessUptimeReset`.
  - Reset `currentAttempt` to the captured value before each retry `start()`.
  - On `state` didSet: if leaving `.running`, cancel successUptimeTimer; if
    leaving `.reconnecting`, cancel retryTimer. (Belt-and-braces; explicit
    cancels in stop/retryNow already do the work but didSet keeps the
    invariant honest.)

- `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`
  - Add `func retryNow(id: UUID)`.
  - Extend `recordStateChangeEvent` switch with `case .reconnecting: break`.

- `Sources/SSHManager/UI/ConnectionListView.swift`
  - Replace the single Start/Stop button with a `@ViewBuilder` returning one
    or two buttons depending on state.
  - Replace the existing "failed" caption with a state-aware status block
    using `TimelineView` for the countdown.
  - Pass an `onRetryNow` callback into `ConnectionRow` from the parent.

**Not touched:** `Connection`, `Paths`, `ConfigStore`, `PingMonitor`,
`HistoryStore`, `Database`, `StatsView`, `ProxyServer`, `MenuBarController`,
`AppDelegate`, `MainWindowController`.

## Edge cases handled

- **User edits a reconnecting connection.** `updateConnection` already stops
  the old engine and installs a fresh one. `stop()` cancels retryTimer.
  Fresh engine has `currentAttempt = 0`.
- **User deletes a reconnecting connection.** Same path — `stop()` cancels.
- **User clicks Retry now twice fast.** First click cancels timer and calls
  `start()`. Second click finds state != `.reconnecting` (it's now `.running`
  or briefly transitioning), guard returns. No-op.
- **Proxy bind fails on a retry.** `start()` sets `.failed(...)` directly
  without going through `handleTermination` (since no ssh process started).
  That looks like a "real" failure now, not a retry. Fix: at the end of
  `start()`, if `state` is `.failed` and `autoReconnect` is true, route
  through the same retry-scheduling logic as `handleTermination`. Concretely:
  extract the "schedule next retry or give up" block into a private helper
  `scheduleRetryOrGiveUp(reason:)` and call it from both places.
- **App quits during retry wait.** `deinit`/normal exit lets timers go away.
  We don't persist retry state.

## Open implementation questions

None.
