// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Sync/ChangeDetector.swift
// Description      : Detects what changed on the server since the last cursor —
//                    incrementally, page by page — applies it to the local
//                    mirror and says what kind of change each item went
//                    through.
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

public enum ChangeKind: String, Sendable, Equatable { case created, contentChanged, renamed, moved, trashed, restored, deleted, metadata }
public struct DetectedChange: Sendable, Equatable {
    public var id: String; public var name: String; public var isFolder: Bool; public var kind: ChangeKind
}

public struct ChangeDetector: Sendable {
    public let api: APIClient
    public let store: MetadataStore
    public init(api: APIClient, store: MetadataStore) { self.api = api; self.store = store }

    /// Compares what the mirror knew with what the server now says.
    public static func classify(old: DriveItem?, new: DriveItem) -> ChangeKind {
        guard let old else { return .created }
        if old.trashedAt == nil, new.trashedAt != nil { return .trashed }
        if old.trashedAt != nil, new.trashedAt == nil { return .restored }
        if !new.isFolder, old.versionID != new.versionID || old.sha256 != new.sha256 { return .contentChanged }
        if old.parentID != new.parentID { return .moved }
        if old.name != new.name { return .renamed }
        return .metadata
    }
    /// True when the server has revisions the mirror has not seen (one small request).
    public func hasRemoteChanges() async throws -> Bool { try await api.syncCursor().head != store.cursor }

    /// Pulls every change after the stored cursor. The cursor only moves together with the rows it accounts for, so an
    /// interruption at any point resumes without loss or repetition.
    @discardableResult public func pull(pageSize: Int = 1000, maxPages: Int = .max) async throws -> [DetectedChange] {
        var out: [DetectedChange] = [], pages = 0
        while pages < maxPages {
            try Task.checkCancellation()
            let since = store.cursor
            let page = try await api.changes(since: since, limit: pageSize)
            if since > page.head {
                // the server knows less than this mirror (restored from a backup): rebuild from nothing
                try store.resetMirror(); pages += 1; continue
            }
            for item in page.items {
                // items the mirror already holds at this revision were written by this device a moment ago: not a remote change
                let old = try store.item(item.id)
                if let old, old.rev >= item.rev { continue }
                out.append(DetectedChange(id: item.id, name: item.name, isFolder: item.isFolder, kind: ChangeDetector.classify(old: old, new: item)))
            }
            for d in page.deleted { if let old = try store.item(d.id) { out.append(DetectedChange(id: d.id, name: old.name, isFolder: old.isFolder, kind: .deleted)) } }
            try store.apply(page)
            pages += 1
            if !page.more { break }
        }
        return out
    }
}
