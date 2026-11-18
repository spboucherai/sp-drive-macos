// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/Navigator.swift
// Description: Where the person is in the window: sidebar section, current folder, selection, search and filters, and which sheet is open.
import Foundation
import Observation
import SPDriveCore

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case drive, recent, shared, portals, favorites, offline, downloads, transfers, conflicts, trash, storage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .drive: "Mon Drive"; case .recent: "Récents"; case .shared: "Partagés par moi"; case .portals: "Liens de dépôt"; case .favorites: "Favoris"
        case .offline: "Disponibles hors ligne"; case .downloads: "Téléchargements"; case .transfers: "Transferts"; case .conflicts: "Conflits"; case .trash: "Corbeille"; case .storage: "Stockage"
        }
    }
    var symbol: String {
        switch self {
        case .drive: "externaldrive.connected.to.line.below"; case .recent: "clock"; case .shared: "link"; case .portals: "tray.and.arrow.down"; case .favorites: "star"
        case .offline: "pin"; case .downloads: "arrow.down.circle"; case .transfers: "arrow.up.arrow.down"; case .conflicts: "exclamationmark.triangle"; case .trash: "trash"; case .storage: "chart.pie"
        }
    }
    /// Sections that show items of the tree in the browser.
    var isBrowser: Bool { [.drive, .recent, .favorites, .offline, .trash].contains(self) }
}

enum SheetKind: Identifiable, Equatable {
    case newFolder(parent: String), rename(DriveItem), move([DriveItem]), share(DriveItem), portal(folder: DriveItem), versions(DriveItem)
    var id: String {
        switch self {
        case .newFolder(let p): "new-\(p)"; case .rename(let i): "rename-\(i.id)"; case .move(let i): "move-\(i.map(\.id).joined())"
        case .share(let i): "share-\(i.id)"; case .portal(let f): "portal-\(f.id)"; case .versions(let i): "versions-\(i.id)"
        }
    }
}

@MainActor @Observable final class Navigator {
    var section: SidebarItem = .drive { didSet { if section != oldValue { selection = []; searchText = ""; filter = LocalSearch() } } }
    /// Folder shown in "Mon Drive"; nil = the root.
    var folderID: String? { didSet { selection = [] } }
    var selection: Set<String> = []
    var searchText = ""
    /// Filters of the search (type, extension, dates, sizes, favourites, shared).
    var filter = LocalSearch()
    var searchEverywhere = true
    var sheet: SheetKind?
    var showInspector = false
    var confirmPurge: [DriveItem] = []
    var confirmEmptyTrash = false
    var previewURL: URL?

    func open(folder id: String?) { section = .drive; folderID = id }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !filter.isEmpty }
}
