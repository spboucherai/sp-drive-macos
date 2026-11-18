// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/MyDrive/BrowserView.swift
// Description: The file browser used by Mon Drive, Récents, Favoris, Hors ligne and Corbeille: list and grid, sorting, search with filters, multiple selection, drag and drop (in from the Finder, between folders), Quick Look, context menus. Reads the local mirror, so it works offline.
import QuickLook
import SPDriveCore
import SPDriveSync
import SwiftUI
import UniformTypeIdentifiers

struct BrowserRow: Identifiable, Equatable {
    let item: DriveItem
    var id: String { item.id }
    var name: String { NameRules.searchKey(item.name) }
    var size: Int64 { item.isFolder ? -1 : item.size }
    var modified: Date { item.isFolder ? item.updatedAt : item.contentAt }
    var kind: String { Fmt.kind(item) }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\BrowserRow.name)]
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var nav: Navigator { model.nav }
    private var currentFolderID: String? { nav.section == .drive ? (nav.folderID ?? model.rootID) : nil }

    /// What the section shows, from the mirror. `revision` is read so that the view follows every change of the mirror.
    private var rows: [BrowserRow] {
        _ = model.revision
        var items: [DriveItem]
        if nav.isSearching, nav.section != .trash {
            var q = nav.filter
            q.text = nav.searchText
            switch nav.section {
            case .drive: q.folderID = nav.searchEverywhere ? nil : currentFolderID
            case .favorites: q.starredOnly = true
            case .offline: q.onlyIDs = Set(model.pinned().flatMap { $0.isFolder ? ((try? model.store?.subtreeIDs(of: $0.id)) ?? []) : [$0.id] })
            default: break
            }
            q.limit = 2000
            items = model.search(q)
        } else {
            switch nav.section {
            case .drive: items = currentFolderID.map { model.children(of: $0) } ?? []
            case .recent: items = model.recent()
            case .favorites: items = model.starred()
            case .offline: items = model.pinned()
            case .trash: items = model.trash().filter { nav.searchText.isEmpty || NameRules.searchKey($0.name).contains(NameRules.searchKey(nav.searchText)) }
            default: items = []
            }
        }
        var rows = items.map(BrowserRow.init)
        if nav.section == .recent && sortOrder.first?.keyPath == \BrowserRow.name { return rows } // most recent first, as given
        rows.sort(using: sortOrder)
        // folders before files, whatever the sort
        return rows.filter { $0.item.isFolder } + rows.filter { !$0.item.isFolder }
    }
    private func selected(_ ids: Set<String>) -> [DriveItem] { ids.compactMap { model.item($0) } }

    var body: some View {
        @Bindable var nav = model.nav
        let rows = self.rows
        VStack(spacing: 0) {
            if nav.section == .drive { PathBar() }
            if nav.isSearching || nav.section == .drive && !nav.filter.isEmpty { FilterBar() }
            Group {
                if rows.isEmpty { emptyState }
                else if model.settings.gridView { grid(rows) }
                else { table(rows) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let target = currentFolderID, !urls.isEmpty else { return false }
                Task { await model.upload(urls, to: target) }
                return true
            } isTargeted: { dropTargeted = $0 && currentFolderID != nil }
            StatusBar(count: rows.count, selection: selected(nav.selection))
        }
        .navigationTitle(title)
        .navigationSubtitle(nav.isSearching ? "\(rows.count) résultat\(rows.count > 1 ? "s" : "")" : "")
        .searchable(text: $nav.searchText, placement: .toolbar, prompt: nav.section == .trash ? "Rechercher dans la corbeille" : "Rechercher")
        .toolbar { BrowserToolbar(model: model, currentFolderID: currentFolderID, selection: selected(nav.selection)) }
        .inspector(isPresented: $nav.showInspector) { InspectorView(items: selected(nav.selection)).environment(model).inspectorColumnWidth(min: 260, ideal: 300, max: 400) }
        .quickLookPreview($nav.previewURL)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) { preview(selected(nav.selection).first); return .handled }
        .onKeyPress(.return) { if let i = selected(nav.selection).first, nav.selection.count == 1, !i.isTrashed { nav.sheet = .rename(i) }; return .handled }
        .onAppear { focused = true }
    }
    private var title: String {
        if nav.section == .drive, let id = nav.folderID, let f = model.item(id), !f.isRoot { return f.name }
        return nav.section.title
    }
    private func preview(_ item: DriveItem?) {
        guard let item, !item.isFolder else { return }
        Task {
            do { nav.previewURL = try await model.localCopy(of: item) }
            catch { model.banner = Banner(text: "Aperçu de « \(item.name) » : \(DriveError.wrap(error).errorDescription ?? "indisponible")", isError: true) }
        }
    }
    private func activate(_ item: DriveItem) {
        if item.isTrashed { return }
        if item.isFolder { nav.open(folder: item.id) } else { Task { await model.open(item) } }
    }

    // MARK: List
    private func table(_ rows: [BrowserRow]) -> some View {
        @Bindable var nav = model.nav
        return Table(of: BrowserRow.self, selection: $nav.selection, sortOrder: $sortOrder) {
            TableColumn("Nom", value: \.name) { row in
                HStack(spacing: 8) {
                    ItemIcon(item: row.item)
                    Text(row.item.name).lineLimit(1).truncationMode(.middle)
                    ItemBadges(model: model, item: row.item)
                }
                .accessibilityElement(children: .combine).accessibilityLabel("\(row.item.name), \(row.kind)")
            }
            .width(min: 220, ideal: 380)
            TableColumn("État") { row in SyncStateLabel(model: model, item: row.item).font(.callout) }.width(min: 90, ideal: 120, max: 150)
            TableColumn("Taille", value: \.size) { row in Text(row.item.isFolder ? "—" : Fmt.bytes(row.item.size)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 90, max: 120)
            TableColumn("Modifié", value: \.modified) { row in Text(Fmt.date(row.modified)).foregroundStyle(.secondary) }.width(min: 120, ideal: 160, max: 200)
            TableColumn("Type", value: \.kind) { row in Text(row.kind).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 130)
        } rows: {
            ForEach(rows) { row in
                if row.item.isFolder && !row.item.isTrashed {
                    TableRow(row).draggable(ItemRef(id: row.id))
                        .dropDestination(for: ItemRef.self) { refs in move(refs, into: row.item) }
                } else { TableRow(row).draggable(ItemRef(id: row.id)) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in ItemMenu(items: selected(ids), currentFolderID: currentFolderID, preview: preview).environment(model) } primaryAction: { ids in
            if let first = selected(ids).first, ids.count == 1 { activate(first) }
        }
        .accessibilityIdentifier("browser-table")
    }
    private func move(_ refs: [ItemRef], into folder: DriveItem) {
        let items = refs.compactMap { model.item($0.id) }.filter { $0.id != folder.id }
        guard !items.isEmpty else { return }
        model.move(items, to: folder.id)
    }

    // MARK: Grid
    private func grid(_ rows: [BrowserRow]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 14)], spacing: 14) {
                ForEach(rows) { row in
                    GridCell(model: model, row: row, selected: nav.selection.contains(row.id))
                        .onTapGesture(count: 2) { activate(row.item) }
                        .simultaneousGesture(TapGesture().onEnded {
                            if NSEvent.modifierFlags.contains(.command) { if nav.selection.contains(row.id) { nav.selection.remove(row.id) } else { nav.selection.insert(row.id) } }
                            else { nav.selection = [row.id] }
                        })
                        .draggable(ItemRef(id: row.id))
                        .dropDestination(for: ItemRef.self) { refs, _ in guard row.item.isFolder, !row.item.isTrashed else { return false }; move(refs, into: row.item); return true }
                        .contextMenu { ItemMenu(items: nav.selection.contains(row.id) ? selected(nav.selection) : [row.item], currentFolderID: currentFolderID, preview: preview).environment(model) }
                }
            }
            .padding(16)
        }
        .contextMenu { ItemMenu(items: [], currentFolderID: currentFolderID, preview: preview).environment(model) }
        .onTapGesture { nav.selection = [] }
    }

    @ViewBuilder private var emptyState: some View {
        if nav.isSearching { ContentUnavailableView.search(text: nav.searchText) }
        else {
            switch nav.section {
            case .drive:
                ContentUnavailableView {
                    Label(model.status.lastSync == nil ? "Première synchronisation…" : "Dossier vide", systemImage: model.status.lastSync == nil ? "arrow.triangle.2.circlepath" : "folder")
                } description: { Text(model.status.lastSync == nil ? "SP Drive récupère la liste de vos fichiers." : "Glissez des fichiers ici, ou utilisez le bouton Téléverser.") } actions: {
                    if let id = currentFolderID, model.status.lastSync != nil { Button("Nouveau dossier") { nav.sheet = .newFolder(parent: id) } }
                }
            case .recent: ContentUnavailableView("Aucun fichier récent", systemImage: "clock", description: Text("Les fichiers modifiés dernièrement apparaîtront ici."))
            case .favorites: ContentUnavailableView("Aucun favori", systemImage: "star", description: Text("Ajoutez un fichier ou un dossier aux favoris depuis son menu contextuel."))
            case .offline: ContentUnavailableView("Rien n’est gardé hors ligne", systemImage: "pin", description: Text("Choisissez « Garder disponible hors ligne » sur un fichier ou un dossier : il sera téléchargé, tenu à jour et jamais retiré de ce Mac."))
            case .trash: ContentUnavailableView("Corbeille vide", systemImage: "trash", description: Text("Les éléments supprimés restent ici jusqu’à leur suppression définitive."))
            default: EmptyView()
            }
        }
    }
}

