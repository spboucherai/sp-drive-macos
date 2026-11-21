// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Core/API/Endpoints.swift
// Description      : One method per route of the SP Drive API: account, tree,
//                    change feed, content, resumable uploads at block level,
//                    share links, deposit portals, versions, notifications.
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

public enum ConflictPolicy: String, Codable, Sendable { case fail, rename, version }
public struct Selection: Codable, Sendable {
    public var fileIds: [String]; public var folderIds: [String]
    public init(fileIds: [String] = [], folderIds: [String] = []) { self.fileIds = fileIds; self.folderIds = folderIds }
    public init(_ items: [DriveItem]) { fileIds = items.filter { !$0.isFolder }.map(\.id); folderIds = items.filter(\.isFolder).map(\.id) }
    public var isEmpty: Bool { fileIds.isEmpty && folderIds.isEmpty }
}
/// State of a resumable upload on the server.
public struct UploadSession: Decodable, Sendable {
    public var id: String; public var name: String; public var size: Int64; public var received: Int64; public var status: String; public var fileId: String?
}
public struct UploadResult: Decodable, Sendable { public var id: String; public var status: String; public var file: DriveItem; public var created: Bool? }
public struct SearchQuery: Sendable {
    public var text = ""; public var kind = "any"; public var starred = false; public var from: Date?; public var to: Date?; public var minSize: Int64?; public var maxSize: Int64?
    public init(text: String = "") { self.text = text }
}

extension APIClient {
    // MARK: Account
    public func authState() async throws -> AuthState { try await get("/auth/state") }
    public func logout() async throws { let _: OK = try await send("POST", "/auth/logout") }
    public func sessions() async throws -> [DeviceSession] { try await get("/account/sessions") }
    public func revokeSession(_ id: String) async throws { let _: OK = try await send("DELETE", "/account/sessions/\(id)") }
    public func notifications() async throws -> [ServerNotification] { try await get("/notifications") }
    public func markNotificationsRead(_ ids: [String]? = nil) async throws {
        struct B: Encodable { var ids: [String]? }
        let _: OK = try await send("POST", "/notifications/read", body: B(ids: ids))
    }

    // MARK: Tree
    public func listFolder(_ id: String = "root") async throws -> FolderListing { try await get("/folders/\(id)") }
    public func createFolder(parent: String, name: String, onConflict: ConflictPolicy = .fail) async throws -> DriveItem {
        struct B: Encodable { var parentId: String; var name: String; var onConflict: ConflictPolicy }
        return try await send("POST", "/folders", body: B(parentId: parent, name: name, onConflict: onConflict))
    }
    private struct Patch: Encodable { var name: String?; var starred: Bool? }
    public func updateFolder(_ id: String, name: String? = nil, starred: Bool? = nil) async throws -> DriveItem { try await send("PATCH", "/folders/\(id)", body: Patch(name: name, starred: starred)) }
    public func updateFile(_ id: String, name: String? = nil, starred: Bool? = nil) async throws -> DriveItem { try await send("PATCH", "/files/\(id)", body: Patch(name: name, starred: starred)) }
    public func update(_ item: DriveItem, name: String? = nil, starred: Bool? = nil) async throws -> DriveItem {
        item.isFolder ? try await updateFolder(item.id, name: name, starred: starred) : try await updateFile(item.id, name: name, starred: starred)
    }
    public func fileDetails(_ id: String) async throws -> FileDetails { try await get("/files/\(id)") }
    public func move(_ sel: Selection, to destination: String, onConflict: ConflictPolicy = .fail) async throws {
        struct B: Encodable { var fileIds: [String]; var folderIds: [String]; var destinationId: String; var onConflict: ConflictPolicy }
        let _: OK = try await send("POST", "/move", body: B(fileIds: sel.fileIds, folderIds: sel.folderIds, destinationId: destination, onConflict: onConflict))
    }
    public struct CopyCount: Decodable, Sendable { public var files: Int; public var folders: Int }
    @discardableResult public func copy(_ sel: Selection, to destination: String) async throws -> CopyCount {
        struct B: Encodable { var fileIds: [String]; var folderIds: [String]; var destinationId: String }
        return try await send("POST", "/copy", body: B(fileIds: sel.fileIds, folderIds: sel.folderIds, destinationId: destination))
    }
    public func trash(_ sel: Selection) async throws { let _: OK = try await send("POST", "/trash", body: sel) }
    public func restore(_ sel: Selection) async throws { let _: OK = try await send("POST", "/restore", body: sel) }
    /// Deletes trashed items for good. Only ever called after an explicit confirmation by the person.
    public func purge(_ sel: Selection) async throws { let _: OK = try await send("POST", "/purge", body: sel) }
    public func emptyTrash() async throws { struct B: Encodable { var all = true }; let _: OK = try await send("POST", "/purge", body: B()) }
    public func trashList() async throws -> ItemList { try await get("/trash") }
    public func recent() async throws -> ItemList { try await get("/recent") }
    public func starred() async throws -> ItemList { try await get("/starred") }
    public func search(_ q: SearchQuery) async throws -> ItemList {
        let day: (Date) -> String = { $0.formatted(.iso8601.year().month().day()) }
        return try await get("/search", query: ["q": q.text, "kind": q.kind, "starred": q.starred ? "1" : nil, "from": q.from.map(day), "to": q.to.map(day),
                                                 "minSize": q.minSize.map(String.init), "maxSize": q.maxSize.map(String.init)])
    }

