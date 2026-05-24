# History & Stats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-connection ping/byte samples and state-change events to SQLite, and expose them in a stats sheet (3 stacked Swift Charts + events list) opened by clicking a connection row.

**Architecture:** A new `History/` module holds a thin `Database` wrapper around the system sqlite3 C API and a `HistoryStore` with the domain queries. `TunnelSupervisor` writes one sample per ~10s tick (driven off the existing PingMonitor publisher) and writes events from the existing `TunnelEngine.onStateChange` hook. A new `StatsView` sheet renders the data using Swift Charts (built-in on macOS 13+).

**Tech Stack:** Swift 6.0 / SwiftPM (no new deps), libsqlite3 (system, linked via `linkerSettings`), Swift Charts, SwiftUI, Combine.

**Conventions for this plan:**
- This project is **not a git repo** — "commit" steps become "checkpoint: `swift build` must succeed".
- This project has **no test target**. Verification at each task end is a mix of `swift build`, `sqlite3` CLI inspection of `~/Library/Application Support/SSHManager/history.db`, and manual smoke through the app.
- Reference spec: `docs/superpowers/specs/2026-05-13-history-and-stats-design.md`.

---

## File Structure

**Create:**
- `Sources/SSHManager/History/Database.swift` — sqlite3 C-API wrapper. Owns the `OpaquePointer` to the DB connection. Exposes `exec`, `prepare`, `runStatement`, `withRows`. ~150 lines.
- `Sources/SSHManager/History/HistoryStore.swift` — domain API: `recordSample`, `recordEvent`, `fetchSamples`, `fetchEvents`, `summary`, `purgeOlderThan`. ~200 lines.
- `Sources/SSHManager/UI/StatsView.swift` — sheet with header, range picker, summary, three charts, events list. ~300 lines.

**Modify:**
- `Package.swift` — link libsqlite3.
- `Sources/SSHManager/Storage/Paths.swift` — add `historyFile` URL.
- `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` — own `HistoryStore`; track `lastByteSnapshot`; on each ping sink emission write a sample row; on each engine state-change write an event row; purge once at init; expose `history` to UI.
- `Sources/SSHManager/UI/ConnectionListView.swift` — `@State var statsFor: Connection?`, scope `onTapGesture` to the left text VStack, `.sheet(item:)` presenting `StatsView`.

**Not touched:** `TunnelEngine`, `PingMonitor`, `ProxyServer`, `Connection`, `ConfigStore`, `ConnectionEditView`, `MenuBarController`, `AppDelegate`, `MainWindowController`.

---

## Task 1: Link libsqlite3 and add history.db path

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/SSHManager/Storage/Paths.swift`

- [ ] **Step 1: Add linker setting for libsqlite3**

In `Package.swift`, modify the target to add `linkerSettings`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SSHManager",
            path: "Sources/SSHManager",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
```

- [ ] **Step 2: Add the history.db path to Paths**

In `Sources/SSHManager/Storage/Paths.swift`, add after `logFile(for:)`:

```swift
    static var historyFile: URL {
        supportDirectory.appendingPathComponent("history.db")
    }
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: `Build complete!` with no errors. The new linker setting takes effect even though nothing yet calls sqlite3.

---

## Task 2: Database wrapper

**Files:**
- Create: `Sources/SSHManager/History/Database.swift`

- [ ] **Step 1: Create the History directory and write Database.swift**

Create `Sources/SSHManager/History/Database.swift`:

```swift
import Foundation
import SQLite3

/// Thin wrapper around a single sqlite3 connection.
///
/// Threading: a `Database` instance is NOT thread-safe. Callers should funnel all
/// access through one serial queue (HistoryStore does this).
final class Database {

    enum DBError: LocalizedError {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        var errorDescription: String? {
            switch self {
            case .open(let msg):              return "sqlite open failed: \(msg)"
            case .prepare(let msg, let sql):  return "sqlite prepare failed (\(msg)) for: \(sql)"
            case .step(let msg, let sql):     return "sqlite step failed (\(msg)) for: \(sql)"
            }
        }
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        var h: OpaquePointer?
        // SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX is the default for sqlite3_open_v2 with these flags.
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let h { sqlite3_close(h) }
            throw DBError.open(msg)
        }
        self.handle = h

