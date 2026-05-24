# History & Stats (Phase 4)

Status: approved, ready for implementation plan.
Date: 2026-05-13.

## Goal

Persist per-connection history (RTT samples, byte deltas, state-change events)
to SQLite and surface it as a stats window opened by clicking a connection row.
Graphs overlay state events on top of metric lines so the user can correlate
ping spikes with tunnel failures.

## Scope

In:
- SQLite store for 10-second samples (ping, byte deltas) and discrete events.
- Stats sheet with ping line chart, throughput area chart, state-band strip,
  events list, summary row, time-range picker (1h / 6h / 24h / 7d / 30d).
- 90-day retention with daily purge at app launch.

Out (later phases):
- Auto-reconnect (phase 5) — `failed` events recorded, but no recovery logic.
- CSV export.
- Multi-connection overlay graphs.
- Graphs in the menubar dropdown.

## Architecture

New module `History/`:

```
Sources/SSHManager/
  History/
    Database.swift      — thin sqlite3 C API wrapper
    HistoryStore.swift  — domain methods (record/fetch/summary/purge)
  UI/
    StatsView.swift     — sheet with charts and events list
```

No new SwiftPM dependencies. `libsqlite3` is a system library; Swift Charts is
built into the SDK on macOS 13+. The project's "zero external SwiftPM deps"
property is preserved.

`TunnelSupervisor` owns the `HistoryStore`. It writes samples on every
`PingMonitor` results update (10s cadence), and writes events from the
existing `TunnelEngine.onStateChange` callback. A daily-equivalent purge runs
once at supervisor init.

## Storage

Path: `~/Library/Application Support/SSHManager/history.db`
(beside `config.json`).

Mode: WAL, foreign_keys off (no FKs needed). Single serial dispatch queue
`ssh-manager.history` owns the `sqlite3*` handle — all reads and writes go
through it.

### Schema

```sql
CREATE TABLE samples (
  connection_id TEXT NOT NULL,
  ts            INTEGER NOT NULL,   -- unix epoch, seconds
  ping_ms       REAL,                -- NULL when probe timed out / no data
  up_delta      INTEGER NOT NULL,    -- bytes since previous sample
  down_delta    INTEGER NOT NULL
);
CREATE INDEX idx_samples_conn_ts ON samples(connection_id, ts);

CREATE TABLE events (
  connection_id TEXT NOT NULL,
  ts            INTEGER NOT NULL,
  kind          TEXT NOT NULL,       -- 'started' | 'stopped' | 'failed'
  message       TEXT                 -- text for 'failed', NULL otherwise
);
CREATE INDEX idx_events_conn_ts ON events(connection_id, ts);
```

### Design notes

- **`connection_id` is a free-standing UUID string, not an FK to config.** If
  a connection is deleted from config, its history remains queryable. Restoring
  a connection with the same UUID re-attaches the history. This is the simplest
  decoupling and matches how logs are already keyed.
- **Deltas, not absolute counters.** Throughput on the chart is `delta /
  interval`. Restarting the app resets engine counters to zero; storing deltas
  means the first sample after restart is small or zero rather than a giant
  negative jump.
- **Sample when engine is stopped.** Ping is still measured (the bastion is
  still pingable), so we INSERT `up_delta=0, down_delta=0` with the real
  ping. On the chart this shows up as "down but reachable" — useful signal.

## Data flow

### Write path

- Supervisor subscribes to `PingMonitor.$results` (already does, for the row
  badge). On each emission, in the same `sink` closure, the supervisor also:
  1. For each connection: read current `ByteCounters` from its engine,
     subtract the previous snapshot stored in
     `private var lastByteSnapshot: [UUID: ByteCounters]` → up/down deltas.
  2. Read `pings[id]?.rttMs`.
  3. INSERT one `samples` row.
  4. Update `lastByteSnapshot[id]` to the current value.
- `TunnelEngine.onStateChange` is already wired. The supervisor's callback
  inspects the new state and INSERTs an `events` row (`started` / `stopped` /
  `failed(message)`).

