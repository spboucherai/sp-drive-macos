// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Next/Calls.swift
// Description      : SPDriveNext — one async call per endpoint of the SP Drive
//                    2.0 API (API-NEXT.md §2–§8): capabilities, sync events,
//                    search, document intelligence, private sharing (owner and
//                    grantee routes, including downloads and resumable uploads
//                    through a grant), collections, activity, storage,
//                    duplicates, versions, upload history, sessions, account,
//                    administration.
// Module           : Next
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-19
// Last Modified    : 2026-11-19
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

import CryptoKit
import Foundation

extension NextClient {
    // MARK: §2 Capabilities, sessions, account
    /// What the server can do. A 1.0 server (404) is reported as `ServerMeta.v1`.
    public func meta() async throws -> ServerMeta {
        do { return try await get("/meta", authenticated: false) }
        catch let e as NextError where e.isNotFound { return .v1 }
    }
    public func sessions() async throws -> [NextSession] { try await get("/account/sessions") }
    public func revokeSession(_ id: String) async throws { let _: OK = try await send("DELETE", "/account/sessions/\(id)") }
    public func updateAccount(_ patch: AccountPatch) async throws { let _: OK = try await send("PATCH", "/account", body: patch) }
    /// The account's own switch for external AI providers.
    public func setExternalAI(_ allowed: Bool) async throws { try await updateAccount(AccountPatch(aiExternal: allowed)) }

