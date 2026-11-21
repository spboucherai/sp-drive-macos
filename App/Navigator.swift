// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/Navigator.swift
// Description      : Where the person is in one window: sidebar section,
//                    current folder and its back/forward history, selection,
//                    inline rename, search and filters, the command palette,
//                    and which sheet is open. Each window has its own
//                    navigator.
// Module           : App
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

import Foundation
import Observation
import SPDriveCore
import SPDriveNext
import SPDriveSync
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case drive, recent, shared, portals, favorites, offline, downloads, transfers, conflicts, trash, storage
    // SP Drive 2.0: shown only when the connected server offers the feature (`AppModel.isAvailable`)
    case collections, sharedWithMe, activity, admin
    var id: String { rawValue }
    var title: String {
        switch self {
        case .drive: "Mon Drive"; case .recent: "Récents"; case .shared: "Partagés"; case .portals: "Portails"; case .favorites: "Favoris"
        case .offline: "Hors ligne"; case .downloads: "Téléchargements"; case .transfers: "Transferts"; case .conflicts: "Conflits"; case .trash: "Corbeille"; case .storage: "Stockage"
        case .collections: "Collections"; case .sharedWithMe: "Partagés avec moi"; case .activity: "Activité"; case .admin: "Administration"
        }
    }
    var symbol: String {
        switch self {
        case .drive: "externaldrive"; case .recent: "clock"; case .shared: "link"; case .portals: "tray.and.arrow.down"; case .favorites: "star"
        case .offline: "arrow.down.circle"; case .downloads: "arrow.down.circle"; case .transfers: "arrow.up.arrow.down"; case .conflicts: "exclamationmark.triangle"; case .trash: "trash"; case .storage: "chart.pie"
        case .collections: "square.stack.3d.up"; case .sharedWithMe: "person.2"; case .activity: "clock.arrow.circlepath"; case .admin: "server.rack"
        }
    }
    /// Sections that show items of the tree in the browser.
    var isBrowser: Bool { [.drive, .recent, .favorites, .offline, .trash].contains(self) }
    /// Sections that exist on every server. The others depend on `GET /meta` (see `AppModel.isAvailable`).
    var isAvailable: Bool { ![.collections, .sharedWithMe, .activity, .admin].contains(self) }
}

enum SheetKind: Identifiable, Equatable {
    case newFolder(parent: String), rename(DriveItem), move([DriveItem]), share(DriveItem), portal(folder: DriveItem), versions(DriveItem), conflict(SyncConflict)
    case members(DriveItem), collection(SmartCollection?), ask(DriveItem?), suggest([DriveItem])
    var id: String {
        switch self {
        case .newFolder(let p): "new-\(p)"; case .rename(let i): "rename-\(i.id)"; case .move(let i): "move-\(i.map(\.id).joined())"
        case .share(let i): "share-\(i.id)"; case .portal(let f): "portal-\(f.id)"; case .versions(let i): "versions-\(i.id)"; case .conflict(let c): "conflict-\(c.id)"
        case .members(let f): "members-\(f.id)"; case .collection(let c): "collection-\(c?.id ?? "new")"; case .ask(let i): "ask-\(i?.id ?? "drive")"; case .suggest(let i): "suggest-\(i.map(\.id).joined())"
        }
    }
}

enum TransferFilter: String, CaseIterable, Identifiable { case all, uploads, downloads, issues
    var id: String { rawValue }
    var title: String { switch self { case .all: "Tous"; case .uploads: "Envois"; case .downloads: "Téléchargements"; case .issues: "À voir" } }
}

@MainActor @Observable final class Navigator {
    enum Direction { case deeper, shallower, lateral }
    var section: SidebarItem = .drive {
        didSet {
            guard section != oldValue else { return }
            if section == .downloads { section = .transfers; transferFilter = .downloads } // one transfer centre; "Téléchargements" is a filter of it
            selection = []; searchText = ""; filter = LocalSearch(); renamingID = nil; direction = .lateral
        }
    }
    /// Folder shown in "Mon Drive"; nil = the root. Set through `go(to:)` to keep the history.
    var folderID: String? { didSet { if folderID != oldValue { selection = []; renamingID = nil } } }
    var selection: Set<String> = []
    /// Where a shift-extended selection started (grid).
    var anchorID: String?
    /// Item whose name is being edited in place.
    var renamingID: String?
    var searchText = ""
    /// Filters of the search (type, extension, dates, sizes, favourites, shared).
    var filter = LocalSearch()
    var searchEverywhere = true
    var sheet: SheetKind?
    var showInspector = false
    var showPalette = false
    var confirmPurge: [DriveItem] = []
    var confirmEmptyTrash = false
    var transferFilter = TransferFilter.all
    /// The smart collection shown by the Collections section.
    var collectionID: String?
    /// Search 2.0: where the server looks (names, content, both) and whether it searches by meaning.
    var searchScope = SearchScope.all
    var searchSemantic = false
    /// How the last folder change moved in the tree: drives the direction of the transition.
    var direction = Direction.lateral
    private(set) var backStack: [String?] = []
    private(set) var forwardStack: [String?] = []

    /// Shows a folder of Mon Drive (nil = root), remembering where we came from.
    func go(to id: String?, direction d: Direction = .deeper) {
        if section != .drive { section = .drive }
        guard id != folderID else { return }
        backStack.append(folderID); if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
        direction = d; folderID = id
    }
    func open(folder id: String?) { go(to: id, direction: .deeper) }
    var canGoBack: Bool { section == .drive && !backStack.isEmpty }
    var canGoForward: Bool { section == .drive && !forwardStack.isEmpty }
    func back() { guard canGoBack, let prev = backStack.popLast() else { return }; forwardStack.append(folderID); direction = .shallower; folderID = prev }
    func forward() { guard canGoForward, let next = forwardStack.popLast() else { return }; backStack.append(folderID); direction = .deeper; folderID = next }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !filter.isEmpty }
}

/// What the menu commands need to know about the focused window to enable themselves. Published as a focused value:
/// that is what makes the menus re-validate (a Commands body does not follow an observable model by itself).
struct WindowFocus: Equatable {
    var section = SidebarItem.drive
    var folderID: String?
    var hasFolder = false
    var selectionCount = 0
    var selectionHasTrashed = false
    var canGoBack = false, canGoForward = false
    var locked = false, paused = false, finderReady = false
}
/// Carries `WindowFocus` to the menu commands as an ObservableObject, which a Commands body is documented to follow.
@MainActor final class MenuBridge: ObservableObject { @Published var focus: WindowFocus? }
private struct NavigatorKey: FocusedValueKey { typealias Value = Navigator }
extension FocusedValues {
    /// The navigator of the window that has the focus (menu commands act on it).
    var spdNavigator: Navigator? { get { self[NavigatorKey.self] } set { self[NavigatorKey.self] = newValue } }
}