No new timers. The 0.5s `statsTimer` keeps doing what it does (live byte
counters on the main row); it does NOT touch the database.

### Retention

`HistoryStore.purgeOlderThan(seconds:)` runs once during supervisor init with
a 90-day cutoff. For a menubar app that's typically up for days at a time,
once-per-launch is enough — no separate cleanup timer.

### Read path

`HistoryStore` exposes:

```swift
func fetchSamples(connectionId: UUID, from: Date, to: Date) -> [Sample]
func fetchEvents(connectionId: UUID, from: Date, to: Date) -> [Event]
func summary(connectionId: UUID, from: Date, to: Date) -> Summary
```

`Summary` contains uptime fraction, fail count, average ping (excluding
timeouts), total up bytes, total down bytes — computed in one aggregating SQL
query.

Uptime is computed from `events`: walk events in range, sum durations between
`started` and the next `stopped|failed`; clip to the [from, to] window.

## UI

### Trigger

Clicking the **left part** of a connection row (the name/subtitle VStack)
opens the stats sheet for that connection. The Start/Stop, Edit and trash
buttons are unaffected — they capture their own taps because they're
`Button`s. Putting `onTapGesture` on the whole row would conflict with the
buttons, so the gesture is scoped to the text VStack.

`ConnectionListView` gains:

```swift
@State private var statsFor: Connection?
.sheet(item: $statsFor) { c in
    StatsView(connection: c, history: supervisor.history)
}
```

### StatsView layout

Sheet size ~720×560, resizable.

Header row: connection name, subtitle (`user@host:port · type :port`), Close
button.

Range picker: segmented `Picker` with `1h / 6h / 24h / 7d / 30d`. 24h is the
default selection. Changing range re-queries `fetchSamples` /
`fetchEvents` / `summary`.

Summary row: `Uptime <pct>%  ·  Fails <n>  ·  Avg ping <ms> ms` on one line,
`↑ <bytes>  ·  ↓ <bytes>` on the next.

Three stacked charts, sharing the X-axis (the chosen range):

1. **Ping (ms)** — Swift Charts `LineMark` over time. Timeouts (`ping_ms IS
   NULL`) become small red `PointMark`s at y=0 to make them visible without
   breaking the line. `RuleMark` verticals overlay each `failed` event in
   range so a ping spike → fail correlation is visible.
2. **Throughput (B/s)** — Stacked `AreaMark`s for up and down (delta divided
   by sample interval). Same vertical event rules.
3. **State band** — Not a Chart. A custom `Canvas` strip the same width as
   the charts, segmented by `events`: green for running, gray for stopped,
   red for failed. Lighter weight than a Chart and lines up pixel-perfect.

Events list at the bottom: scrollable, newest first, timestamp + kind +
message. Limited to the same time range.

### Live updates while sheet is open

The view subscribes to `supervisor.objectWillChange` (it's an
`ObservableObject` available in environment / passed in). On each tick after
the supervisor writes a new sample, the view refetches the current range and
re-renders. To keep the chart from flickering, the fetch produces stable
identity arrays keyed by `ts`.

## Files to create

- `Sources/SSHManager/History/Database.swift`
- `Sources/SSHManager/History/HistoryStore.swift`
- `Sources/SSHManager/UI/StatsView.swift`

## Files to modify

- `Package.swift` — add `linkerSettings: [.linkedLibrary("sqlite3")]` to the
  `SSHManager` target.
- `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` — own `HistoryStore`,
  maintain `lastByteSnapshot`, write samples in the ping sink, write events
  in the existing state-change callback, expose `history` for the UI, call
  `purgeOlderThan` once at init.
- `Sources/SSHManager/UI/ConnectionListView.swift` — add `statsFor` state,
  scope `onTapGesture` to the name VStack, present the sheet.

## Files not touched

- `TunnelEngine` — `onStateChange` already exists, no change needed.
- `PingMonitor`, `ProxyServer` — unchanged.
- `Connection`, `ConfigStore`, `ConnectionEditView` — unchanged.

## Open implementation questions

None. All decisions taken during brainstorming. Plan can proceed.
