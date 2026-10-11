//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .real(self) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { var sqlValue: SQLValue { .real(timeIntervalSince1970) } }
extension UUID: SQLBindable { var sqlValue: SQLValue { .text(uuidString) } }
extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }

extension Optional where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One materialised result row with typed accessors.
struct SQLRow {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) { self.values = values }

    func raw(_ column: String) -> SQLValue? { values[column] }

    func int(_ column: String) -> Int? {
        switch values[column] {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        default: return nil
        }
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    func string(_ column: String) -> String? {
        switch values[column] {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        default: return nil
        }
    }

    func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }

    func date(_ column: String) -> Date? { double(column).map { Date(timeIntervalSince1970: $0) } }

    func uuid(_ column: String) -> UUID? { string(column).flatMap(UUID.init(uuidString:)) }

    func data(_ column: String) -> Data? {
        if case .blob(let value) = values[column] { return value }
        return nil
    }
}

struct SQLiteError: LocalizedError {
    let code: Int32
    let message: String
    var errorDescription: String? { "SQLite error \(code): \(message)" }
}

/// Minimal typed wrapper over the system SQLite. Every statement runs on the database's own
/// serial queue, which is what keeps repositories off the main thread and makes the single
/// writer safe without a second connection.
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    /// Recursive so a repository inside `transaction` can keep calling `run` and `query`.
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    let path: String

    init(path: String) throws {
        self.path = path
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let pointer { sqlite3_close_v2(pointer) }
            throw SQLiteError(code: SQLITE_CANTOPEN, message: message)
        }
        handle = pointer
        try sync {
            try executeUnsafe("PRAGMA journal_mode = WAL;")
            try executeUnsafe("PRAGMA foreign_keys = ON;")
            try executeUnsafe("PRAGMA busy_timeout = 8000;")
            try executeUnsafe("PRAGMA synchronous = NORMAL;")
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Running work

    /// Serialises `body` against every other database call. All repository calls funnel here.
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func execute(_ sql: String) throws {
        try sync { try executeUnsafe(sql) }
    }

    @discardableResult
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        try sync { try runUnsafe(sql, parameters) }
    }

    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        try sync { try queryUnsafe(sql, parameters) }
    }

    func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, parameters).first
    }

    func scalarInt(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        guard let row = try queryOne(sql, parameters) else { return 0 }
        return row.int("value") ?? 0
    }

    /// Wraps `body` in a transaction. Any thrown error rolls back, which is how import and
    /// analysis replacement stay atomic. Nested calls use savepoints, so a repository that runs
    /// its own transaction composes inside a larger one (import does exactly this).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try sync {
            let depth = transactionDepth
            if depth == 0 {
                try executeUnsafe("BEGIN IMMEDIATE;")
            } else {
                try executeUnsafe("SAVEPOINT nested\(depth);")
            }
            transactionDepth = depth + 1
            do {
                let result = try body()
                transactionDepth = depth
                if depth == 0 {
                    try executeUnsafe("COMMIT;")
                } else {
                    try executeUnsafe("RELEASE nested\(depth);")
                }
                return result
            } catch {
                transactionDepth = depth
                if depth == 0 {
                    try? executeUnsafe("ROLLBACK;")
                } else {
                    try? executeUnsafe("ROLLBACK TO nested\(depth); RELEASE nested\(depth);")
                }
                throw error
            }
        }
    }

    // MARK: - Reentrant primitives (already on the queue)

    /// Called with the lock already held.
    func executeUnsafe(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: sqlite3_errcode(handle), message: message)
        }
    }

    @discardableResult
    func runUnsafe(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    func queryUnsafe(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, index)))
        }

        var rows: [SQLRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
            }
            var values: [String: SQLValue] = [:]
            for index in 0..<columnCount {
                values[names[Int(index)]] = columnValue(statement, index)
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    private func columnValue(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: pointer))
        case SQLITE_BLOB:
            guard let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw SQLiteError(code: sqlite3_errcode(handle), message: "\(message) — while preparing: \(sql)")
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let string): status = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .blob(let data):
                status = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError(code: status, message: "could not bind parameter \(index)")
            }
        }
        return statement
    }

    // MARK: - Maintenance

    func userVersion() throws -> Int {
        try sync { try queryUnsafe("PRAGMA user_version;").first?.int("user_version") ?? 0 }
    }

    func setUserVersion(_ version: Int) throws {
        try sync { try executeUnsafe("PRAGMA user_version = \(version);") }
    }

    func checkpointAndVacuum() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try execute("VACUUM;")
    }

    var fileSizeBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
