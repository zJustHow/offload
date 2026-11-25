import Foundation
import SQLite3

/// A value that can be bound to, or read from, a SQLite statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
}

public extension SQLValue {
    static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    static func opt(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    static func opt(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
    static func bool(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
}

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case prepare(message: String, sql: String)
    case step(message: String, sql: String)

    public var description: String {
        switch self {
        case .open(let m): return "database open failed: \(m)"
        case .prepare(let m, let sql): return "SQL prepare failed: \(m) in: \(sql.prefix(160))"
        case .step(let m, let sql): return "SQL step failed: \(m) in: \(sql.prefix(160))"
        }
    }
}

/// One result row. Column access is by index; helpers coerce NULL to sensible defaults.
public struct Row {
    fileprivate let stmt: OpaquePointer

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    public func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small, serialized wrapper over the system SQLite. Every call takes a recursive lock so the
/// handle can be shared across tasks; statements are prepared per call (the workloads here are
/// batch-oriented, so statement caching is not worth the complexity).
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw DatabaseError.open(msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            try exec("PRAGMA journal_mode = WAL;")
            try exec("PRAGMA synchronous = NORMAL;")
        }
    }

    public static func inMemory() throws -> Database { try Database(path: ":memory:") }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    /// Runs one or more statements with no parameters and no result handling.
    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.step(message: msg, sql: sql)
        }
    }

    /// Runs a single statement and discards any rows.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params, sql: sql)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { continue }
            if rc == SQLITE_DONE { break }
            throw DatabaseError.step(message: errorMessage(), sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params, sql: sql)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw DatabaseError.step(message: errorMessage(), sql: sql) }
        }
        return out
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64? {
        try query(sql, params) { $0.int(0) }.first
    }

    public func scalarText(_ sql: String, _ params: [SQLValue] = []) throws -> String? {
        try query(sql, params) { $0.optText(0) }.first ?? nil
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside a transaction; commits on return, rolls back on throw. Nested calls join
    /// the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if depth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE;")
        depth += 1
        defer { depth -= 1 }
        do {
            let value = try body()
            try exec("COMMIT;")
            return value
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }
    private var depth = 0

    // MARK: - internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(message: errorMessage(), sql: sql)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue], sql: String) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            if rc != SQLITE_OK { throw DatabaseError.step(message: errorMessage(), sql: sql) }
        }
    }

    private func errorMessage() -> String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle" }
}