    // MARK: Change feed
    public func syncCursor() async throws -> SyncCursor { try await get("/sync/cursor") }
    public func changes(since: Int64, limit: Int = 1000) async throws -> ChangePage { try await get("/sync/changes", query: ["since": String(since), "limit": String(limit)]) }
    /// Current state of the given items, trashed ones included; unknown identifiers are absent from the answer.
    public func items(_ sel: Selection) async throws -> ItemList { try await send("POST", "/sync/items", body: sel) }
    public func item(_ id: String, kind: ItemKind) async throws -> DriveItem? {
        try await items(kind == .file ? Selection(fileIds: [id]) : Selection(folderIds: [id])).all.first
    }

    // MARK: Content
    /// Request for a file's bytes. `from` resumes a partial download: the `If-Range` condition makes the server send the
    /// whole file again when the content changed meanwhile (the ETag is the SHA-256 of the content).
    public func contentRequest(fileID: String, versionID: String? = nil, from offset: Int64 = 0, etag: String? = nil) throws -> URLRequest {
        var headers: [String: String] = [:]
        if offset > 0 { headers["Range"] = "bytes=\(offset)-"; if let etag { headers["If-Range"] = "\"\(etag)\"" } }
        var r = try request("GET", "/files/\(fileID)/content", query: ["download": "1", "v": versionID], headers: headers)
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        return r
    }
    public func thumbnailRequest(fileID: String) throws -> URLRequest {
        var r = try request("GET", "/files/\(fileID)/preview/thumb"); r.setValue("image/jpeg", forHTTPHeaderField: "Accept"); return r
    }

