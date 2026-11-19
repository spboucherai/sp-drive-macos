// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/ConflictResolver.swift
// Description: Conflicts between this device and the server: each one is recorded with the copy that preserved the local content, and resolved by an explicit choice — keep both, keep mine, keep the server's — none of which deletes anything for good.
import Foundation
import SPDriveCore

public struct SyncConflict: Sendable, Identifiable, Hashable {
    public var id: String
    /// The file that was changed on two devices.
    public var itemID: String
    public var itemName: String
    /// The copy holding this device's content.
    public var copyID: String?
    public var copyName: String
    /// "content" (edited on two devices), "edit_delete" (edited here, deleted elsewhere).
    public var kind: String
    public var detail: String
    public var detectedAt: Date
    public var resolvedAt: Date?
    public var resolution: String?
    public var isOpen: Bool { resolvedAt == nil }
}
public enum ConflictChoice: String, Sendable, CaseIterable {
    /// Both files stay, side by side.
    case keepBoth
    /// This device's content takes the original's place; the server's version goes to the trash.
    case keepMine
    /// The server's version stays; this device's copy goes to the trash.
    case keepServer
}

public struct ConflictResolver: Sendable {
    public let api: APIClient
    public let store: MetadataStore
    public init(api: APIClient, store: MetadataStore) { self.api = api; self.store = store }

    @discardableResult public func record(itemID: String, itemName: String, copy: DriveItem?, kind: String = "content", detail: String = "") throws -> SyncConflict {
        let c = SyncConflict(id: UUID().uuidString, itemID: itemID, itemName: itemName, copyID: copy?.id, copyName: copy?.name ?? "", kind: kind, detail: detail, detectedAt: Date(), resolvedAt: nil, resolution: nil)
        try store.db.run("INSERT INTO conflicts (id, item_id, item_name, copy_id, copy_name, kind, detail, detected_at) VALUES (?,?,?,?,?,?,?,?)",
                         [.text(c.id), .text(itemID), .text(itemName), copy.map { .text($0.id) } ?? .null, .text(c.copyName), .text(kind), .text(detail), .double(c.detectedAt.timeIntervalSince1970)])
        return c
    }
    private static func conflict(_ r: SQLRow) -> SyncConflict {
        SyncConflict(id: r["id"]?.text ?? "", itemID: r["item_id"]?.text ?? "", itemName: r["item_name"]?.text ?? "", copyID: r["copy_id"]?.text, copyName: r["copy_name"]?.text ?? "",
                     kind: r["kind"]?.text ?? "content", detail: r["detail"]?.text ?? "", detectedAt: Date(timeIntervalSince1970: r["detected_at"]?.double ?? 0),
                     resolvedAt: r["resolved_at"]?.double.map(Date.init(timeIntervalSince1970:)), resolution: r["resolution"]?.text)
    }
    public func conflicts(openOnly: Bool = false) throws -> [SyncConflict] {
        try store.db.query("SELECT * FROM conflicts \(openOnly ? "WHERE resolved_at IS NULL" : "") ORDER BY detected_at DESC LIMIT 500").map(ConflictResolver.conflict)
    }
    public func openCount() throws -> Int { Int(try store.db.scalar("SELECT COUNT(*) FROM conflicts WHERE resolved_at IS NULL").int ?? 0) }

    /// Applies the person's choice. Whatever is set aside goes to the trash of SP Drive, from which it can be restored.
    public func resolve(_ c: SyncConflict, _ choice: ConflictChoice) async throws {
        switch choice {
        case .keepBoth: break
        case .keepServer:
            if let copy = c.copyID, try await api.item(copy, kind: .file)?.isTrashed == false { try await api.trash(Selection(fileIds: [copy])) }
        case .keepMine:
            guard let copy = c.copyID, let mine = try await api.item(copy, kind: .file), !mine.isTrashed else { throw DriveError.local("la copie de cet appareil n’existe plus") }
            if let original = try await api.item(c.itemID, kind: .file), !original.isTrashed {
                try await api.trash(Selection(fileIds: [original.id]))
                if original.parentID != mine.parentID, let p = original.parentID { try await api.move(Selection(fileIds: [copy]), to: p, onConflict: .rename) }
            }
            _ = try await api.updateFile(copy, name: c.itemName)
        }
        try store.db.run("UPDATE conflicts SET resolved_at = ?, resolution = ? WHERE id = ?", [.double(Date().timeIntervalSince1970), .text(choice.rawValue), .text(c.id)])
    }
    /// "Keep mine" without losing the file's history: this device's content becomes the **new current version** of the
    /// original file (the server's version stays in its version history, restorable), and the conflict copy goes to the
    /// trash. The upload names the version it replaces: if the file changed yet again meanwhile, nothing is overwritten
    /// and `version_conflict` is thrown so that the person looks again.
    @discardableResult public func resolveKeepingMineAsNewVersion(_ c: SyncConflict, workDirectory: URL, deviceName: String) async throws -> DriveItem {
        guard let copyID = c.copyID, let mine = try await api.item(copyID, kind: .file), !mine.isTrashed else { throw DriveError.local("la copie de cet appareil n’existe plus") }
        guard let original = try await api.item(c.itemID, kind: .file), !original.isTrashed else {
            // the original is gone: there is no history to extend; this device's copy simply takes the name
            try await resolve(c, .keepMine)
            return try await api.item(copyID, kind: .file) ?? mine
        }
        var result = original
        if mine.sha256 != original.sha256 {
            let dir = workDirectory.appendingPathComponent("conflicts/\(c.id)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let local = try PathSafety.child(of: dir, named: "content")
            try await DownloadEngine(api: api).download(fileID: mine.id, versionID: mine.versionID, sha256: mine.sha256, size: mine.size, to: local, partial: dir.appendingPathComponent("content.part"))
            let outcome = try await UploadEngine(api: api, store: nil, deviceName: deviceName)
                .upload(file: local, to: .newVersion(fileID: original.id, folderID: original.parentID ?? "root", name: original.name, baseVersionID: original.versionID))
            guard case .stored(let updated) = outcome else {
                // changed again while we were deciding: the engine made a second copy of the same bytes — one is enough
                try? await api.trash(Selection(fileIds: [outcome.item.id]))
                throw DriveError.server(status: 409, code: "version_conflict", message: "", extra: [:])
            }
            result = updated
        }
        try await api.trash(Selection(fileIds: [copyID]))
        _ = try? store.upsert([result])
        try store.db.run("UPDATE conflicts SET resolved_at = ?, resolution = ? WHERE id = ?", [.double(Date().timeIntervalSince1970), .text("keepMineVersion"), .text(c.id)])
        return result
    }
}
