// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Sync/OperationJournal.swift
// Description      : Persistent journal of the changes decided on this device
//                    (create folder, rename, move, trash, restore, favourite,
//                    copy): applied at once to the local mirror, replayed in
//                    order against the server when it is reachable, kept as
//                    history. Survives restarts; nothing is lost offline.
// Module           : Sync
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
import SPDriveCore

public enum OpKind: String, Codable, Sendable { case createFolder, rename, move, trash, restore, star, copy }
public struct OpPayload: Codable, Sendable, Equatable {
    public var ids: [String] = []        // items concerned (identifiers may be local ones, see `localPrefix`)
    public var kinds: [String] = []      // "file"/"folder", parallel to ids
    public var parent: String?           // destination folder, or parent of a new folder
    public var name: String?
    public var flag: Bool?
    public var localID: String?          // identifier given to a folder created offline
    public init() {}
}
public struct JournalOp: Sendable, Identifiable, Equatable {
    public var id: String; public var kind: OpKind; public var payload: OpPayload
    /// pending, done, failed
    public var state: String
    public var attempts: Int; public var error: String?; public var source: String; public var createdAt: Date; public var updatedAt: Date
    public var summary: String {
        let n = payload.ids.count
        switch kind {
        case .createFolder: return "Créer le dossier « \(payload.name ?? "") »"
        case .rename: return "Renommer en « \(payload.name ?? "") »"
        case .move: return "Déplacer \(n) élément\(n > 1 ? "s" : "")"
        case .trash: return "Mettre \(n) élément\(n > 1 ? "s" : "") à la corbeille"
        case .restore: return "Restaurer \(n) élément\(n > 1 ? "s" : "")"
        case .star: return payload.flag == true ? "Ajouter aux favoris" : "Retirer des favoris"
        case .copy: return "Dupliquer \(n) élément\(n > 1 ? "s" : "")"
        }
    }
}

public final class OperationJournal: Sendable {
    public static let localPrefix = "local-"
    public let api: APIClient
    public let store: MetadataStore
    public init(api: APIClient, store: MetadataStore) { self.api = api; self.store = store }
    public static func isLocal(_ id: String) -> Bool { id.hasPrefix(localPrefix) }