    // MARK: Resumable uploads (block level)
    /// Opens an upload. With `fileID` the bytes become a new version of that file; `baseVersionID` is the version they were
    /// derived from, and the server answers `version_conflict` when it is no longer the current one.
    public func createUpload(folderID: String, name: String, size: Int64, onConflict: ConflictPolicy = .rename, fileID: String? = nil, baseVersionID: String? = nil) async throws -> UploadSession {
        struct B: Encodable { var folderId: String; var name: String; var size: Int64; var onConflict: ConflictPolicy; var fileId: String?; var baseVersionId: String? }
        return try await send("POST", "/uploads", body: B(folderId: folderID, name: name, size: size, onConflict: onConflict, fileId: fileID, baseVersionId: baseVersionID))
    }
    public func uploadStatus(_ id: String) async throws -> UploadSession { try await get("/uploads/\(id)") }
    /// Request that appends one block at `offset`. The body is given separately (`upload(for:from:)` or a background upload task from a file).
    public func chunkRequest(uploadID: String, offset: Int64, sha256: String?) throws -> URLRequest {
        var r = try request("PATCH", "/uploads/\(uploadID)", query: ["offset": String(offset)])
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let sha256 { r.setValue(sha256, forHTTPHeaderField: "X-Chunk-SHA256") }
        return r
    }
    public func completeUpload(_ id: String, sha256: String) async throws -> UploadResult {
        struct B: Encodable { var sha256: String }
        return try await send("POST", "/uploads/\(id)/complete", body: B(sha256: sha256))
    }
    /// Turns a refused new version into a separate file next to the original (the bytes already received are kept).
    public func convertUploadToNewFile(_ id: String, name: String) async throws {
        struct N: Encodable { var name: String }; struct B: Encodable { var asNewFile: N }
        let _: OK = try await send("PATCH", "/uploads/\(id)/options", body: B(asNewFile: N(name: name)))
    }
    public func abortUpload(_ id: String) async throws { let _: OK = try await send("DELETE", "/uploads/\(id)") }

    // MARK: Versions
    public func restoreVersion(fileID: String, versionID: String) async throws -> DriveItem { try await send("POST", "/files/\(fileID)/versions/\(versionID)/restore") }
    public func deleteVersion(fileID: String, versionID: String) async throws { let _: OK = try await send("DELETE", "/files/\(fileID)/versions/\(versionID)") }

    // MARK: Share links
    public struct CreatedShare: Decodable, Sendable { public var share: ShareLink; public var url: URL }
    public struct LinkURL: Decodable, Sendable { public var url: URL }
    public func shares(of item: DriveItem? = nil) async throws -> [ShareLink] {
        try await get("/shares", query: ["fileId": item?.isFolder == false ? item?.id : nil, "folderId": item?.isFolder == true ? item?.id : nil])
    }
    private struct ShareBody: Encodable { var settings: ShareSettings; var target: (kind: ItemKind, id: String)?; func encode(to e: Encoder) throws { try settings.encode(to: e, target: target) } }
    /// Creates a link. Its address is returned here and never again: only a hash is kept by the server.
    public func createShare(for item: DriveItem, settings: ShareSettings) async throws -> CreatedShare {
        try await send("POST", "/shares", body: ShareBody(settings: settings, target: (item.kind, item.id)))
    }
    public func updateShare(_ id: String, settings: ShareSettings) async throws -> ShareLink { try await send("PATCH", "/shares/\(id)", body: ShareBody(settings: settings, target: nil)) }
    public func revokeShare(_ id: String, delete: Bool = false) async throws { let _: OK = try await send("DELETE", "/shares/\(id)", query: ["purge": delete ? "1" : nil]) }
    public func rotateShare(_ id: String) async throws -> URL { let r: LinkURL = try await send("POST", "/shares/\(id)/rotate"); return r.url }
    public func shareEvents(_ id: String) async throws -> [ShareAccessEvent] { try await get("/shares/\(id)/events") }

    // MARK: Deposit portals
    public struct CreatedPortal: Decodable, Sendable { public var request: DepositPortal; public var url: URL }
    public func portals() async throws -> [DepositPortal] { try await get("/requests") }
    public func createPortal(_ settings: PortalSettings) async throws -> CreatedPortal { try await send("POST", "/requests", body: settings) }
    public func updatePortal(_ id: String, _ settings: PortalSettings) async throws -> DepositPortal { try await send("PATCH", "/requests/\(id)", body: settings) }
    public func revokePortal(_ id: String, delete: Bool = false) async throws { let _: OK = try await send("DELETE", "/requests/\(id)", query: ["purge": delete ? "1" : nil]) }
    public func rotatePortal(_ id: String) async throws -> URL { let r: LinkURL = try await send("POST", "/requests/\(id)/rotate"); return r.url }
    public func portalSubmissions(_ id: String) async throws -> [PortalSubmission] { try await get("/requests/\(id)/submissions") }
}