    // MARK: §3 Sync events
    /// One connection to `GET /sync/events`. Finishes when the server closes it, throws when it fails; reconnecting
    /// (exponential back-off with jitter, 1 s → 60 s) and the polling fallback are the caller's.
    /// - Parameter idleTimeout: the server pings every 25 s; a stream silent for longer than this is treated as dead.
    public func syncEvents(idleTimeout: Double = 60) -> AsyncThrowingStream<SyncEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    struct Head: Decodable { var head: Int64 }; struct Kind: Decodable { var kind: String }
                    let req = try await request("GET", "/sync/events")
                    for try await m in events(req, idleTimeout: idleTimeout) {
                        let d = Data(m.data.utf8)
                        switch m.event {
                        case "hello": if let h = try? JSONDecoder().decode(Head.self, from: d) { continuation.yield(.hello(head: h.head)) }
                        case "change": if let h = try? JSONDecoder().decode(Head.self, from: d) { continuation.yield(.change(head: h.head)) }
                        case "notify": if let k = try? JSONDecoder().decode(Kind.self, from: d) { continuation.yield(.notify(kind: k.kind)) }
                        default: break
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: NextError.wrap(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: §4 Search
    /// Names and content of the caller's own files (shared folders are browsed, not searched). Every hit carries `match`.
    public func search(_ p: SearchParameters) async throws -> SearchResults {
        try await get("/search", query: ["q": p.q, "in": p.scope.rawValue, "kind": p.kind, "starred": p.starred == true ? "1" : nil,
                                         "from": p.from.map(NextClient.isoString), "to": p.to.map(NextClient.isoString),
                                         "minSize": p.minSize.map(String.init), "maxSize": p.maxSize.map(String.init), "sort": p.sort, "dir": p.dir])
    }
    public func search(_ q: String, in scope: SearchScope = .all) async throws -> SearchResults { try await search(SearchParameters(q: q, scope: scope)) }
    /// Nearest passages by meaning. `available == false` when the server has no embedding model right now; the server
    /// may also answer `503 busy` (thrown as `NextError`, see `retryAfterSeconds`) when its local model has a queue.
    public func semanticSearch(_ q: String, limit: Int = 10) async throws -> SemanticResults { try await get("/search/semantic", query: ["q": q, "limit": String(limit)]) }
    public func fileText(_ fileID: String) async throws -> FileTextStatus { try await get("/files/\(fileID)/text") }
    public func indexStatus() async throws -> IndexStatus { try await get("/index/status") }

    // MARK: §5 Document intelligence
    public func aiProviders() async throws -> AIProviders { try await get("/ai/providers") }
    /// Asks a question about files, a folder or the whole Drive. Errors before the answer starts are thrown as
    /// `NextError` (`ai_unavailable`, `ai_external_disabled`, `provider_not_configured`…); a failure of the model
    /// during the answer arrives as `.error`. Cancelling the consuming task cancels the model call.
    public func aiAsk(_ ask: AIAskRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    struct Notice: Decodable { var unindexed: [AIUnindexed] }; struct Delta: Decodable { var text: String }; struct Failure: Decodable { var code: String; var message: String? }
                    let req = try await request("POST", "/ai/ask", body: try NextClient.encoder.encode(ask))
                    for try await m in events(req) {
                        let d = Data(m.data.utf8)
                        switch m.event {
                        case "notice": if let n = try? JSONDecoder().decode(Notice.self, from: d) { continuation.yield(.notice(unindexed: n.unindexed)) }
                        case "sources": continuation.yield(.sources((try? JSONDecoder().decode([AISource].self, from: d)) ?? []))
                        case "delta": if let t = try? JSONDecoder().decode(Delta.self, from: d) { continuation.yield(.delta(t.text)) }
                        case "done": continuation.yield(.done((try? JSONDecoder().decode(AIDone.self, from: d)) ?? AIDone(empty: nil)))
                        case "error": let f = try? JSONDecoder().decode(Failure.self, from: d); continuation.yield(.error(code: f?.code ?? "provider_error", message: f?.message ?? ""))
                        default: break
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: NextError.wrap(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    /// Proposals of name, tags, folder and category. Nothing is applied by the server.
    public func aiSuggest(fileIDs: [String], provider: String? = nil, model: String? = nil) async throws -> AISuggestions {
        struct B: Encodable { var fileIds: [String]; var provider: String?; var model: String? }
        return try await send("POST", "/ai/suggest", body: B(fileIds: fileIDs, provider: provider, model: model))
    }

    // MARK: §6.1 Private sharing — the owner's side
    /// Finds an account by its exact e-mail address (rate-limited; 404 for an unknown address or one's own).
    public func resolveUser(email: String) async throws -> ResolvedUser { struct B: Encodable { var email: String }; return try await send("POST", "/collab/resolve", body: B(email: email)) }
    public func members(of folderID: String) async throws -> FolderMembers { try await get("/folders/\(folderID)/members") }
    /// Gives an account access to a folder, **by its e-mail address** (API-NEXT D18: the server no longer accepts an
    /// account identifier here). `userID` is kept in the signature for source compatibility and is ignored: a call
    /// without `email` throws `invalid_request` without reaching the server.
    public func addMember(to folderID: String, userID: String? = nil, email: String? = nil, role: GrantRole, workspaceName: String? = nil) async throws -> FolderMember {
        guard let email, !email.isEmpty else { throw NextError.server(status: 400, code: "invalid_request", message: "an e-mail address is required to add a member", extra: [:]) }
        struct B: Encodable { var email: String; var role: GrantRole; var workspaceName: String? }
        return try await send("POST", "/folders/\(folderID)/members", body: B(email: email, role: role, workspaceName: workspaceName))
    }
    /// Gives an account access to a folder by its exact e-mail address.
    public func addMember(to folderID: String, email: String, as role: GrantRole, workspaceName: String? = nil) async throws -> FolderMember {
        try await addMember(to: folderID, userID: nil, email: email, role: role, workspaceName: workspaceName)
    }
    public func updateMember(of folderID: String, userID: String, role: GrantRole) async throws -> FolderMember {
        struct B: Encodable { var role: GrantRole }
        return try await send("PATCH", "/folders/\(folderID)/members/\(userID)", body: B(role: role))
    }
    public func removeMember(of folderID: String, userID: String) async throws { let _: OK = try await send("DELETE", "/folders/\(folderID)/members/\(userID)") }
    /// Names the shared folder as a workspace (nil removes the name).
    public func setWorkspaceName(of folderID: String, _ name: String?) async throws -> NextFolder {
        let body = try JSONSerialization.data(withJSONObject: ["name": name as Any? ?? NSNull()])
        return try decode(NextFolder.self, try await data(for: try await request("PATCH", "/folders/\(folderID)/workspace", body: body)).0)
    }
    /// Folders the caller shares with members.
    public func outgoingShares() async throws -> [OutgoingShare] { try await get("/collab/outgoing") }

    // MARK: §6.2 Private sharing — the member's side
    public func sharedWithMe() async throws -> [SharedGrant] { try await get("/shared-with-me") }
    /// The reduced activity feed a member may read (API-NEXT D19): a few actions, since the grant, live items only,
    /// people by display name (`actor.userId` is nil), almost no `meta`.
    /// Lists a folder of a grant (nil = the granted folder). Viewer and editor; an uploader gets 403 (`isForbidden`).
    public func sharedChildren(grant: String, folderID: String? = nil) async throws -> SharedListing { try await get("/shared/\(grant)/children", query: ["folderId": folderID]) }
    public func sharedFile(grant: String, fileID: String) async throws -> SharedFileDetails { try await get("/shared/\(grant)/files/\(fileID)") }
    /// Request for the bytes of a shared file (`Range` supported through `from`).
    public func sharedContentRequest(grant: String, fileID: String, from offset: Int64 = 0, download: Bool = true) async throws -> URLRequest {
        var r = try await request("GET", "/shared/\(grant)/files/\(fileID)/content", query: ["download": download ? "1" : nil], headers: offset > 0 ? ["Range": "bytes=\(offset)-"] : [:])
        r.setValue("*/*", forHTTPHeaderField: "Accept"); return r
    }
    /// kind: thumb, image, pdf…
    public func sharedPreviewRequest(grant: String, fileID: String, kind: String = "thumb") async throws -> URLRequest {
        var r = try await request("GET", "/shared/\(grant)/files/\(fileID)/preview/\(kind)"); r.setValue("*/*", forHTTPHeaderField: "Accept"); return r
    }
    /// Downloads a shared file to `destination` (streamed to disk by URLSession, moved into place) and returns its SHA-256.
    @discardableResult public func downloadShared(grant: String, fileID: String, to destination: URL) async throws -> String {
        try await download(try await sharedContentRequest(grant: grant, fileID: fileID), to: destination)
    }
    public func sharedActivity(grant: String, before: String? = nil, limit: Int = 50) async throws -> ActivityPage { try await get("/shared/\(grant)/activity", query: ["before": before, "limit": String(limit)]) }
    public func sharedCreateFolder(grant: String, parentID: String? = nil, name: String, onConflict: String = "rename") async throws -> NextFolder {
        struct B: Encodable { var parentId: String?; var name: String; var onConflict: String }
        return try await send("POST", "/shared/\(grant)/folders", body: B(parentId: parentID, name: name, onConflict: onConflict))
    }
    /// Renames and/or moves a file or a folder inside the grant (editor).
    public func sharedUpdateItem(grant: String, itemID: String, name: String? = nil, parentID: String? = nil, onConflict: String? = nil) async throws -> SharedItem {
        struct B: Encodable { var name: String?; var parentId: String?; var onConflict: String? }
        let d = try await data(for: try await request("PATCH", "/shared/\(grant)/items/\(itemID)", body: try NextClient.encoder.encode(B(name: name, parentId: parentID, onConflict: onConflict)))).0
        struct T: Decodable { var type: String? }
        if (try? JSONDecoder().decode(T.self, from: d))?.type == "folder" { return .folder(try decode(NextFolder.self, d)) }
        return .file(try decode(NextFile.self, d))
    }
    /// Sends items of the grant to the OWNER's trash (editor). Only the owner restores or purges.
    public func sharedTrash(grant: String, fileIDs: [String] = [], folderIDs: [String] = []) async throws {
        struct B: Encodable { var fileIds: [String]; var folderIds: [String] }
        let _: OK = try await send("POST", "/shared/\(grant)/trash", body: B(fileIds: fileIDs, folderIds: folderIDs))
    }
    // resumable uploads through a grant (editor, uploader) — the same protocol as the owner's /uploads
    /// - Parameter onConflict: rename (default) | fail | version. An uploader may only use rename.
    public func sharedCreateUpload(grant: String, folderID: String? = nil, name: String, size: Int64, onConflict: String? = nil) async throws -> NextUpload {
        struct B: Encodable { var folderId: String?; var name: String; var size: Int64; var onConflict: String? }
        return try await send("POST", "/shared/\(grant)/uploads", body: B(folderId: folderID, name: name, size: size, onConflict: onConflict))
    }
    public func sharedUpload(grant: String, id: String) async throws -> NextUpload { try await get("/shared/\(grant)/uploads/\(id)") }
    public func sharedAppend(grant: String, id: String, offset: Int64, chunk: Data) async throws -> NextUpload {
        let r = try await request("PATCH", "/shared/\(grant)/uploads/\(id)", query: ["offset": String(offset)], body: chunk, contentType: "application/octet-stream",
                                  headers: ["X-Chunk-SHA256": SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined()])
        return try decode(NextUpload.self, try await data(for: r).0)
    }
    public func sharedCompleteUpload(grant: String, id: String, sha256: String?) async throws -> NextUploadResult {
        struct B: Encodable { var sha256: String? }
        return try await send("POST", "/shared/\(grant)/uploads/\(id)/complete", body: B(sha256: sha256))
    }
    public func sharedAbortUpload(grant: String, id: String) async throws { let _: OK = try await send("DELETE", "/shared/\(grant)/uploads/\(id)") }
    /// Sends a local file into a grant: read block by block, each block with its SHA-256, the whole-file SHA-256
    /// confirmed by the server at the end. `resume` continues an upload opened earlier (same file) from the offset the
    /// server reports. Bytes count against the owner's quota.
    @discardableResult public func uploadShared(grant: String, file url: URL, folderID: String? = nil, name: String? = nil, onConflict: String? = nil, resume uploadID: String? = nil,
                                               chunkSize: Int = 4 * 1024 * 1024, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> NextUploadResult {
        let size = ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.int64Value ?? 0
        var upload: NextUpload
        if let uploadID, let known = try? await sharedUpload(grant: grant, id: uploadID), known.size == size, known.status == "active" { upload = known }
        else { upload = try await sharedCreateUpload(grant: grant, folderID: folderID, name: name ?? url.lastPathComponent, size: size, onConflict: onConflict) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        // the whole-file hash covers what was sent before a resume too
        var hashed: Int64 = 0
        while hashed < upload.received, let d = try handle.read(upToCount: Int(min(Int64(chunkSize), upload.received - hashed))), !d.isEmpty { hasher.update(data: d); hashed += Int64(d.count) }
        var offset = upload.received
        progress(offset, size)
        while offset < size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: Int(min(Int64(chunkSize), size - offset))), !chunk.isEmpty else { throw NextError.invalidResponse("file shorter than announced") }
            do { upload = try await sharedAppend(grant: grant, id: upload.id, offset: offset, chunk: chunk) }
            catch let e as NextError where e.code == "offset_mismatch" {
                // the server knows where it is: follow it (hash again from the start to stay exact)
                guard let r = e.extra["received"]?.double.map({ Int64($0) }) else { throw e }
                offset = r; hasher = SHA256(); try handle.seek(toOffset: 0); hashed = 0
                while hashed < offset, let d = try handle.read(upToCount: Int(min(Int64(chunkSize), offset - hashed))), !d.isEmpty { hasher.update(data: d); hashed += Int64(d.count) }
                continue
            }
            hasher.update(data: chunk); offset = upload.received
            progress(offset, size)
        }
        return try await sharedCompleteUpload(grant: grant, id: upload.id, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    // MARK: §7.1 Collections
    public func collections() async throws -> [SmartCollection] { try await get("/collections") }
    public func createCollection(_ draft: CollectionDraft) async throws -> SmartCollection { try await send("POST", "/collections", body: draft) }
    public func updateCollection(_ id: String, _ draft: CollectionDraft) async throws -> SmartCollection { try await send("PATCH", "/collections/\(id)", body: draft) }
    public func deleteCollection(_ id: String) async throws { let _: OK = try await send("DELETE", "/collections/\(id)") }
    public func collectionItems(_ id: String, limit: Int = 200, offset: Int = 0) async throws -> CollectionItems { try await get("/collections/\(id)/items", query: ["limit": String(limit), "offset": String(offset)]) }
    /// Runs a rule without saving it.
    public func previewCollection(_ rule: CollectionRule, limit: Int = 50) async throws -> CollectionItems {
        struct B: Encodable { var rule: CollectionRule; var limit: Int }
        return try await send("POST", "/collections/preview", body: B(rule: rule, limit: limit))
    }

    // MARK: §7.2 Activity
    public func fileActivity(_ fileID: String, before: String? = nil, limit: Int = 50) async throws -> ActivityPage { try await get("/files/\(fileID)/activity", query: ["before": before, "limit": String(limit)]) }
    public func accountActivity(before: String? = nil, limit: Int = 50) async throws -> ActivityPage { try await get("/activity", query: ["before": before, "limit": String(limit)]) }
    /// The folder and everything below it, members' actions included (owner only).
    public func folderActivity(_ folderID: String, before: String? = nil, limit: Int = 50) async throws -> ActivityPage { try await get("/folders/\(folderID)/activity", query: ["before": before, "limit": String(limit)]) }

    // MARK: §7.3 Storage, §7.4 Duplicates
    public func storageOverview() async throws -> StorageOverview { try await get("/storage/overview") }
    /// `folderID` or "root".
    public func storageFolder(_ folderID: String = "root") async throws -> StorageFolder { try await get("/storage/folder/\(folderID)") }
    /// Never deletes anything. `distance` (0–16, default 6) applies to similar images.
    public func duplicates(_ mode: DuplicateMode = .exact, distance: Int? = nil) async throws -> Duplicates { try await get("/duplicates", query: ["mode": mode.rawValue, "distance": distance.map(String.init)]) }

    // MARK: §7.5 Versions, §7.6 Upload history
    public func versions(of fileID: String) async throws -> VersionList { try await get("/files/\(fileID)/versions") }
    public func versionContentRequest(fileID: String, versionID: String, download: Bool = false) async throws -> URLRequest {
        var r = try await request("GET", "/files/\(fileID)/versions/\(versionID)/content", query: ["download": download ? "1" : nil]); r.setValue("*/*", forHTTPHeaderField: "Accept"); return r
    }
    /// Downloads one version to `destination`; returns its SHA-256 (compare with `VersionInfo.sha256`).
    @discardableResult public func downloadVersion(fileID: String, versionID: String, to destination: URL) async throws -> String {
        try await download(try await versionContentRequest(fileID: fileID, versionID: versionID), to: destination)
    }
    /// The old content becomes a NEW current version; every existing version is kept. Returns the file.
    public func restoreVersion(fileID: String, versionID: String) async throws -> NextFile { try await send("POST", "/files/\(fileID)/versions/\(versionID)/restore") }
    /// state: recent | active
    public func uploadHistory(state: String = "recent", limit: Int = 200) async throws -> [NextUpload] {
        let h: UploadHistory = try await get("/uploads", query: ["state": state, "limit": String(limit)]); return h.uploads
    }

    // MARK: §8 Administration
    /// Administrators only (404 for anyone else).
    public func adminSystem() async throws -> AdminSystem {
        let d = try await data(for: try await request("GET", "/admin/system")).0
        let raw = try decode([String: NextJSON].self, d)
        func part<T: Decodable>(_ key: String, _ type: T.Type) -> T? { raw[key].flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
        return AdminSystem(version: raw["version"]?.string, features: raw["features"]?.array?.compactMap(\.string) ?? [], worker: part("worker", AdminSystem.Worker.self),
                           jobs: part("jobs", [AdminSystem.Job].self) ?? [], previewFailures: part("previewFailures", [AdminSystem.PreviewFailure].self) ?? [], raw: raw)
    }

    // MARK: Downloads
    /// Streams a response body to a temporary file, moves it to `destination`, and returns the SHA-256 of what was stored.
    @discardableResult public func download(_ request: URLRequest, to destination: URL) async throws -> String {
        do {
            let (tmp, response) = try await transport.session.download(for: request)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { try NextClient.check((try? Data(contentsOf: tmp)) ?? Data(), response) }
            var hasher = SHA256()
            let h = try FileHandle(forReadingFrom: tmp); defer { try? h.close() }
            while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { throw NextError.wrap(error) }
    }
}
