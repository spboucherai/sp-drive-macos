// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : FileProviderExtension/DriveServices.swift
// Description      : The engine objects of the File Provider extension for the
//                    signed-in account (API, mirror, transfer engines), and the
//                    translation between SP Drive errors and the errors the
//                    system understands.
// Module           : FileProviderExtension
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-18
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

import FileProvider
import Foundation
import OSLog
import SPDriveCore
import SPDriveSync

final class DriveServices: Sendable {
    let api: APIClient
    let store: MetadataStore
    let uploader: UploadEngine
    let downloader: DownloadEngine
    let detector: ChangeDetector
    let conflicts: ConflictResolver
    static let log = Logger(subsystem: AppEnvironment.appBundleID, category: "fileprovider")

    /// Throws `.notAuthenticated` when nobody is signed in on this Mac: the system then shows the location as needing sign-in.
    init() throws {
        guard let store = try AppEnvironment.openStore(), (try? AppEnvironment.tokens.readToken()) != nil else { throw NSFileProviderError(.notAuthenticated) }
        self.store = store
        api = try AppEnvironment.makeAPI()
        uploader = UploadEngine(api: api, store: store, deviceName: AppEnvironment.deviceName)
        downloader = DownloadEngine(api: api)
        detector = ChangeDetector(api: api, store: store)
        conflicts = ConflictResolver(api: api, store: store)
    }

    var rootID: String? { store.rootID }
    func requireRoot() async throws -> String {
        if let r = store.rootID { return r }
        let c = try await api.syncCursor()
        try store.setMeta("root", c.rootId)
        return c.rootId
    }
    func fpItem(_ item: DriveItem) -> FileProviderItem? {
        guard let root = store.rootID else { return nil }
        return FileProviderItem(item, rootID: root, pinned: (try? store.isPinned(item.id)) ?? false, shared: sharedIDs().contains(item.id))
    }
    /// Items with an active share link, as last written by the application (`shared_ids` in the mirror); re-read at most every two seconds.
    private let sharedCache = SharedCache()
    final class SharedCache: @unchecked Sendable { let lock = NSLock(); var ids: Set<String> = []; var at = Date.distantPast }
    func sharedIDs() -> Set<String> {
        sharedCache.lock.withLock {
            if Date().timeIntervalSince(sharedCache.at) > 2 {
                sharedCache.ids = Set(((try? store.meta("shared_ids")) ?? nil ?? "").split(separator: ",").map(String.init)); sharedCache.at = Date()
            }
            return sharedCache.ids
        }
    }
    func forgetSharedCache() { sharedCache.lock.withLock { sharedCache.at = .distantPast } }
    /// Refreshes the mirror from the server when it is reachable; silent otherwise (the mirror then answers as it is).
    func pull() async {
        do { try await detector.pull() } catch { DriveServices.log.info("pull skipped: \(DriveError.wrap(error).code, privacy: .public)") }
    }
    /// Current description of an item: from the server when reachable, from the mirror otherwise.
    func fresh(_ id: String, kind: ItemKind? = nil) async throws -> DriveItem {
        do {
            let sel = kind == .file ? Selection(fileIds: [id]) : kind == .folder ? Selection(folderIds: [id]) : Selection(fileIds: [id], folderIds: [id])
            guard let item = try await api.items(sel).all.first else { try? store.remove([id]); throw DriveError.server(status: 404, code: "not_found", message: "", extra: [:]) }
            try store.upsert([item])
            return item
        } catch {
            let e = DriveError.wrap(error)
            if e.isTransient, let known = try store.item(id) { return known }
            throw e
        }
    }

    /// The error the system should see. It decides what the system does next: retry later, ask to sign in, re-create the item…
    func fpError(_ error: Error) -> NSError {
        if let ns = error as NSError?, ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain { return ns }
        let e = DriveError.wrap(error)
        switch e {
        case .offline: return NSFileProviderError(.serverUnreachable) as NSError
        case .unauthenticated: return NSFileProviderError(.notAuthenticated) as NSError
        case .cancelled: return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        case .integrity: return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: e.errorDescription ?? ""]) as NSError
        case .server(let status, let code, _, _):
            if code == "not_found" { return NSFileProviderError(.noSuchItem) as NSError }
            if code == "quota_exceeded" || code == "file_too_large" { return NSFileProviderError(.insufficientQuota) as NSError }
            if status >= 500 || status == 429 { return NSFileProviderError(.serverUnreachable) as NSError }
            return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: e.errorDescription ?? code]) as NSError
        default: return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: e.errorDescription ?? e.code]) as NSError
        }
    }
    /// Names the system and applications create next to documents and that must never travel: they stay on this Mac.
    static func isExcluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.hasPrefix(".") || name.hasPrefix("~$") || lower == "icon\r" || lower == "thumbs.db" || lower == "desktop.ini" || lower.hasSuffix(".tmp") || lower.hasSuffix(".sb-") || name.contains(".sb-")
    }
}