    // MARK: Recording (optimistic)
    private func append(_ kind: OpKind, _ payload: OpPayload, source: String) throws -> String {
        let id = UUID().uuidString, now = Date().timeIntervalSince1970
        let ord = (try store.db.scalar("SELECT COALESCE(MAX(ord), 0) + 1 FROM ops").int) ?? 1
        try store.db.run("INSERT INTO ops (id, kind, payload, state, source, created_at, updated_at, ord) VALUES (?,?,?,?,?,?,?,?)",
                         [.text(id), .text(kind.rawValue), .text(String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"), .text("pending"), .text(source), .double(now), .double(now), .int(ord)])
        return id
    }
    private func selection(_ items: [DriveItem]) -> OpPayload { var p = OpPayload(); p.ids = items.map(\.id); p.kinds = items.map(\.kind.rawValue); return p }
    private func local(_ sql: String, _ v: [SQLValue], ids: [String]) throws { try store.db.run(sql, v); try store.touch(ids) }

    /// Creates a folder locally at once; the server learns of it when reachable. Returns the local item.
    @discardableResult public func createFolder(parent: String, name: String, source: String = "app") throws -> DriveItem {
        try store.db.transaction {
            let taken = Set(try store.children(of: parent).map { NameRules.key($0.name) })
            let free = NameRules.nextFree(NameRules.sanitize(name, fallback: "Nouveau dossier")) { taken.contains($0) }
            var p = OpPayload(); p.parent = parent; p.name = free; p.localID = OperationJournal.localPrefix + UUID().uuidString.lowercased()
            let item = DriveItem(id: p.localID!, kind: .folder, name: free, parentID: parent, rev: 0)
            try store.upsert([item]); _ = try append(.createFolder, p, source: source)
            return item
        }
    }
    public func rename(_ item: DriveItem, to name: String, source: String = "app") throws {
        let clean = NameRules.sanitize(name)
        guard clean != item.name else { return }
        try store.db.transaction {
            if let parent = item.parentID, let other = try store.child(of: parent, named: clean), other.id != item.id { throw DriveError.server(status: 409, code: "name_conflict", message: "", extra: [:]) }
            var p = selection([item]); p.name = clean
            try local("UPDATE items SET name = ?, name_key = ?, ext = ? WHERE id = ?", [.text(clean), .text(NameRules.searchKey(clean)), .text(item.isFolder ? "" : NameRules.fileExtension(clean)), .text(item.id)], ids: [item.id])
            _ = try append(.rename, p, source: source)
        }
    }
    public func move(_ items: [DriveItem], to destination: String, source: String = "app") throws {
        let moving = items.filter { $0.parentID != destination && !$0.isRoot }
        guard !moving.isEmpty else { return }
        try store.db.transaction {
            for f in moving where f.isFolder { if try store.subtreeIDs(of: f.id).contains(destination) { throw DriveError.server(status: 409, code: "move_into_self", message: "", extra: [:]) } }
            var p = selection(moving); p.parent = destination
            for i in moving { try local("UPDATE items SET parent_id = ? WHERE id = ?", [.text(destination), .text(i.id)], ids: [i.id]) }
            _ = try append(.move, p, source: source)
        }
    }
    public func trash(_ items: [DriveItem], source: String = "app") throws {
        let live = items.filter { !$0.isRoot && !$0.isTrashed }
        guard !live.isEmpty else { return }
        try store.db.transaction {
            let now = Date().timeIntervalSince1970
            for i in live {
                let ids = i.isFolder ? try store.subtreeIDs(of: i.id) : [i.id]
                for id in ids { try store.db.run("UPDATE items SET trashed_at = ?, trash_root = ? WHERE id = ? AND trashed_at IS NULL", [.double(now), .int(id == i.id ? 1 : 0), .text(id)]) }
                try store.touch(ids)
            }
            _ = try append(.trash, selection(live), source: source)
        }
    }
    public func restore(_ items: [DriveItem], source: String = "app") throws {
        let roots = items.filter(\.trashRoot)
        guard !roots.isEmpty else { return }
        try store.db.transaction {
            for i in roots {
                let ids = i.isFolder ? try store.subtreeIDs(of: i.id, includeTrashed: true) : [i.id]
                for id in ids { try store.db.run("UPDATE items SET trashed_at = NULL, trash_root = 0 WHERE id = ?", [.text(id)]) }
                try store.touch(ids)
            }
            _ = try append(.restore, selection(roots), source: source)
        }
    }
    public func setStarred(_ item: DriveItem, _ on: Bool, source: String = "app") throws {
        try store.db.transaction {
            var p = selection([item]); p.flag = on
            try local("UPDATE items SET starred = ? WHERE id = ?", [.int(on ? 1 : 0), .text(item.id)], ids: [item.id])
            _ = try append(.star, p, source: source)
        }
    }
    /// Duplicates items into a folder. The copies appear when the server has made them (their content is shared there, not re-sent).
    public func copy(_ items: [DriveItem], to destination: String, source: String = "app") throws {
        guard !items.isEmpty else { return }
        var p = selection(items); p.parent = destination
        _ = try append(.copy, p, source: source)
    }

    // MARK: Reading
    private static func op(_ r: SQLRow) -> JournalOp? {
        guard let kind = OpKind(rawValue: r["kind"]?.text ?? ""), let payload = try? JSONDecoder().decode(OpPayload.self, from: Data((r["payload"]?.text ?? "{}").utf8)) else { return nil }
        return JournalOp(id: r["id"]?.text ?? "", kind: kind, payload: payload, state: r["state"]?.text ?? "", attempts: Int(r["attempts"]?.int ?? 0), error: r["error"]?.text, source: r["source"]?.text ?? "app",
                         createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0), updatedAt: Date(timeIntervalSince1970: r["updated_at"]?.double ?? 0))
    }
    public func pending() throws -> [JournalOp] { try store.db.query("SELECT * FROM ops WHERE state = 'pending' ORDER BY ord").compactMap(OperationJournal.op) }
    public func pendingCount() throws -> Int { Int(try store.db.scalar("SELECT COUNT(*) FROM ops WHERE state = 'pending'").int ?? 0) }
    public func history(limit: Int = 200) throws -> [JournalOp] { try store.db.query("SELECT * FROM ops ORDER BY ord DESC LIMIT ?", [.int(Int64(limit))]).compactMap(OperationJournal.op) }
    /// Server identifier of an item created offline, once known.
    public func resolve(_ id: String) -> String { OperationJournal.isLocal(id) ? ((try? store.meta("idmap:" + id)) ?? id) ?? id : id }
    public func prune(olderThan days: Int = 30) throws {
        try store.db.run("DELETE FROM ops WHERE state <> 'pending' AND updated_at < ?", [.double(Date().timeIntervalSince1970 - Double(days) * 86400)])
    }

    // MARK: Replay
    public struct RunResult: Sendable, Equatable { public var done = 0; public var failed = 0; public var blocked = false }
    /// Replays pending operations in the order they were decided. A network failure stops the run (order matters and
    /// nothing is skipped); an operation the server refuses for good is marked failed, the mirror is put back in line
    /// with the server for the items it touched, and the run continues.
    @discardableResult public func run() async -> RunResult {
        var result = RunResult()
        guard let ops = try? pending() else { return result }
        for op in ops {
            do {
                try Task.checkCancellation()
                try await execute(op)
                try finish(op, state: "done", error: nil); result.done += 1
            } catch {
                let e = DriveError.wrap(error)
                if e.isTransient || e == .cancelled || e == .unauthenticated {
                    _ = try? store.db.run("UPDATE ops SET attempts = attempts + 1, error = ?, updated_at = ? WHERE id = ?", [.text(e.errorDescription ?? e.code), .double(Date().timeIntervalSince1970), .text(op.id)])
                    result.blocked = true; return result
                }
                // an item already gone, or already in the wanted state, is not a failure of the person's intent
                let harmless = e.isNotFound && [.trash, .star].contains(op.kind)
                _ = try? finish(op, state: harmless ? "done" : "failed", error: harmless ? nil : (e.errorDescription ?? e.code))
                if harmless { result.done += 1 } else { result.failed += 1 }
                await realign(op)
            }
        }
        return result
    }
    private func finish(_ op: JournalOp, state: String, error: String?) throws {
        try store.db.run("UPDATE ops SET state = ?, error = ?, attempts = attempts + 1, updated_at = ? WHERE id = ?", [.text(state), error.map(SQLValue.text) ?? .null, .double(Date().timeIntervalSince1970), .text(op.id)])
    }
    private func selection(_ p: OpPayload) throws -> Selection {
        var s = Selection()
        for (i, raw) in p.ids.enumerated() {
            let id = resolve(raw)
            if OperationJournal.isLocal(id) { throw DriveError.local("l’élément créé hors ligne n’a pas pu être créé sur le serveur") }
            if i < p.kinds.count, p.kinds[i] == "folder" { s.folderIds.append(id) } else { s.fileIds.append(id) }
        }
        return s
    }
    private func execute(_ op: JournalOp) async throws {
        let p = op.payload
        func parent() throws -> String {
            let id = resolve(p.parent ?? "root")
            if OperationJournal.isLocal(id) { throw DriveError.local("le dossier de destination n’a pas pu être créé sur le serveur") }
            return id
        }
        switch op.kind {
        case .createFolder:
            let created = try await api.createFolder(parent: try parent(), name: p.name ?? "Nouveau dossier", onConflict: .rename)
            if let localID = p.localID {
                // swap the placeholder for the real folder and re-home what was put inside it meanwhile
                try store.db.transaction {
                    try store.setMeta("idmap:" + localID, created.id)
                    try store.upsert([created])
                    let kids = try store.db.query("SELECT id FROM items WHERE parent_id = ?", [.text(localID)]).compactMap { $0["id"]?.text }
                    try store.db.run("UPDATE items SET parent_id = ? WHERE parent_id = ?", [.text(created.id), .text(localID)])
                    try store.db.run("UPDATE transfers SET parent_id = ? WHERE parent_id = ?", [.text(created.id), .text(localID)])
                    if try store.isPinnedItself(localID) { try store.setPinned(created.id, true) }
                    try store.touch(kids); try store.remove([localID])
                }
            } else { try store.upsert([created]) }
        case .rename:
            let s = try selection(p)
            let updated = s.folderIds.first != nil ? try await api.updateFolder(s.folderIds[0], name: p.name) : try await api.updateFile(s.fileIds[0], name: p.name)
            try store.upsert([updated])
        case .move: try await api.move(try selection(p), to: try parent(), onConflict: .rename)
        case .trash: try await api.trash(try selection(p))
        case .restore: try await api.restore(try selection(p))
        case .star:
            let s = try selection(p)
            let updated = s.folderIds.first != nil ? try await api.updateFolder(s.folderIds[0], starred: p.flag) : try await api.updateFile(s.fileIds[0], starred: p.flag)
            try store.upsert([updated])
        case .copy: try await api.copy(try selection(p), to: try parent())
        }
    }
    /// After a refused operation: make the mirror say what the server says for the items involved.
    private func realign(_ op: JournalOp) async {
        var s = Selection()
        for (i, raw) in op.payload.ids.enumerated() {
            let id = resolve(raw); if OperationJournal.isLocal(id) { continue }
            if i < op.payload.kinds.count, op.payload.kinds[i] == "folder" { s.folderIds.append(id) } else { s.fileIds.append(id) }
        }
        if let localID = op.payload.localID { try? store.remove([localID]) }
        guard !s.isEmpty, let fresh = try? await api.items(s) else { return }
        try? store.db.transaction {
            let known = Set(fresh.all.map(\.id))
            for id in s.fileIds + s.folderIds where !known.contains(id) { try store.remove([id]) }
            for i in fresh.all { try store.db.run("UPDATE items SET rev = -1 WHERE id = ?", [.text(i.id)]) } // force the server's state over the optimistic one
            try store.upsert(fresh.all)
        }
    }
}
