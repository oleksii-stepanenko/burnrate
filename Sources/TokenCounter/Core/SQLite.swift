import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

/// Minimal SQLite wrapper. Not thread-safe: always owned by a single actor.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI)
        let target = readOnly ? "file:\(path)?mode=ro" : path
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(description: "open \(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(description: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(description: "prepare: \(errorMessage)\n\(sql)")
        }
        return Statement(stmt)
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ params: [Any?] = [], map: (Statement) -> T) throws -> [T] {
        let st = try prepare(sql)
        st.bind(params)
        var out: [T] = []
        while st.step() { out.append(map(st)) }
        return out
    }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        let st = try prepare(sql)
        st.bind(params)
        _ = st.step()
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    func bind(_ params: [Any?]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(p!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Returns true while a row is available.
    @discardableResult
    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func optString(_ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : string(i)
    }
    func optDouble(_ i: Int32) -> Double? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : double(i)
    }
}
