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

    // MARK: - Flush

    /// Барьер: дождаться завершения всех ранее поставленных асинхронных записей.
    func flush() {
        queue.sync {}
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
