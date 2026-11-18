// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/Persistence/MetadataStore.swift
// Description: Local SQLite mirror of the owner's tree, fed by the change feed: items, purged identifiers, offline pins, materialisation state, and the tables of the sync engine (journal, transfers, conflicts). Browsing and search work from it without a network.
import Foundation

/// The mirror. One file per account; the app and its File Provider extension may open the same file (macOS) or each
/// keep their own (iOS extensions) — the schema is the same. See docs/SCHEMA.md.
public final class MetadataStore: Sendable {
    public let db: SQLiteDB
    public static let schemaVersion = 1

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path)
        try migrate()
    }
    private func migrate() throws {
        try db.transaction {
            try db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let v = Int(try meta("schema") ?? "0") ?? 0
            if v < 1 {
                try db.exec("""
                CREATE TABLE items (
                  id TEXT PRIMARY KEY, kind TEXT NOT NULL, parent_id TEXT, name TEXT NOT NULL, name_key TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
                  size INTEGER NOT NULL DEFAULT 0, sha256 TEXT NOT NULL DEFAULT '', version_id TEXT, version_seq INTEGER NOT NULL DEFAULT 1, version_count INTEGER NOT NULL DEFAULT 1,
                  content_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, starred INTEGER NOT NULL DEFAULT 0, trashed_at REAL, trash_root INTEGER NOT NULL DEFAULT 0,
                  rev INTEGER NOT NULL DEFAULT 0, scan TEXT NOT NULL DEFAULT 'clean', thumb INTEGER NOT NULL DEFAULT 0, preview_kind TEXT NOT NULL DEFAULT 'none',
                  seq INTEGER NOT NULL);
                CREATE INDEX items_parent ON items (parent_id, trashed_at);
                CREATE INDEX items_seq ON items (seq);
                CREATE INDEX items_name ON items (name_key);
                CREATE INDEX items_updated ON items (updated_at DESC);
                CREATE INDEX items_size ON items (size DESC);
                CREATE TABLE tombstones (id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
                CREATE INDEX tombstones_seq ON tombstones (seq);
                CREATE TABLE pins (id TEXT PRIMARY KEY, pinned_at REAL NOT NULL);
                CREATE TABLE local_state (id TEXT PRIMARY KEY, materialized INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL);
                -- journal of operations decided on this device and not yet confirmed by the server (and their history)
                CREATE TABLE ops (
                  id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, error TEXT,
                  source TEXT NOT NULL DEFAULT 'app', created_at REAL NOT NULL, updated_at REAL NOT NULL, next_try REAL NOT NULL DEFAULT 0, ord INTEGER NOT NULL);
                CREATE INDEX ops_state ON ops (state, ord);
                CREATE TABLE transfers (
                  id TEXT PRIMARY KEY, direction TEXT NOT NULL, state TEXT NOT NULL, item_id TEXT, parent_id TEXT, name TEXT NOT NULL, local_path TEXT NOT NULL,
                  size INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0, sha256 TEXT, upload_id TEXT, base_version_id TEXT, version_id TEXT, priority INTEGER NOT NULL DEFAULT 0,
                  attempts INTEGER NOT NULL DEFAULT 0, error TEXT, source TEXT NOT NULL DEFAULT 'app', created_at REAL NOT NULL, updated_at REAL NOT NULL, finished_at REAL, ord INTEGER NOT NULL);
                CREATE INDEX transfers_state ON transfers (state, priority DESC, ord);
                -- upload sessions that can be resumed: same destination + same content = same server session
                CREATE TABLE upload_sessions (key TEXT PRIMARY KEY, upload_id TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE conflicts (
                  id TEXT PRIMARY KEY, item_id TEXT NOT NULL, item_name TEXT NOT NULL, copy_id TEXT, copy_name TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
                  detected_at REAL NOT NULL, resolved_at REAL, resolution TEXT);
                """)
                try setMeta("schema", "1")
                try setMeta("generation", UUID().uuidString)
                try setMeta("seq", "0")
            }
        }
    }

    // MARK: Meta
    public func meta(_ key: String) throws -> String? { try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?["value"]?.text }
    public func setMeta(_ key: String, _ value: String?) throws {
        if let value { try db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)]) }
        else { try db.run("DELETE FROM meta WHERE key = ?", [.text(key)]) }
    }
    /// Identity of this mirror: changes when it is rebuilt, which invalidates every anchor derived from `seq`.
    public var generation: String { (try? meta("generation")) ?? "" }
    public var cursor: Int64 { get { Int64((try? meta("cursor")) ?? "0") ?? 0 } }
    public func setCursor(_ c: Int64) throws { try setMeta("cursor", String(c)) }
    public var rootID: String? { try? meta("root") }
    public var lastSync: Date? { (try? meta("last_sync")).flatMap { Double($0 ?? "") }.map(Date.init(timeIntervalSince1970:)) }
    /// Local change counter. Every row written gets the next value; "what changed since N" is `seq > N`.
    public var seq: Int64 { Int64((try? meta("seq")) ?? "0") ?? 0 }
    private func nextSeq() throws -> Int64 { let n = seq + 1; try setMeta("seq", String(n)); return n }

    // MARK: Writing
    private static let columns = "id, kind, parent_id, name, name_key, ext, size, sha256, version_id, version_seq, version_count, content_at, created_at, updated_at, starred, trashed_at, trash_root, rev, scan, thumb, preview_kind, seq"
    /// Stores items as the server described them. An item older than what is known (lower revision) is ignored.
    @discardableResult public func upsert(_ items: [DriveItem]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        return try db.transaction {
            var changed = 0
            for i in items {
                if let known = try db.query("SELECT rev FROM items WHERE id = ?", [.text(i.id)]).first?["rev"]?.int, known >= i.rev, i.rev != 0 { continue }
                let s = try nextSeq()
                try db.run("INSERT OR REPLACE INTO items (\(MetadataStore.columns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(i.id), .text(i.kind.rawValue), i.parentID.map(SQLValue.text) ?? .null, .text(i.name), .text(NameRules.searchKey(i.name)), .text(i.fileExtension),
                    .int(i.size), .text(i.sha256), i.versionID.map(SQLValue.text) ?? .null, .int(Int64(i.versionSeq)), .int(Int64(i.versionCount)),
                    .double(i.contentAt.timeIntervalSince1970), .double(i.createdAt.timeIntervalSince1970), .double(i.updatedAt.timeIntervalSince1970), .int(i.starred ? 1 : 0),
                    i.trashedAt.map { .double($0.timeIntervalSince1970) } ?? .null, .int(i.trashRoot ? 1 : 0), .int(i.rev), .text(i.scan), .int(i.hasThumbnail ? 1 : 0), .text(i.previewKind), .int(s)])
                try db.run("DELETE FROM tombstones WHERE id = ?", [.text(i.id)])
                if i.isRoot { try setMeta("root", i.id) }
                changed += 1
            }
            return changed
        }
    }
    /// Forgets items the server deleted for good, keeping their identifiers as tombstones for the File Provider.
    public func remove(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                let s = try nextSeq()
                try db.run("DELETE FROM items WHERE id = ?", [.text(id)])
                try db.run("INSERT OR REPLACE INTO tombstones (id, seq) VALUES (?, ?)", [.text(id), .int(s)])
                try db.run("DELETE FROM pins WHERE id = ?", [.text(id)])
                try db.run("DELETE FROM local_state WHERE id = ?", [.text(id)])
            }
        }
    }
    /// Applies one page of the change feed and moves the cursor, atomically.
    public func apply(_ page: ChangePage) throws {
        try db.transaction {
            try upsert(page.items); try remove(page.deleted.map(\.id))
            try setCursor(page.cursor); try setMeta("root", page.rootId)
            try setMeta("last_sync", String(Date().timeIntervalSince1970))
        }
    }
    /// Empties the mirror before a full replay (the server went back in time). Pins and the journal are kept.
    public func resetMirror() throws {
        try db.transaction {
            let ids = try db.query("SELECT id FROM items").compactMap { $0["id"]?.text }
            for id in ids { let s = try nextSeq(); try db.run("INSERT OR REPLACE INTO tombstones (id, seq) VALUES (?, ?)", [.text(id), .int(s)]) }
            try db.run("DELETE FROM items"); try setCursor(0)
        }
    }
    /// Marks an item as locally changed so that the File Provider re-reads it (pin toggled, materialisation changed).
    public func touch(_ ids: [String]) throws {
        try db.transaction { for id in ids { let s = try nextSeq(); try db.run("UPDATE items SET seq = ? WHERE id = ?", [.int(s), .text(id)]) } }
    }

    // MARK: Reading
    static func item(_ r: SQLRow) -> DriveItem {
        DriveItem(id: r["id"]?.text ?? "", kind: ItemKind(rawValue: r["kind"]?.text ?? "file") ?? .file, name: r["name"]?.text ?? "", parentID: r["parent_id"]?.text,
                  size: r["size"]?.int ?? 0, sha256: r["sha256"]?.text ?? "", versionID: r["version_id"]?.text, versionSeq: Int(r["version_seq"]?.int ?? 1), versionCount: Int(r["version_count"]?.int ?? 1),
                  contentAt: Date(timeIntervalSince1970: r["content_at"]?.double ?? 0), createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                  updatedAt: Date(timeIntervalSince1970: r["updated_at"]?.double ?? 0), starred: r["starred"]?.bool ?? false, trashedAt: r["trashed_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                  trashRoot: r["trash_root"]?.bool ?? false, rev: r["rev"]?.int ?? 0, scan: r["scan"]?.text ?? "clean", hasThumbnail: r["thumb"]?.bool ?? false, previewKind: r["preview_kind"]?.text ?? "none")
    }
    private func items(_ sql: String, _ v: [SQLValue] = []) throws -> [DriveItem] { try db.query(sql, v).map(MetadataStore.item) }
    /// Every item of the mirror (trashed ones included), in a stable order, by pages.
    public func allItems(limit: Int, offset: Int) throws -> [DriveItem] { try items("SELECT * FROM items ORDER BY id LIMIT ? OFFSET ?", [.int(Int64(limit)), .int(Int64(offset))]) }
    public func item(_ id: String) throws -> DriveItem? { try items("SELECT * FROM items WHERE id = ?", [.text(id)]).first }
    public func root() throws -> DriveItem? { try rootID.flatMap { try item($0) } }
    /// Live children of a folder: folders first, then by name.
    public func children(of parent: String, limit: Int = 100_000, offset: Int = 0) throws -> [DriveItem] {
        try items("SELECT * FROM items WHERE parent_id = ? AND trashed_at IS NULL ORDER BY kind DESC, name_key, id LIMIT ? OFFSET ?", [.text(parent), .int(Int64(limit)), .int(Int64(offset))])
    }
    /// Every child, trashed ones included (what lies inside a trashed folder).
    public func allChildren(of parent: String) throws -> [DriveItem] { try items("SELECT * FROM items WHERE parent_id = ? ORDER BY kind DESC, name_key, id", [.text(parent)]) }
    public func child(of parent: String, named name: String) throws -> DriveItem? {
        try items("SELECT * FROM items WHERE parent_id = ? AND trashed_at IS NULL", [.text(parent)]).first { NameRules.key($0.name) == NameRules.key(name) }
    }
    public func trashRoots() throws -> [DriveItem] { try items("SELECT * FROM items WHERE trash_root = 1 ORDER BY trashed_at DESC") }
    public func recent(limit: Int = 100) throws -> [DriveItem] { try items("SELECT * FROM items WHERE kind = 'file' AND trashed_at IS NULL ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]) }
    public func starred() throws -> [DriveItem] { try items("SELECT * FROM items WHERE starred = 1 AND trashed_at IS NULL ORDER BY kind DESC, name_key") }
    public func largestFiles(limit: Int = 50) throws -> [DriveItem] { try items("SELECT * FROM items WHERE kind = 'file' AND trashed_at IS NULL ORDER BY size DESC LIMIT ?", [.int(Int64(limit))]) }
    /// Path from the root down to the item (the root excluded).
    public func path(to id: String) throws -> [DriveItem] {
        var out: [DriveItem] = [], cur = try item(id), guardN = 0
        while let c = cur, !c.isRoot, guardN < 256 { out.insert(c, at: 0); cur = try c.parentID.flatMap { try item($0) }; guardN += 1 }
        return out
    }
    /// Identifiers of a folder and of everything below it.
    public func subtreeIDs(of folder: String, includeTrashed: Bool = false) throws -> [String] {
        try db.query("""
            WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT i.id FROM items i JOIN sub ON i.parent_id = sub.id \(includeTrashed ? "" : "WHERE i.trashed_at IS NULL"))
            SELECT id FROM sub
            """, [.text(folder)]).compactMap { $0["id"]?.text }
    }
    public func subtreeFiles(of folder: String) throws -> [DriveItem] {
        try items("""
            WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT i.id FROM items i JOIN sub ON i.parent_id = sub.id WHERE i.trashed_at IS NULL AND i.kind = 'folder')
            SELECT i.* FROM items i JOIN sub ON i.parent_id = sub.id WHERE i.kind = 'file' AND i.trashed_at IS NULL
            """, [.text(folder)])
    }
    public struct Counts: Sendable, Equatable {
        public var files: Int; public var folders: Int; public var bytes: Int64; public var trashed: Int
        public init(files: Int, folders: Int, bytes: Int64, trashed: Int) { self.files = files; self.folders = folders; self.bytes = bytes; self.trashed = trashed }
    }
    public func counts() throws -> Counts {
        let r = try db.query("""
            SELECT (SELECT COUNT(*) FROM items WHERE kind='file' AND trashed_at IS NULL) AS files, (SELECT COUNT(*) FROM items WHERE kind='folder' AND trashed_at IS NULL AND parent_id IS NOT NULL) AS folders,
                   (SELECT COALESCE(SUM(size),0) FROM items WHERE kind='file' AND trashed_at IS NULL) AS bytes, (SELECT COUNT(*) FROM items WHERE trashed_at IS NOT NULL) AS trashed
            """).first ?? [:]
        return Counts(files: Int(r["files"]?.int ?? 0), folders: Int(r["folders"]?.int ?? 0), bytes: r["bytes"]?.int ?? 0, trashed: Int(r["trashed"]?.int ?? 0))
    }

    // MARK: Changes since an anchor (File Provider working set)
    public struct LocalChanges: Sendable { public var items: [DriveItem]; public var deleted: [String]; public var seq: Int64; public var more: Bool }
    public func changes(since: Int64, limit: Int = 500) throws -> LocalChanges {
        try db.transaction {
            let rows = try db.query("SELECT * FROM items WHERE seq > ? ORDER BY seq LIMIT ?", [.int(since), .int(Int64(limit + 1))])
            let gone = try db.query("SELECT id, seq FROM tombstones WHERE seq > ? ORDER BY seq LIMIT ?", [.int(since), .int(Int64(limit + 1))])
            // merge both streams by seq and cut at `limit`
            var merged: [(seq: Int64, item: DriveItem?, deleted: String?)] = rows.map { ($0["seq"]?.int ?? 0, MetadataStore.item($0), nil) } + gone.map { ($0["seq"]?.int ?? 0, nil, $0["id"]?.text) }
            merged.sort { $0.seq < $1.seq }
            let more = merged.count > limit
            let page = Array(merged.prefix(limit))
            return LocalChanges(items: page.compactMap(\.item), deleted: page.compactMap(\.deleted), seq: page.last?.seq ?? since, more: more)
        }
    }

    // MARK: Offline pins
    /// Pins or unpins an item itself ("keep available offline"). A pinned folder covers everything below it.
    public func setPinned(_ id: String, _ pinned: Bool) throws {
        try db.transaction {
            if pinned { try db.run("INSERT OR IGNORE INTO pins (id, pinned_at) VALUES (?, ?)", [.text(id), .double(Date().timeIntervalSince1970)]) }
            else { try db.run("DELETE FROM pins WHERE id = ?", [.text(id)]) }
            try touch(try subtreeIDs(of: id))
        }
    }
    public func isPinnedItself(_ id: String) throws -> Bool { try !db.query("SELECT 1 FROM pins WHERE id = ?", [.text(id)]).isEmpty }
    /// True when the item or one of its ancestors is pinned.
    public func isPinned(_ id: String) throws -> Bool {
        try !db.query("""
            WITH RECURSIVE up(id, parent_id, depth) AS (SELECT id, parent_id, 0 FROM items WHERE id = ? UNION ALL SELECT i.id, i.parent_id, up.depth + 1 FROM items i JOIN up ON i.id = up.parent_id WHERE up.depth < 256)
            SELECT 1 FROM up JOIN pins p ON p.id = up.id LIMIT 1
            """, [.text(id)]).isEmpty
    }
    public func pinnedItems() throws -> [DriveItem] { try items("SELECT i.* FROM items i JOIN pins p ON p.id = i.id WHERE i.trashed_at IS NULL ORDER BY i.kind DESC, i.name_key") }
    public func pinnedIDs() throws -> Set<String> { Set(try db.query("SELECT id FROM pins").compactMap { $0["id"]?.text }) }

    // MARK: Local copies (reported by the File Provider)
    public func setMaterialized(_ id: String, _ on: Bool, bytes: Int64) throws {
        try db.run("INSERT INTO local_state (id, materialized, bytes, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET materialized = excluded.materialized, bytes = excluded.bytes, updated_at = excluded.updated_at",
                   [.text(id), .int(on ? 1 : 0), .int(on ? bytes : 0), .double(Date().timeIntervalSince1970)])
    }
    /// Replaces the whole set of materialised items (the File Provider reports it in full).
    public func replaceMaterialized(_ ids: Set<String>) throws {
        try db.transaction {
            try db.run("UPDATE local_state SET materialized = 0, bytes = 0")
            for id in ids {
                let size = try db.query("SELECT size FROM items WHERE id = ? AND kind = 'file'", [.text(id)]).first?["size"]?.int ?? 0
                try setMaterialized(id, true, bytes: size)
            }
        }
    }
    public func materializedIDs() throws -> Set<String> { Set(try db.query("SELECT id FROM local_state WHERE materialized = 1").compactMap { $0["id"]?.text }) }
    public func isMaterialized(_ id: String) throws -> Bool { try !db.query("SELECT 1 FROM local_state WHERE id = ? AND materialized = 1", [.text(id)]).isEmpty }
    public struct LocalUsage: Sendable, Equatable {
        public var files: Int; public var bytes: Int64; public var pinnedBytes: Int64
        public init(files: Int, bytes: Int64, pinnedBytes: Int64) { self.files = files; self.bytes = bytes; self.pinnedBytes = pinnedBytes }
    }
    public func localUsage() throws -> LocalUsage {
        let rows = try db.query("SELECT l.id AS id, i.size AS size FROM local_state l JOIN items i ON i.id = l.id WHERE l.materialized = 1 AND i.kind = 'file'")
        var u = LocalUsage(files: 0, bytes: 0, pinnedBytes: 0)
        for r in rows { let s = r["size"]?.int ?? 0; u.files += 1; u.bytes += s; if let id = r["id"]?.text, try isPinned(id) { u.pinnedBytes += s } }
        return u
    }
    /// Materialised files that no pin covers: the copies "free up space" may evict.
    public func evictableIDs() throws -> [String] { try materializedIDs().filter { try !isPinned($0) }.sorted() }
}
