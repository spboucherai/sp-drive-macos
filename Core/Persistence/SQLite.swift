// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Core/Persistence/SQLite.swift
// Description      : A small, thread-safe SQLite wrapper (WAL, busy timeout,
//                    prepared statements, transactions) used by the metadata
//                    mirror and the operation journal.
// Module           : Core
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-18
// Last Modified    : 2026-11-18
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : None specified (no license file in this repository)
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)
    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
    public var double: Double? { switch self { case .double(let v): return v; case .int(let v): return Double(v); default: return nil } }
    public var bool: Bool { int ?? 0 != 0 }
}
public typealias SQLRow = [String: SQLValue]
public struct SQLiteError: Error, Sendable, CustomStringConvertible { public let code: Int32; public let message: String; public var description: String { "SQLite \(code): \(message)" } }

/// One connection, serialised by a recursive lock. Several processes may open the same file (WAL + busy timeout).
public final class SQLiteDB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var cache: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else { let e = error(); sqlite3_close(handle); throw e }
        sqlite3_busy_timeout(handle, 8000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;")
    }
    deinit { for s in cache.values { sqlite3_finalize(s) }; sqlite3_close(handle) }
    private func error() -> SQLiteError { SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle))) }

    public func exec(_ sql: String) throws {
        try lock.withLock { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let stmt = s else { throw error() }
        cache[sql] = stmt
        return stmt
    }
    private func bind(_ s: OpaquePointer, _ values: [SQLValue]) throws {
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1); let rc: Int32
            switch v {
            case .null: rc = sqlite3_bind_null(s, n)
            case .int(let x): rc = sqlite3_bind_int64(s, n, x)
            case .double(let x): rc = sqlite3_bind_double(s, n, x)
            case .text(let x): rc = sqlite3_bind_text(s, n, x, -1, SQLiteDB.transient)
            case .blob(let x): rc = x.withUnsafeBytes { sqlite3_bind_blob(s, n, $0.baseAddress, Int32(x.count), SQLiteDB.transient) }
            }
            guard rc == SQLITE_OK else { throw error() }
        }
    }
    /// Runs a statement that returns no row; returns the number of rows changed.
    @discardableResult public func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        try lock.withLock {
            let s = try prepare(sql); try bind(s, values)
            defer { sqlite3_reset(s) }
            guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
            return Int(sqlite3_changes(handle))
        }
    }
    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [SQLRow] {
        try lock.withLock {
            let s = try prepare(sql); try bind(s, values)
            defer { sqlite3_reset(s) }
            var rows: [SQLRow] = []
            let n = sqlite3_column_count(s)
            while true {
                let rc = sqlite3_step(s)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw error() }
                var row = SQLRow(minimumCapacity: Int(n))
                for i in 0..<n {
                    let name = String(cString: sqlite3_column_name(s, i))
                    switch sqlite3_column_type(s, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(s, i))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(s, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(s, i)))
                    case SQLITE_BLOB: let c = Int(sqlite3_column_bytes(s, i)); row[name] = .blob(c > 0 ? Data(bytes: sqlite3_column_blob(s, i), count: c) : Data())
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }
    public func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> SQLValue { try query(sql, values).first?.values.first ?? .null }
    /// Runs `body` in an IMMEDIATE transaction (the write lock is taken at once, so two processes queue instead of failing half-way).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if sqlite3_get_autocommit(handle) == 0 { return try body() } // already inside one
            try exec("BEGIN IMMEDIATE")
            do { let r = try body(); try exec("COMMIT"); return r } catch { try? exec("ROLLBACK"); throw error }
        }
    }
}