        // WAL = readers don't block the writer, and a single writer doesn't block readers.
        // Cheap durability tradeoff for our use case (occasional sample writes).
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// Run a statement that returns no rows (CREATE, INSERT, DELETE, PRAGMA).
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(err)
            throw DBError.step(msg, sql: sql)
        }
    }

    /// Run a parameterised statement that returns no rows.
    /// `bind` is called with a Statement; the caller binds positional parameters by index.
    func run(_ sql: String, bind: (Statement) throws -> Void = { _ in }) throws {
        let stmt = try Statement(db: self, sql: sql)
        try bind(stmt)
        try stmt.step()
    }

    /// Run a SELECT and iterate rows.
    /// `bind` binds parameters; `row` is invoked once per row with the same Statement.
    func query(
        _ sql: String,
        bind: (Statement) throws -> Void = { _ in },
        row: (Statement) throws -> Void
    ) throws {
        let stmt = try Statement(db: self, sql: sql)
        try bind(stmt)
        while try stmt.stepRow() {
            try row(stmt)
        }
    }

    fileprivate var rawHandle: OpaquePointer? { handle }

    fileprivate func errmsg() -> String {
        if let handle { return String(cString: sqlite3_errmsg(handle)) }
        return "no handle"
    }
}

/// Auto-finalizing prepared statement.
final class Statement {
    private let db: Database
    private let sql: String
    private var stmt: OpaquePointer?

    fileprivate init(db: Database, sql: String) throws {
        self.db = db
        self.sql = sql
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.rawHandle, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else {
            throw Database.DBError.prepare(db.errmsg(), sql: sql)
        }
        self.stmt = s
    }

    deinit {
        if let stmt { sqlite3_finalize(stmt) }
    }

    // Use SQLITE_TRANSIENT so sqlite copies the string/blob and we don't have to
    // keep the Swift value alive across the step.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Statement.SQLITE_TRANSIENT)
    }
    func bind(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }
    func bind(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }
    func bindNull(_ index: Int32) {
        sqlite3_bind_null(stmt, index)
    }
    func bind(_ index: Int32, _ value: Double?) {
        if let value { bind(index, value) } else { bindNull(index) }
    }

    func column(int64 index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }
    func column(double index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }
    func column(doubleOrNil index: Int32) -> Double? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, index)
    }
    func column(text index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
    func column(textOrNil index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return column(text: index)
    }

    /// For INSERT / UPDATE / DELETE / CREATE — expects SQLITE_DONE.
    func step() throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw Database.DBError.step(db.errmsg(), sql: sql)
        }
    }

    /// For SELECT — returns true if a row is available.
    func stepRow() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default:          throw Database.DBError.step(db.errmsg(), sql: sql)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: `Build complete!`. The `import SQLite3` resolves because we linked libsqlite3 in Task 1.

---

## Task 3: HistoryStore — schema, record/fetch/summary/purge

**Files:**
- Create: `Sources/SSHManager/History/HistoryStore.swift`

- [ ] **Step 1: Write HistoryStore.swift**

Create `Sources/SSHManager/History/HistoryStore.swift`:

