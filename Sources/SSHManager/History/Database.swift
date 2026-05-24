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

    // SQLITE_TRANSIENT tells sqlite to copy the bound buffer immediately so we don't
    // have to keep the Swift value alive across the step.
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