/// Reference to an item carried by a drag inside the application.
struct ItemRef: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .spdriveItem) }
}
extension UTType { static let spdriveItem = UTType(exportedAs: "ai.spboucher.spdrive.item") }

struct GridCell: View {
    let model: AppModel
    let row: BrowserRow
    let selected: Bool
    var body: some View {
        VStack(spacing: 6) {
            ItemIcon(item: row.item, size: 64)
            Text(row.item.name).font(.callout).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(selected ? .white : .primary)
            ItemBadges(model: model, item: row.item).frame(height: 12)
        }
        .frame(maxWidth: .infinity).padding(8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine).accessibilityLabel("\(row.item.name), \(row.kind)").accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Breadcrumbs of the current folder; each crumb accepts dropped items.
struct PathBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let nav = model.nav
        let crumbs = nav.folderID.map { model.path(to: $0) } ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb("Mon Drive", symbol: "externaldrive", id: nil, current: crumbs.isEmpty)
                ForEach(crumbs) { c in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(c.name, symbol: "folder", id: c.id, current: c.id == crumbs.last?.id)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
    private func crumb(_ name: String, symbol: String, id: String?, current: Bool) -> some View {
        Button { model.nav.folderID = id } label: { Label(name, systemImage: symbol).font(.callout).fontWeight(current ? .semibold : .regular) }
            .buttonStyle(.plain).foregroundStyle(current ? .primary : .secondary)
            .dropDestination(for: ItemRef.self) { refs, _ in
                guard let dest = id ?? model.rootID else { return false }
                let items = refs.compactMap { model.item($0.id) }
                guard !items.isEmpty else { return false }
                model.move(items, to: dest); return true
            }
    }
}

/// Search filters: type, extension, date, size, favourites, shared, scope.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var nav = model.nav
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("Type", selection: $nav.filter.category) {
                    ForEach(FileCategory.allCases) { Text(FilterBar.label($0)).tag($0) }
                }.frame(width: 170)
                TextField("Extension", text: Binding(get: { nav.filter.fileExtension ?? "" }, set: { nav.filter.fileExtension = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder).frame(width: 90)
                Picker("Modifié", selection: Binding(get: { FilterBar.days(nav.filter.modifiedAfter) }, set: { nav.filter.modifiedAfter = $0 == 0 ? nil : Calendar.current.date(byAdding: .day, value: -$0, to: Date()) })) {
                    Text("À toute date").tag(0); Text("Aujourd’hui").tag(1); Text("7 derniers jours").tag(7); Text("30 derniers jours").tag(30); Text("Cette année").tag(365)
                }.frame(width: 190)
                Picker("Taille", selection: Binding(get: { nav.filter.minSize ?? 0 }, set: { nav.filter.minSize = $0 == 0 ? nil : $0 })) {
                    Text("Toute taille").tag(Int64(0)); Text("Plus de 1 Mo").tag(Int64(1_000_000)); Text("Plus de 100 Mo").tag(Int64(100_000_000)); Text("Plus de 1 Go").tag(Int64(1_000_000_000))
                }.frame(width: 170)
                Toggle("Favoris", isOn: $nav.filter.starredOnly).toggleStyle(.button)
                Toggle("Partagés", isOn: Binding(get: { nav.filter.onlyIDs != nil }, set: { nav.filter.onlyIDs = $0 ? model.sharedIDs : nil })).toggleStyle(.button)
                if nav.section == .drive, nav.folderID != nil { Toggle("Tout le Drive", isOn: $nav.searchEverywhere).toggleStyle(.button) }
                Button("Effacer") { nav.filter = LocalSearch(); nav.searchText = "" }.buttonStyle(.link)
            }
            .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
    static func days(_ d: Date?) -> Int {
        guard let d else { return 0 }
        let n = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return [1, 7, 30, 365].min { abs($0 - n) < abs($1 - n) } ?? 0
    }
    static func label(_ c: FileCategory) -> String {
        switch c { case .any: "Tous les types"; case .folder: "Dossiers"; case .image: "Images"; case .pdf: "PDF"; case .document: "Documents"; case .sheet: "Feuilles de calcul"
        case .video: "Vidéos"; case .audio: "Audio"; case .archive: "Archives"; case .text: "Texte" }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let selection: [DriveItem]
    var body: some View {
        HStack {
            if selection.isEmpty { Text("\(count) élément\(count > 1 ? "s" : "")") }
            else { Text("\(selection.count) sélectionné\(selection.count > 1 ? "s" : "") · \(Fmt.bytes(selection.filter { !$0.isFolder }.reduce(0) { $0 + $1.size }))") }
            Spacer()
            if !model.online { Label("Hors ligne — vos changements seront envoyés au retour de la connexion", systemImage: "icloud.slash") }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 5)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
}
