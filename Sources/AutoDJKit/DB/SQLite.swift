// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

/// A value bound to or read from a SQLite statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// Converts Swift values to statement arguments.
public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row. The accessors read NULL as the zero value, like Go's sql.Null* types.
public struct SQLRow: Sendable {
    public let values: [SQLValue]

    public subscript(i: Int) -> SQLValue { values[i] }

    public func string(_ i: Int) -> String {
        switch values[i] {
        case .null: ""
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .text(let s): s
        case .blob(let d): String(decoding: d, as: UTF8.self)
        }
    }

    public func int(_ i: Int) -> Int {
        switch values[i] {
        case .int(let v): Int(v)
        case .double(let v): Int(v)
        case .text(let s): Int(s) ?? 0
        default: 0
        }
    }

    public func double(_ i: Int) -> Double {
        switch values[i] {
        case .int(let v): Double(v)
        case .double(let v): v
        case .text(let s): Double(s) ?? 0
        default: 0
        }
    }

    public func isNull(_ i: Int) -> Bool { values[i] == .null }

    /// The integer value, nil when NULL.
    public func optInt(_ i: Int) -> Int? { isNull(i) ? nil : int(i) }
}

/// A SQLite error with the database's message.
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite: \(message) (\(code))" }
}

/// A connection to a plain SQLite file through the system libsqlite3. Not thread-safe: one
/// connection per task, like the Go version's single-connection pool.
public final class SQLite: @unchecked Sendable {
    let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
    }

    /// Runs once the connection is closed (removes a temporary copy).
    var onClose: (@Sendable () -> Void)?

    deinit {
        sqlite3_close_v2(handle)
        onClose?()
    }

    func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else { throw error(rc) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch a.sqlValue {
            case .null: rc = sqlite3_bind_null(st, idx)
            case .int(let v): rc = sqlite3_bind_int64(st, idx, v)
            case .double(let v): rc = sqlite3_bind_double(st, idx, v)
            case .text(let s): rc = sqlite3_bind_text(st, idx, s, -1, Self.transient)
            case .blob(let d):
                rc = d.withUnsafeBytes {
                    sqlite3_bind_blob(st, idx, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            if rc != SQLITE_OK {
                sqlite3_finalize(st)
                throw error(rc)
            }
        }
        return st
    }

    /// Runs a query and returns every row.
    @discardableResult
    public func query(_ sql: String, _ args: SQLBindable...) throws -> [SQLRow] {
        try query(sql, args: args)
    }

    public func query(_ sql: String, args: [SQLBindable]) throws -> [SQLRow] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var rows: [SQLRow] = []
        let n = sqlite3_column_count(st)
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var vals: [SQLValue] = []
            vals.reserveCapacity(Int(n))
            for c in 0..<n {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: vals.append(.int(sqlite3_column_int64(st, c)))
                case SQLITE_FLOAT: vals.append(.double(sqlite3_column_double(st, c)))
                case SQLITE_TEXT: vals.append(.text(String(cString: sqlite3_column_text(st, c))))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(st, c))
                    if let p = sqlite3_column_blob(st, c) {
                        vals.append(.blob(Data(bytes: p, count: len)))
                    } else {
                        vals.append(.blob(Data()))
                    }
                default: vals.append(.null)
                }
            }
            rows.append(SQLRow(values: vals))
        }
        return rows
    }

    /// The first row, or nil.
    public func queryRow(_ sql: String, _ args: SQLBindable...) throws -> SQLRow? {
        try query(sql, args: args).first
    }

    /// Runs a statement; returns the number of rows changed.
    @discardableResult
    public func exec(_ sql: String, _ args: SQLBindable...) throws -> Int {
        try exec(sql, args: args)
    }

    @discardableResult
    public func exec(_ sql: String, args: [SQLBindable]) throws -> Int {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw error(rc) }
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs several statements without arguments.
    public func execScript(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "error"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    /// Runs body in a transaction, committing when it returns and rolling back when it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execScript("begin")
        do {
            let v = try body()
            try execScript("commit")
            return v
        } catch {
            try? execScript("rollback")
            throw error
        }
    }
}