```swift
import Foundation

struct Sample: Equatable {
    let ts: Date
    let pingMs: Double?
    let upDelta: UInt64
    let downDelta: UInt64
}

struct StateEvent: Equatable, Identifiable {
    enum Kind: String {
        case started, stopped, failed
    }
    let id: Int64
    let ts: Date
    let kind: Kind
    let message: String?
}

struct StatsSummary: Equatable {
    let uptimeFraction: Double   // 0...1 of the time window
    let failCount: Int
    let avgPingMs: Double?       // nil if no successful probes
    let totalUp: UInt64
    let totalDown: UInt64
}

/// Domain access over a single SQLite file. All work is funneled through `queue`
/// so the underlying `Database` instance never sees concurrent calls.
final class HistoryStore {

    private let db: Database
    private let queue = DispatchQueue(label: "ssh-manager.history")

    init(url: URL) throws {
        self.db = try Database(url: url)
        try createSchemaIfNeeded()
    }

    // MARK: - Schema

    private func createSchemaIfNeeded() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS samples (
              connection_id TEXT NOT NULL,
              ts            INTEGER NOT NULL,
              ping_ms       REAL,
              up_delta      INTEGER NOT NULL,
              down_delta    INTEGER NOT NULL
            );
        """)
        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_samples_conn_ts
            ON samples(connection_id, ts);
        """)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS events (
              id            INTEGER PRIMARY KEY AUTOINCREMENT,
              connection_id TEXT NOT NULL,
              ts            INTEGER NOT NULL,
              kind          TEXT NOT NULL,
              message       TEXT
            );
        """)
        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_events_conn_ts
            ON events(connection_id, ts);
        """)
    }

    // MARK: - Writes

    func recordSample(
        connectionId: UUID,
        ts: Date = Date(),
        pingMs: Double?,
        upDelta: UInt64,
        downDelta: UInt64
    ) {
        let id = connectionId.uuidString
        let tsInt = Int64(ts.timeIntervalSince1970)
        queue.async { [db] in
            do {
                try db.run("""
                    INSERT INTO samples (connection_id, ts, ping_ms, up_delta, down_delta)
                    VALUES (?, ?, ?, ?, ?);
                """) { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, tsInt)
                    stmt.bind(3, pingMs)
                    stmt.bind(4, Int64(min(upDelta, UInt64(Int64.max))))
                    stmt.bind(5, Int64(min(downDelta, UInt64(Int64.max))))
                }
            } catch {
                NSLog("SSHManager: history sample write failed: \(error)")
            }
        }
    }

    func recordEvent(
        connectionId: UUID,
        ts: Date = Date(),
        kind: StateEvent.Kind,
        message: String? = nil
    ) {
        let id = connectionId.uuidString
        let tsInt = Int64(ts.timeIntervalSince1970)
        let kindStr = kind.rawValue
        queue.async { [db] in
            do {
                try db.run("""
                    INSERT INTO events (connection_id, ts, kind, message)
                    VALUES (?, ?, ?, ?);
                """) { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, tsInt)
                    stmt.bind(3, kindStr)
                    if let message { stmt.bind(4, message) } else { stmt.bindNull(4) }
                }
            } catch {
                NSLog("SSHManager: history event write failed: \(error)")
            }
        }
    }

    // MARK: - Reads (synchronous on `queue`)

    func fetchSamples(connectionId: UUID, from: Date, to: Date) -> [Sample] {
        let id = connectionId.uuidString
        let fromTs = Int64(from.timeIntervalSince1970)
        let toTs = Int64(to.timeIntervalSince1970)
        var out: [Sample] = []
        queue.sync { [db] in
            do {
                try db.query("""
                    SELECT ts, ping_ms, up_delta, down_delta
                    FROM samples
                    WHERE connection_id = ? AND ts >= ? AND ts <= ?
                    ORDER BY ts ASC;
                """, bind: { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, fromTs)
                    stmt.bind(3, toTs)
                }, row: { stmt in
                    let ts = Date(timeIntervalSince1970: TimeInterval(stmt.column(int64: 0)))
                    let ping = stmt.column(doubleOrNil: 1)
                    let up = UInt64(max(0, stmt.column(int64: 2)))
                    let down = UInt64(max(0, stmt.column(int64: 3)))
                    out.append(Sample(ts: ts, pingMs: ping, upDelta: up, downDelta: down))
                })
            } catch {
                NSLog("SSHManager: history sample fetch failed: \(error)")
            }
        }
        return out
    }

    func fetchEvents(connectionId: UUID, from: Date, to: Date) -> [StateEvent] {
        let id = connectionId.uuidString
        let fromTs = Int64(from.timeIntervalSince1970)
        let toTs = Int64(to.timeIntervalSince1970)
        var out: [StateEvent] = []
        queue.sync { [db] in
            do {
                try db.query("""
                    SELECT id, ts, kind, message
                    FROM events
                    WHERE connection_id = ? AND ts >= ? AND ts <= ?
                    ORDER BY ts ASC;
                """, bind: { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, fromTs)
                    stmt.bind(3, toTs)
                }, row: { stmt in
                    let evId = stmt.column(int64: 0)
                    let ts = Date(timeIntervalSince1970: TimeInterval(stmt.column(int64: 1)))
                    let kindStr = stmt.column(text: 2)
                    let kind = StateEvent.Kind(rawValue: kindStr) ?? .stopped
                    let msg = stmt.column(textOrNil: 3)
                    out.append(StateEvent(id: evId, ts: ts, kind: kind, message: msg))
                })
            } catch {
                NSLog("SSHManager: history event fetch failed: \(error)")
            }
        }
        return out
    }

    /// Most recent event at or before `to`, used to know whether the connection was
    /// running at the start of the visible window.
    func lastEvent(connectionId: UUID, atOrBefore: Date) -> StateEvent? {
        let id = connectionId.uuidString
        let toTs = Int64(atOrBefore.timeIntervalSince1970)
        var out: StateEvent?
        queue.sync { [db] in
            do {
                try db.query("""
                    SELECT id, ts, kind, message
                    FROM events
                    WHERE connection_id = ? AND ts <= ?
                    ORDER BY ts DESC LIMIT 1;
                """, bind: { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, toTs)
                }, row: { stmt in
                    let evId = stmt.column(int64: 0)
                    let ts = Date(timeIntervalSince1970: TimeInterval(stmt.column(int64: 1)))
                    let kindStr = stmt.column(text: 2)
                    let kind = StateEvent.Kind(rawValue: kindStr) ?? .stopped
                    let msg = stmt.column(textOrNil: 3)
                    out = StateEvent(id: evId, ts: ts, kind: kind, message: msg)
                })
            } catch {
                NSLog("SSHManager: lastEvent fetch failed: \(error)")
            }
        }
        return out
    }

    func summary(connectionId: UUID, from: Date, to: Date) -> StatsSummary {
        let id = connectionId.uuidString
        let fromTs = Int64(from.timeIntervalSince1970)
        let toTs = Int64(to.timeIntervalSince1970)
        var failCount = 0
        var avgPing: Double?
        var totalUp: UInt64 = 0
        var totalDown: UInt64 = 0
        queue.sync { [db] in
            do {
                try db.query("""
                    SELECT
                      SUM(CASE WHEN ping_ms IS NOT NULL THEN ping_ms ELSE 0 END) AS sum_ping,
                      SUM(CASE WHEN ping_ms IS NOT NULL THEN 1 ELSE 0 END)       AS n_ping,
                      COALESCE(SUM(up_delta), 0)                                  AS sum_up,
                      COALESCE(SUM(down_delta), 0)                                AS sum_down
                    FROM samples
                    WHERE connection_id = ? AND ts >= ? AND ts <= ?;
                """, bind: { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, fromTs)
                    stmt.bind(3, toTs)
                }, row: { stmt in
                    let sumPing = stmt.column(double: 0)
                    let nPing = stmt.column(int64: 1)
                    if nPing > 0 { avgPing = sumPing / Double(nPing) }
                    totalUp = UInt64(max(0, stmt.column(int64: 2)))
                    totalDown = UInt64(max(0, stmt.column(int64: 3)))
                })
                try db.query("""
                    SELECT COUNT(*) FROM events
                    WHERE connection_id = ? AND kind = 'failed' AND ts >= ? AND ts <= ?;
                """, bind: { stmt in
                    stmt.bind(1, id)
                    stmt.bind(2, fromTs)
                    stmt.bind(3, toTs)
                }, row: { stmt in
                    failCount = Int(stmt.column(int64: 0))
                })
            } catch {
                NSLog("SSHManager: history summary failed: \(error)")
            }
        }
        let uptime = computeUptime(connectionId: connectionId, from: from, to: to)
        return StatsSummary(
            uptimeFraction: uptime,
            failCount: failCount,
            avgPingMs: avgPing,
            totalUp: totalUp,
            totalDown: totalDown
        )
    }

    /// Walk events in [from, to] together with the state immediately before `from`.
    /// Sum the running intervals; clip to the window.
    private func computeUptime(connectionId: UUID, from: Date, to: Date) -> Double {
        let total = to.timeIntervalSince(from)
        guard total > 0 else { return 0 }

        var running = false
        if let last = lastEvent(connectionId: connectionId, atOrBefore: from) {
            running = (last.kind == .started)
        }

        let events = fetchEvents(connectionId: connectionId, from: from, to: to)
        var cursor = from
        var sum: TimeInterval = 0
        for e in events {
            if running {
                sum += max(0, e.ts.timeIntervalSince(cursor))
            }
            cursor = e.ts
            running = (e.kind == .started)
        }
        if running {
            sum += max(0, to.timeIntervalSince(cursor))
        }
        return min(1, sum / total)
    }

    // MARK: - Purge

    func purgeOlderThan(seconds: TimeInterval) {
        let cutoff = Int64(Date().timeIntervalSince1970 - seconds)
        queue.async { [db] in
            do {
                try db.run("DELETE FROM samples WHERE ts < ?;") { stmt in
                    stmt.bind(1, cutoff)
                }
                try db.run("DELETE FROM events WHERE ts < ?;") { stmt in
                    stmt.bind(1, cutoff)
                }
            } catch {
                NSLog("SSHManager: history purge failed: \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: `Build complete!` with no errors.

---

## Task 4: Wire HistoryStore into TunnelSupervisor

**Files:**
- Modify: `Sources/SSHManager/Tunnel/TunnelSupervisor.swift`

- [ ] **Step 1: Add history store, byte snapshot, and ensureSupportDirectory call**

The supervisor currently doesn't ensure the support directory exists (something else does at app init). We need the directory before opening the db. Modify the file as follows:

Replace the property block:

```swift
    private let store: ConfigStore
    @Published private(set) var connections: [Connection]
    @Published private(set) var stats: [UUID: ByteCounters] = [:]
    @Published private(set) var pings: [UUID: PingResult] = [:]
    private var engines: [UUID: TunnelEngine] = [:]
    private var statsTimer: Timer?
    private let pingMonitor = PingMonitor()
    private var pingCancellable: AnyCancellable?
