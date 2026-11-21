// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/SpotlightIndexer.swift
// Description      : Optional Core Spotlight index of item METADATA only —
//                    name, kind, dates, location — never content. Off by
//                    default; incremental from the mirror's change counter;
//                    erased when the setting is turned off and at sign-out.
// Module           : App
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

import CoreSpotlight
import Foundation
import SPDriveCore
import UniformTypeIdentifiers

@MainActor final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    static let domain = "ai.spboucher.spdrive.items"
    private let index = CSSearchableIndex(name: "ai.spboucher.spdrive\(AppEnvironment.variant)")
    private var running = false
    private(set) var lastIndexed = 0

    /// What Spotlight is told about one item. Deliberately small: nothing here is read from the file's bytes.
    static func attributes(for item: DriveItem, path: String) -> CSSearchableItemAttributeSet {
        let type: UTType = item.isFolder ? .folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        let a = CSSearchableItemAttributeSet(contentType: type)
        a.title = item.name; a.displayName = item.name
        a.contentCreationDate = item.createdAt; a.contentModificationDate = item.isFolder ? item.updatedAt : item.contentAt
        a.kind = type.localizedDescription
        a.containerTitle = "SP Drive"; a.containerDisplayName = "SP Drive"
        a.path = path.isEmpty ? "SP Drive" : "SP Drive › " + path
        if !item.isFolder { a.fileSize = NSNumber(value: item.size) }
        a.keywords = ["SP Drive"] + (item.fileExtension.isEmpty ? [] : [item.fileExtension]) + (item.starred ? ["favori"] : [])
        return a
    }
    /// Brings the index in line with the mirror (changes since the last pass). No-op when the setting is off.
    func sync(model: AppModel) async {
        guard model.settings.spotlightIndex, CSSearchableIndex.isIndexingAvailable(), let store = model.store, !running else { return }
        running = true; defer { running = false }
        let d = AppEnvironment.defaults
        var since: Int64 = d.string(forKey: "spotlightGeneration") == store.generation ? Int64(d.integer(forKey: "spotlightSeq")) : 0
        if since == 0 { try? await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightIndexer.domain]) }
        while let page = try? store.changes(since: since, limit: 400), page.seq > since {
            let live = page.items.filter { !$0.isTrashed && !$0.isRoot && !$0.id.hasPrefix("local-") }
            let gone = page.deleted + page.items.filter(\.isTrashed).map(\.id)
            let items = live.map { i -> CSSearchableItem in
                let path = ((try? store.path(to: i.id)) ?? []).dropLast().map(\.name).joined(separator: " › ")
                return CSSearchableItem(uniqueIdentifier: i.id, domainIdentifier: SpotlightIndexer.domain, attributeSet: SpotlightIndexer.attributes(for: i, path: path))
            }
            do {
                if !items.isEmpty { try await index.indexSearchableItems(items) }
                if !gone.isEmpty { try await index.deleteSearchableItems(withIdentifiers: gone) }
            } catch { AppEnvironment.log.info("spotlight: \(error.localizedDescription, privacy: .public)"); return }
            lastIndexed += items.count
            since = page.seq
            d.set(store.generation, forKey: "spotlightGeneration"); d.set(Int(since), forKey: "spotlightSeq")
            if !page.more { break }
        }
    }
    /// Erases everything SP Drive put in Spotlight (setting turned off, sign-out).
    func removeAll() async {
        try? await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightIndexer.domain])
        try? await index.deleteAllSearchableItems()
        AppEnvironment.defaults.removeObject(forKey: "spotlightSeq"); AppEnvironment.defaults.removeObject(forKey: "spotlightGeneration")
        lastIndexed = 0
    }
    /// Number of items Spotlight returns for a name, in SP Drive's own index (used by the self-test).
    func count(named name: String) async -> Int {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let context = CSSearchQueryContext(); context.fetchAttributes = ["title"]
        let q = CSSearchQuery(queryString: "title == \"\(escaped)\"", queryContext: context)
        var n = 0
        do { for try await r in q.results where r.item.domainIdentifier == SpotlightIndexer.domain { n += 1 } } catch { return -1 }
        return n
    }
}