```

with:

```swift
    private let store: ConfigStore
    @Published private(set) var connections: [Connection]
    @Published private(set) var stats: [UUID: ByteCounters] = [:]
    @Published private(set) var pings: [UUID: PingResult] = [:]
    private var engines: [UUID: TunnelEngine] = [:]
    private var statsTimer: Timer?
    private let pingMonitor = PingMonitor()
    private var pingCancellable: AnyCancellable?
    let history: HistoryStore?
    private var lastByteSnapshot: [UUID: ByteCounters] = [:]
```

- [ ] **Step 2: Open the history DB in init**

Replace the init body:

```swift
    init(store: ConfigStore, connections: [Connection]) {
        self.store = store
        self.connections = connections
        for c in connections {
            installEngine(for: c, startIfAuto: true)
        }
        startStatsTimer()
        startPingMonitor()
    }
```

with:

```swift
    init(store: ConfigStore, connections: [Connection]) {
        self.store = store
        self.connections = connections

        // History is best-effort. If the DB can't open we keep running without it.
        var openedHistory: HistoryStore?
        do {
            try? Paths.ensureSupportDirectory()
            openedHistory = try HistoryStore(url: Paths.historyFile)
        } catch {
            NSLog("SSHManager: history disabled: \(error)")
        }
        self.history = openedHistory

        // Drop everything older than 90 days. Daily-equivalent for a long-running menubar app.
        openedHistory?.purgeOlderThan(seconds: 90 * 86_400)

        for c in connections {
            installEngine(for: c, startIfAuto: true)
        }
        startStatsTimer()
        startPingMonitor()
    }
```

- [ ] **Step 3: Record events on state change**

In `installEngine(for:startIfAuto:)`, replace the existing `onStateChange` closure:

```swift
        e.onStateChange = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Engine state lives in TunnelEngine. Re-publish so SwiftUI re-evaluates
                // bodies that read supervisor.state(for:).
                self.objectWillChange.send()
                self.onChange?()
            }
        }
```

with:

```swift
        e.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send()
                self.onChange?()
                self.recordStateChangeEvent(connectionId: connection.id, newState: newState)
            }
        }
```

- [ ] **Step 4: Add the event-recording helper**

In the `// MARK: - Private` section of `TunnelSupervisor`, add:

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

- [ ] **Step 5: Write samples on each ping tick**

Replace `startPingMonitor()`:

```swift
    private func startPingMonitor() {
        refreshPingTargets()
        pingCancellable = pingMonitor.$results
            .sink { [weak self] new in
                self?.pings = new
            }
        pingMonitor.start()
    }
```

with:

```swift
    private func startPingMonitor() {
        refreshPingTargets()
        pingCancellable = pingMonitor.$results
            .sink { [weak self] new in
                guard let self else { return }
                self.pings = new
                self.writeHistorySamples()
            }
        pingMonitor.start()
    }

    private func writeHistorySamples() {
        guard let history else { return }
        let now = Date()
        for c in connections {
            let current = engines[c.id]?.snapshotStats() ?? ByteCounters()
            let prev = lastByteSnapshot[c.id] ?? ByteCounters()
            // Counters reset to 0 on engine restart. If `current < prev` (a wrap), treat as fresh.
            let upDelta: UInt64 = current.up >= prev.up ? current.up - prev.up : current.up
            let downDelta: UInt64 = current.down >= prev.down ? current.down - prev.down : current.down
            let ping = pings[c.id]?.rttMs
            history.recordSample(
                connectionId: c.id,
                ts: now,
                pingMs: ping,
                upDelta: upDelta,
                downDelta: downDelta
            )
            lastByteSnapshot[c.id] = current
        }
    }
```

- [ ] **Step 6: Clean stale snapshots on delete**

Replace `deleteConnection(id:)`:

```swift
    func deleteConnection(id: UUID) throws {
        if let e = engines[id] {
            e.stop()
            engines.removeValue(forKey: id)
        }
        connections.removeAll { $0.id == id }
        try store.save(connections)
        notifyChanged()
    }
```

with:

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

- [ ] **Step 7: Verify build**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 8: Smoke test — events get written**

Run: `./scripts/build-app.sh && open ./SSHManager.app`

Then:
1. Start one of your existing connections from the menu.
2. Wait ~5 seconds.
3. Stop it.

Inspect the DB:

```sh
sqlite3 ~/Library/Application\ Support/SSHManager/history.db \
  'SELECT datetime(ts, "unixepoch", "localtime"), kind, message FROM events ORDER BY ts DESC LIMIT 5;'
```

Expected output (last 2 lines):
- one `started` event at the moment you clicked Start
- one `stopped` event a few seconds later

- [ ] **Step 9: Smoke test — samples get written**

Wait ~30 seconds with at least one connection running (the ping tick is 10s, so we want ≥2-3 ticks).

```sh
sqlite3 ~/Library/Application\ Support/SSHManager/history.db \
  'SELECT datetime(ts, "unixepoch", "localtime"), substr(connection_id,1,8), ping_ms, up_delta, down_delta FROM samples ORDER BY ts DESC LIMIT 10;'
```

Expected: multiple rows with timestamps ~10s apart, sensible ping_ms values, byte deltas (likely 0 for an idle SOCKS proxy — that's fine).

If both checks pass, the write path works. Quit the app before moving on.

---

## Task 5: StatsView shell — header, range picker, summary row

**Files:**
- Create: `Sources/SSHManager/UI/StatsView.swift`

- [ ] **Step 1: Write the StatsView shell**

Create `Sources/SSHManager/UI/StatsView.swift`:

```swift
import SwiftUI

enum StatsRange: String, CaseIterable, Identifiable {
    case h1   = "1h"
    case h6   = "6h"
    case d1   = "24h"
    case d7   = "7d"
    case d30  = "30d"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .h1:  return 3600
        case .h6:  return 6 * 3600
        case .d1:  return 86_400
        case .d7:  return 7 * 86_400
        case .d30: return 30 * 86_400
        }
    }
}

struct StatsView: View {
    let connection: Connection
    let history: HistoryStore
    @ObservedObject var supervisor: TunnelSupervisor
    @Environment(\.dismiss) private var dismiss

    @State private var range: StatsRange = .d1
    @State private var samples: [Sample] = []
    @State private var events: [StateEvent] = []
    @State private var summary: StatsSummary = .empty
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rangePicker
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            summaryRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    Text("Charts go here (Task 6)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                    Text("Events go here (Task 7)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { reload() }
        .onChange(of: range) { _, _ in reload() }
        .onReceive(supervisor.objectWillChange) { _ in
            // The supervisor publishes on every ping tick / state change; refetch.
            reload()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? "(unnamed)" : connection.name)
                    .font(.title2).fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let target = "\(connection.user)@\(connection.host):\(connection.sshPort)"
        switch connection.type {
        case .dynamic: return "SOCKS :\(connection.listenPort) · via \(target)"
        case .local:   return "L :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0) · via \(target)"
        case .remote:  return "R :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0) · via \(target)"
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(StatsRange.allCases) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var summaryRow: some View {
        HStack(spacing: 18) {
            metric("Uptime",   String(format: "%.1f%%", summary.uptimeFraction * 100))
            metric("Fails",    "\(summary.failCount)")
            metric("Avg ping", summary.avgPingMs.map { String(format: "%.0f ms", $0) } ?? "—")
            metric("↑",         formatBytes(summary.totalUp))
            metric("↓",         formatBytes(summary.totalDown))
            Spacer()
        }
        .font(.system(.callout, design: .monospaced))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    // MARK: - Data

    private func reload() {
        let to = Date()
        let from = to.addingTimeInterval(-range.duration)
        samples = history.fetchSamples(connectionId: connection.id, from: from, to: to)
        events = history.fetchEvents(connectionId: connection.id, from: from, to: to)
        summary = history.summary(connectionId: connection.id, from: from, to: to)
    }
}

extension StatsSummary {
    static let empty = StatsSummary(
        uptimeFraction: 0, failCount: 0, avgPingMs: nil, totalUp: 0, totalDown: 0
    )
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 6: Charts — ping, throughput, state band

**Files:**
- Modify: `Sources/SSHManager/UI/StatsView.swift`

- [ ] **Step 1: Add Swift Charts import and chart views**

In `Sources/SSHManager/UI/StatsView.swift`, change the import line at the top:

```swift
import SwiftUI
```

to:

```swift
import SwiftUI
import Charts
```

Then replace this block:

```swift
            ScrollView {
                VStack(spacing: 16) {
                    Text("Charts go here (Task 6)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                    Text("Events go here (Task 7)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
                .padding(16)
            }
```

with:

```swift
            ScrollView {
                VStack(spacing: 16) {
                    chartsBlock
                    Text("Events go here (Task 7)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
                .padding(16)
            }
```

- [ ] **Step 2: Add the chartsBlock view + helpers**

Append before the `// MARK: - Data` line:

```swift
    private var visibleRange: ClosedRange<Date> {
        let to = Date()
        return to.addingTimeInterval(-range.duration)...to
    }

    private var failEvents: [StateEvent] {
        events.filter { $0.kind == .failed }
    }

    private var sampleIntervalSeconds: Double {
        // PingMonitor ticks every 10s. Throughput = delta / 10.
        return 10
    }

    @ViewBuilder
    private var chartsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            chartTitle("Ping (ms)")
            pingChart
                .frame(height: 140)

            chartTitle("Throughput (B/s)")
            throughputChart
                .frame(height: 110)

            chartTitle("State")
            stateBand
                .frame(height: 14)
        }
    }

    private func chartTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var pingChart: some View {
        Chart {
            ForEach(samples.indices, id: \.self) { i in
                let s = samples[i]
                if let p = s.pingMs {
                    LineMark(
                        x: .value("t", s.ts),
                        y: .value("ping", p)
                    )
                    .interpolationMethod(.monotone)
                } else {
                    PointMark(
                        x: .value("t", s.ts),
                        y: .value("ping", 0)
                    )
                    .foregroundStyle(.red)
                    .symbolSize(20)
                }
            }
            ForEach(failEvents) { e in
                RuleMark(x: .value("fail", e.ts))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: visibleRange)
    }

    private var throughputChart: some View {
        Chart {
            ForEach(samples.indices, id: \.self) { i in
                let s = samples[i]
                AreaMark(
                    x: .value("t", s.ts),
                    y: .value("rate", Double(s.upDelta) / sampleIntervalSeconds)
                )
                .foregroundStyle(by: .value("dir", "↑ up"))
                AreaMark(
                    x: .value("t", s.ts),
                    y: .value("rate", Double(s.downDelta) / sampleIntervalSeconds)
                )
                .foregroundStyle(by: .value("dir", "↓ down"))
            }
            ForEach(failEvents) { e in
                RuleMark(x: .value("fail", e.ts))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: visibleRange)
        .chartForegroundStyleScale([
            "↑ up":   Color.blue.opacity(0.5),
            "↓ down": Color.green.opacity(0.5),
        ])
    }

    private var stateBand: some View {
        StateBandView(
            range: visibleRange,
            events: events,
            stateAtStart: history.lastEvent(connectionId: connection.id,
                                            atOrBefore: visibleRange.lowerBound)?.kind
        )
    }
```

- [ ] **Step 3: Add StateBandView (Canvas-based state strip)**

Append at the bottom of `Sources/SSHManager/UI/StatsView.swift`, after the last `}` of the file:

```swift
private struct StateBandView: View {
    let range: ClosedRange<Date>
    let events: [StateEvent]
    let stateAtStart: StateEvent.Kind?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let total = range.upperBound.timeIntervalSince(range.lowerBound)
                guard total > 0 else { return }

                // Build interval list: (start, end, color)
                var current: StateEvent.Kind = stateAtStart ?? .stopped
                var cursor = range.lowerBound
                var intervals: [(Date, Date, Color)] = []
                for e in events {
                    let s = max(cursor, range.lowerBound)
                    let t = min(e.ts, range.upperBound)
                    if t > s {
                        intervals.append((s, t, color(for: current)))
                    }
                    cursor = e.ts
                    current = e.kind
                }
                // Tail to the right edge.
                if cursor < range.upperBound {
                    intervals.append((max(cursor, range.lowerBound), range.upperBound, color(for: current)))
                }

                for (s, e, c) in intervals {
                    let x0 = CGFloat((s.timeIntervalSince(range.lowerBound)) / total) * size.width
                    let x1 = CGFloat((e.timeIntervalSince(range.lowerBound)) / total) * size.width
                    let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(c))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func color(for kind: StateEvent.Kind) -> Color {
        switch kind {
        case .started: return .green.opacity(0.6)
        case .stopped: return .gray.opacity(0.35)
        case .failed:  return .red.opacity(0.6)
        }
    }
}
```

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 7: Events list

**Files:**
- Modify: `Sources/SSHManager/UI/StatsView.swift`

- [ ] **Step 1: Replace the placeholder events block with a real list**

In `Sources/SSHManager/UI/StatsView.swift`, replace:

```swift
                    Text("Events go here (Task 7)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
```

with:

```swift
                    eventsList
```

- [ ] **Step 2: Add the eventsList computed property and a date formatter**

Append before the `// MARK: - Data` line:

```swift
    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    @ViewBuilder
    private var eventsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Events").font(.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                Text("No events in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.eventTimeFormatter.string(from: e.ts))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        Text(e.kind.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color(for: e.kind))
                            .frame(width: 60, alignment: .leading)
                        Text(e.message ?? "")
                            .font(.caption)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func color(for kind: StateEvent.Kind) -> Color {
        switch kind {
        case .started: return .green
        case .stopped: return .secondary
        case .failed:  return .red
        }
    }
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: `Build complete!`.

---

## Task 8: Open StatsView from a row click

**Files:**
- Modify: `Sources/SSHManager/UI/ConnectionListView.swift`

- [ ] **Step 1: Add state and the sheet presentation**

In `Sources/SSHManager/UI/ConnectionListView.swift`, replace this block at the top of the view:

```swift
struct ConnectionListView: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var editing: Connection?
    @State private var addingDraft: Connection?
    @State private var errorMessage: String?
```

with:

```swift
struct ConnectionListView: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var editing: Connection?
    @State private var addingDraft: Connection?
    @State private var statsFor: Connection?
    @State private var errorMessage: String?
```

- [ ] **Step 2: Add the stats sheet modifier**

Add this `.sheet` next to the existing two `.sheet` calls (after the `addingDraft` sheet, before `.alert`):

```swift
        .sheet(item: $statsFor) { c in
            if let history = supervisor.history {
                StatsView(connection: c, history: history, supervisor: supervisor)
            } else {
                VStack(spacing: 12) {
                    Text("History database unavailable.").font(.headline)
                    Text("Check ~/Library/Application Support/SSHManager/history.db permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Close") { statsFor = nil }
                }
                .padding(24)
                .frame(minWidth: 360)
            }
        }
```

- [ ] **Step 3: Pipe `onShowStats` into ConnectionRow**

Replace the `ConnectionRow(...)` call inside the `ForEach`:

```swift
                        ConnectionRow(
                            connection: c,
                            state: supervisor.state(for: c.id),
                            counters: supervisor.stats[c.id] ?? ByteCounters(),
                            ping: supervisor.pings[c.id],
                            onToggle: { supervisor.toggle(id: c.id) },
                            onEdit: { editing = c },
                            onDelete: {
                                do {
                                    try supervisor.deleteConnection(id: c.id)
                                } catch {
                                    errorMessage = "Failed to delete: \(error.localizedDescription)"
                                }
                            }
                        )
```

with:

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

- [ ] **Step 4: Update ConnectionRow signature and wire the tap gesture**

In the same file, find `private struct ConnectionRow: View {` and replace its property block:

```swift
private struct ConnectionRow: View {
    let connection: Connection
    let state: TunnelState
    let counters: ByteCounters
    let ping: PingResult?
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
```

with:

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

Then replace the inner VStack (the name + subtitle block) inside `ConnectionRow.body`:

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
```

with:

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

The gesture is scoped to this VStack only — the Start/Edit/trash `Button`s outside it keep their own tap targets.

- [ ] **Step 5: Verify build**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 6: Full smoke test**

Run: `./scripts/build-app.sh && open ./SSHManager.app`

Then:
1. Open the main window from the menubar.
2. Start at least one connection. Let it run for ~30 seconds (so a few samples land).
3. Stop it. Start it again. Stop it again (so events exist).
4. Click the connection name (left side of the row). The stats sheet should open.
5. Verify:
   - Header shows the connection's name and target.
   - Range picker defaults to `24h`. Switching to `1h` should re-fetch and re-render.
   - Summary row shows non-zero `Fails: 0`, non-nil `Avg ping`, byte totals.
   - Ping chart shows a line with at least a few points.
   - Throughput chart shows two near-zero areas (idle SOCKS).
   - State band shows alternating green/gray segments matching your start/stop cycles.
   - Events list shows the start/stop entries you produced, newest first.
6. Click on a row, then click the Start/Edit/🗑 buttons of OTHER rows — verify those buttons still work and don't open the stats sheet.

If anything misbehaves, fix it before moving to Task 9.

---

## Task 9: Rebuild .pkg

**Files:** None (just scripts).

- [ ] **Step 1: Bump the patch version**

In `Resources/Info.plist`, change `CFBundleShortVersionString` from `0.1.0` to `0.2.0` (use `PlistBuddy`):

Run:
```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.2.0' Resources/Info.plist
```

- [ ] **Step 2: Build the .pkg**

Run: `./scripts/build-pkg.sh`
Expected: `Built: SSHManager-0.2.0.pkg`.

- [ ] **Step 3: Quick install verify**

Run: `pkgutil --expand SSHManager-0.2.0.pkg /tmp/sshm-pkg-verify && ls /tmp/sshm-pkg-verify/Payload || true`
Expected: payload extracts and contains the .app bundle. (Then `rm -rf /tmp/sshm-pkg-verify`.)

---

## Self-Review Notes

- **Spec coverage:**
  - Schema, WAL, indices — Task 3.
  - Sample writes on 10s tick — Task 4, Step 5.
  - Event writes on state change — Task 4, Steps 3-4.
  - 90-day purge at init — Task 4, Step 2.
  - StatsView shell + range picker + summary — Task 5.
  - Three charts with event overlays + state band — Task 6.
  - Events list — Task 7.
  - Click-to-open scoped to text VStack — Task 8, Step 4.
- **Placeholders:** none — every step shows the actual code or command.
- **Type consistency:** `StateEvent.Kind` is the same enum used in `recordEvent`, `events` array, color helpers, and `stateAtStart`. `Sample.pingMs` is `Double?` everywhere.
