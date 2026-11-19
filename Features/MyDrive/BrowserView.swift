// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/MyDrive/BrowserView.swift
// Description: The file browser of Mon Drive, Récents, Favoris, Hors ligne and Corbeille: a compact list and a thumbnail grid over the local mirror (so it works offline), path bar, search filters, full keyboard navigation (arrows, Return to rename in place, Space for Quick Look, type-select), drag and drop in and out, folder transitions, and empty states that offer the next action.
import AppKit
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

enum BrowserSort: String, CaseIterable, Identifiable {
    case name, modified, size, kind
    var id: String { rawValue }
    var title: String { switch self { case .name: "Nom"; case .modified: "Date de modification"; case .size: "Taille"; case .kind: "Type" } }
    func comparator(_ order: SortOrder) -> KeyPathComparator<BrowserRow> {
        switch self { case .name: KeyPathComparator(\.name, order: order); case .modified: KeyPathComparator(\.modified, order: order); case .size: KeyPathComparator(\.size, order: order); case .kind: KeyPathComparator(\.kind, order: order) }
    }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sortOrder = [KeyPathComparator(\BrowserRow.name)]
    @State private var dropTargeted = false
    @State private var gridColumns = 4
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @State private var window: NSWindow?

    private var currentFolderID: String? { nav.section == .drive ? (nav.folderID ?? model.rootID) : nil }
    /// Search 2.0: the server looks in names and content. Used in Mon Drive when it offers it and can be reached; the
    /// local name search (with its filters) remains for the other sections, offline, and on a 1.0 server.
    private var serverSearch: Bool {
        nav.section == .drive && model.has(.contentSearch) && model.online && nav.filter.isEmpty && !nav.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
    /// Identity of what is on screen: changing it plays the navigation transition.
    private var placeKey: String { "\(nav.section.rawValue)|\(nav.folderID ?? "root")" }

    var body: some View {
        @Bindable var nav = nav
        let rows = self.rows
        VStack(spacing: 0) {
            if nav.section == .drive { PathBar(model: model, nav: nav) }
            if !serverSearch, nav.isSearching || nav.section == .drive && !nav.filter.isEmpty { FilterBar(model: model, nav: nav) }
            ZStack {
                Group {
                    if serverSearch { SearchResultsView(model: model, nav: nav) }
                    else if rows.isEmpty { emptyState }
                    else if model.settings.gridView { grid(rows) }
                    else { table(rows) }
                }
                .id(placeKey)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .modifier(active: PlaceShift(x: nav.direction == .shallower ? -18 : (nav.direction == .deeper ? 18 : 0), opacity: 0), identity: PlaceShift(x: 0, opacity: 1)),
                                                                   removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SPDTheme.canvas)
            .spdMotion(.navigate, value: placeKey)
            .overlay { DropOverlay(active: dropTargeted, label: dropLabel) }
            .onDrop(of: Drops.types, isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 && currentFolderID != nil })) { providers in
                guard let target = currentFolderID else { return false }
                return Drops.handle(providers, into: target, model: model)
            }
            StatusBar(model: model, count: rows.count, selection: selected(nav.selection), showsGridSize: model.settings.gridView && !rows.isEmpty)
        }
        .navigationTitle(title)
        .navigationSubtitle(serverSearch ? "Recherche dans les noms et le contenu" : nav.isSearching ? "\(rows.count) résultat\(rows.count > 1 ? "s" : "")" : subtitle(rows))
        .searchable(text: $nav.searchText, placement: .toolbar, prompt: nav.section == .trash ? "Rechercher dans la corbeille" : (nav.section == .drive && model.has(.contentSearch) ? "Noms et contenu des documents" : "Rechercher"))
        .toolbar { BrowserToolbar(model: model, nav: nav, currentFolderID: currentFolderID, selection: selected(nav.selection), sort: sortBinding) }
        .inspector(isPresented: $nav.showInspector) {
            InspectorView(model: model, nav: nav, items: selected(nav.selection)).inspectorColumnWidth(min: 270, ideal: 300, max: 400)
        }
        .background(KeyCatcher { handleKey($0, rows: rows) })
        .background(WindowReader { window = $0 })
        .onChange(of: nav.selection) { _, new in followSelectionInQuickLook(new) }
    }
    private var title: String {
        if nav.section == .drive, let id = nav.folderID, let f = model.item(id), !f.isRoot { return f.name }
        return nav.section.title
    }
    private func subtitle(_ rows: [BrowserRow]) -> String {
        guard nav.section == .drive, !rows.isEmpty else { return "" }
        let folders = rows.filter { $0.item.isFolder }.count, files = rows.count - folders
        return [folders > 0 ? "\(folders) dossier\(folders > 1 ? "s" : "")" : nil, files > 0 ? "\(files) fichier\(files > 1 ? "s" : "")" : nil].compactMap { $0 }.joined(separator: ", ")
    }
    private var dropLabel: String {
        guard let id = currentFolderID, let f = model.item(id) else { return "" }
        return "Déposer dans « \(f.isRoot ? "Mon Drive" : f.name) »"
    }
    private var sortBinding: Binding<(BrowserSort, SortOrder)> {
        Binding(get: {
            let c = sortOrder.first
            let key: BrowserSort = c?.keyPath == \BrowserRow.modified ? .modified : c?.keyPath == \BrowserRow.size ? .size : c?.keyPath == \BrowserRow.kind ? .kind : .name
            return (key, c?.order ?? .forward)
        }, set: { sortOrder = [$0.0.comparator($0.1)] })
    }

    // MARK: Actions
    private func activate(_ item: DriveItem) {
        if item.isTrashed { return }
        if item.isFolder { nav.go(to: item.id, direction: .deeper) } else { Task { await model.open(item) } }
    }
    /// Opens Quick Look on a file, or closes it when it already shows that file (Space toggles).
    private func togglePreview(_ item: DriveItem?) {
        let ql = QuickLookCoordinator.shared
        if ql.isVisible, item == nil || ql.itemID == item?.id { ql.close(); return }
        showPreview(item)
    }
    private func showPreview(_ item: DriveItem?) {
        guard let item, !item.isFolder else { return }
        let rowsNow = self.rows
        QuickLookCoordinator.shared.onKey = { e in handleKey(e, rows: rowsNow, fromPanel: true) }
        Task {
            do { let url = try await model.localCopy(of: item, inContainer: true); QuickLookCoordinator.shared.show(url: url, itemID: item.id) }
            catch { model.banner = Banner(text: "Aperçu de « \(item.name) » : \(DriveError.wrap(error).errorDescription ?? "indisponible")", isError: true) }
        }
    }
    /// While the panel is open, it follows the selection (arrows in the browser or in the panel).
    private func followSelectionInQuickLook(_ selection: Set<String>) {
        guard QuickLookCoordinator.shared.isVisible, selection.count == 1, let id = selection.first, id != QuickLookCoordinator.shared.itemID, let item = model.item(id) else { return }
        showPreview(item)
    }
    private func beginRename() {
        guard nav.selection.count == 1, let id = nav.selection.first, let item = model.item(id), !item.isTrashed, !item.isRoot else { return }
        nav.renamingID = id
    }
    private func move(_ refs: [ItemRef], into folder: DriveItem) {
        let items = refs.compactMap { model.item($0.id) }.filter { $0.id != folder.id }
        guard !items.isEmpty else { return }
        model.move(items, to: folder.id)
    }

    // MARK: Keyboard
    private func handleKey(_ e: NSEvent, rows: [BrowserRow], fromPanel: Bool = false) -> Bool {
        guard nav.section.isBrowser, nav.sheet == nil, !nav.showPalette else { return false }
        if !fromPanel, e.isInTextInput { return false }
        let mods = e.plainModifiers
        switch e.keyCode {
        case Key.space where mods.isEmpty:
            togglePreview(selected(nav.selection).first { !$0.isFolder }); return true
        case Key.return, Key.enter:
            guard mods.isEmpty, !fromPanel else { return false }
            beginRename(); return nav.renamingID != nil
        case Key.escape:
            if nav.renamingID != nil { nav.renamingID = nil; return true }
            if !nav.selection.isEmpty, !fromPanel { nav.selection = []; return true }
            return false
        case Key.left, Key.right, Key.up, Key.down:
            guard mods.subtracting(.shift).isEmpty else { return false }
            let grid = model.settings.gridView
            // the list moves its own selection when it has the focus; the grid, and the Quick Look panel, are driven here
            if !grid && !fromPanel { return false }
            if grid && !fromPanel && e.firstResponderIsTable { return false } // the sidebar has the focus
            let step: Int
            switch e.keyCode { case Key.left: step = grid ? -1 : 0; case Key.right: step = grid ? 1 : 0; case Key.up: step = grid ? -gridColumns : -1; default: step = grid ? gridColumns : 1 }
            guard step != 0 else { return false }
            moveSelection(by: step, in: rows, extend: mods.contains(.shift)); return true
        default:
            guard mods.subtracting(.shift).isEmpty, !fromPanel, let chars = e.characters, let scalar = chars.unicodeScalars.first, chars.count == 1,
                  CharacterSet.alphanumerics.contains(scalar) || (CharacterSet.punctuationCharacters.contains(scalar) && !typed.isEmpty) else { return false }
            typeSelect(chars, in: rows); return true
        }
    }
    private func moveSelection(by step: Int, in rows: [BrowserRow], extend: Bool) {
        guard !rows.isEmpty else { return }
        let current = (nav.selection.count == 1 ? nav.selection.first : nav.anchorID).flatMap { id in rows.firstIndex { $0.id == id } }
        let lead = extend ? (rows.firstIndex { $0.id == leadID } ?? current) : current
        guard let from = lead else { nav.selection = [rows[step > 0 ? 0 : rows.count - 1].id]; nav.anchorID = nav.selection.first; leadID = nav.anchorID; return }
        var to = from + step
        if to < 0 || to >= rows.count { to = abs(step) == 1 ? max(0, min(rows.count - 1, to)) : from } // a row jump that leaves the grid stays where it is
        if extend, let anchor = (nav.anchorID.flatMap { id in rows.firstIndex { $0.id == id } } ?? current) {
            nav.selection = Set(rows[min(anchor, to)...max(anchor, to)].map(\.id)); if nav.anchorID == nil { nav.anchorID = rows[anchor].id }
        } else { nav.selection = [rows[to].id]; nav.anchorID = rows[to].id }
        leadID = rows[to].id
    }
    @State private var leadID: String?
    /// Typing a few letters selects the first item whose name starts with them (accents and case ignored).
    private func typeSelect(_ chars: String, in rows: [BrowserRow]) {
        let now = Date()
        typed = now.timeIntervalSince(typedAt) > 1.0 ? chars : typed + chars
        typedAt = now
        let key = NameRules.searchKey(typed)
        if let hit = rows.first(where: { $0.name.hasPrefix(key) }) ?? rows.first(where: { $0.name.contains(key) }) { nav.selection = [hit.id]; nav.anchorID = hit.id; leadID = hit.id }
    }

    // MARK: List
    private func table(_ rows: [BrowserRow]) -> some View {
        @Bindable var nav = nav
        let model = self.model
        return ScrollViewReader { proxy in
            Table(of: BrowserRow.self, selection: $nav.selection, sortOrder: $sortOrder) {
                TableColumn("Nom", value: \.name) { row in
                    HStack(spacing: SPDTheme.Space.sm) {
                        ItemThumbnail(model: model, item: row.item, side: 20).background(FrameAnchor(id: row.id))
                        if nav.renamingID == row.id {
                            RenameField(initial: row.item.name, isFolder: row.item.isFolder, commit: { nav.renamingID = nil; model.rename(row.item, to: $0) }, cancel: { nav.renamingID = nil })
                        } else {
                            Text(row.item.name).lineLimit(1).truncationMode(.middle)
                            ItemBadges(model: model, item: row.item)
                        }
                    }
                    .accessibilityElement(children: .combine).accessibilityLabel("\(row.item.name), \(row.kind)")
                }
                .width(min: 220, ideal: 380)
                TableColumn("État") { row in SyncStateLabel(model: model, item: row.item).font(SPDTheme.Typo.callout) }.width(min: 90, ideal: 120, max: 150)
                TableColumn("Taille", value: \.size) { row in Text(row.item.isFolder ? "—" : Fmt.bytes(row.item.size)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 90, max: 120)
                TableColumn("Modifié", value: \.modified) { row in Text(Fmt.date(row.modified)).foregroundStyle(.secondary) }.width(min: 120, ideal: 160, max: 200)
                TableColumn("Type", value: \.kind) { row in Text(row.kind).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 130)
            } rows: {
                ForEach(rows) { row in
                    if row.item.isFolder && !row.item.isTrashed {
                        TableRow(row).itemProvider { Drops.provider(for: row.item, model: model) }
                            .dropDestination(for: ItemRef.self) { refs in move(refs, into: row.item) }
                    } else { TableRow(row).itemProvider { Drops.provider(for: row.item, model: model) } }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in ItemMenu(model: model, nav: nav, items: selected(ids), currentFolderID: currentFolderID, preview: showPreview, rename: { nav.selection = [$0.id]; nav.renamingID = $0.id }) } primaryAction: { ids in
                if let first = selected(ids).first, ids.count == 1 { activate(first) }
            }
            .onChange(of: leadID) { _, id in if let id { proxy.scrollTo(id) } }
            .accessibilityIdentifier("browser-table")
        }
    }

    // MARK: Grid
    private var cellWidth: CGFloat { [112, SPDTheme.Size.gridCell, 196][min(max(model.settings.gridSize, 0), 2)] }
    private func grid(_ rows: [BrowserRow]) -> some View {
        let spacing = SPDTheme.Space.md, width = cellWidth
        return GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - 2 * SPDTheme.Space.lg + spacing) / (width + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing, alignment: .top), count: columns), alignment: .leading, spacing: spacing) {
                        ForEach(rows) { row in
                            GridCell(model: model, nav: nav, row: row, width: width, selected: nav.selection.contains(row.id), moveInto: { move($0, into: row.item) })
                                .id(row.id)
                                .onTapGesture(count: 2) { activate(row.item) }
                                .simultaneousGesture(TapGesture().onEnded { click(row, in: rows) })
                                .onDrag { Drops.provider(for: row.item, model: model) }
                                .contextMenu {
                                    ItemMenu(model: model, nav: nav, items: nav.selection.contains(row.id) ? selected(nav.selection) : [row.item], currentFolderID: currentFolderID, preview: showPreview,
                                             rename: { nav.selection = [$0.id]; nav.renamingID = $0.id })
                                }
                        }
                    }
                    .padding(SPDTheme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: leadID) { _, id in if let id { spdAnimate(.select) { proxy.scrollTo(id) } } }
            }
            .onAppear { gridColumns = columns }
            .onChange(of: columns) { _, n in gridColumns = n }
        }
        .contextMenu { ItemMenu(model: model, nav: nav, items: [], currentFolderID: currentFolderID, preview: showPreview) }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { nav.selection = []; nav.renamingID = nil })
        .accessibilityIdentifier("browser-grid")
    }
    private func click(_ row: BrowserRow, in rows: [BrowserRow]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if nav.selection.contains(row.id) { nav.selection.remove(row.id) } else { nav.selection.insert(row.id) }
            nav.anchorID = row.id
        } else if flags.contains(.shift), let a = nav.anchorID, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == row.id }) {
            nav.selection = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else { nav.selection = [row.id]; nav.anchorID = row.id }
        leadID = row.id
        window?.makeFirstResponder(nil) // typing now goes to the browser (type-select), not to a control left focused
    }

    // MARK: Empty states
    @ViewBuilder private var emptyState: some View {
        if nav.isSearching {
            SPDEmptyState(symbol: "magnifyingglass", title: "Aucun résultat", message: nav.searchText.isEmpty ? "Aucun élément ne correspond à ces filtres." : "Rien ne s’appelle « \(nav.searchText) » ici. La recherche porte sur les noms, sans tenir compte des accents ni des majuscules.") {
                if !nav.filter.isEmpty { Button("Effacer les filtres") { nav.filter = LocalSearch() } }
                if nav.section == .drive, nav.folderID != nil, !nav.searchEverywhere { Button("Chercher dans tout le Drive") { nav.searchEverywhere = true }.buttonStyle(.borderedProminent) }
                Button("Effacer la recherche") { nav.searchText = ""; nav.filter = LocalSearch() }
            }
        } else {
            switch nav.section {
            case .drive:
                if model.status.lastSync == nil {
                    SPDEmptyState(symbol: "arrow.triangle.2.circlepath", title: "Première synchronisation", message: model.online ? "SP Drive récupère la liste de vos fichiers." : "Ce Mac est hors ligne : la liste de vos fichiers arrivera au retour de la connexion.") {
                        if model.online { ProgressView().controlSize(.small) } else { Button("Réessayer") { Task { await model.syncNow() } } }
                    }
                } else {
                    SPDEmptyState(symbol: "tray.and.arrow.up", title: nav.folderID == nil ? "Votre Drive est vide" : "Dossier vide", message: "Glissez des fichiers ou des dossiers ici depuis le Finder. Ils partent aussitôt, même si vous fermez la fenêtre.") {
                        if let id = currentFolderID {
                            Button("Téléverser…") { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: id) } } }.buttonStyle(.borderedProminent)
                            Button("Nouveau dossier") { nav.sheet = .newFolder(parent: id) }
                        }
                    }
                }
            case .recent:
                SPDEmptyState(symbol: "clock", title: "Rien de récent", message: "Les fichiers ajoutés ou modifiés dernièrement, sur n’importe lequel de vos appareils, apparaissent ici.") { Button("Ouvrir Mon Drive") { nav.section = .drive } }
            case .favorites:
                SPDEmptyState(symbol: "star", title: "Aucun favori", message: "Marquez un fichier ou un dossier d’une étoile (⌃⌘F) pour le retrouver ici d’un geste.") { Button("Ouvrir Mon Drive") { nav.section = .drive } }
            case .offline:
                if model.finderReady {
                    SPDEmptyState(symbol: "arrow.down.circle", title: "Rien n’est gardé hors ligne", message: "« Garder disponible hors ligne » (⇧⌘P) télécharge un fichier ou un dossier, le tient à jour et ne le retire jamais de ce Mac.") { Button("Choisir dans Mon Drive") { nav.section = .drive } }
                } else {
                    SPDEmptyState(symbol: "folder.badge.questionmark", title: "L’emplacement Finder est inactif", message: "Les copies hors ligne vivent dans l’emplacement SP Drive du Finder. macOS demande votre accord dans Réglages Système › Général › Ouverture et extensions › Fournisseurs de fichiers.") {
                        Button("Ouvrir les Réglages Système") { DriveDomain.shared.openSystemSettings() }.buttonStyle(.borderedProminent)
                    }
                }
            case .trash:
                SPDEmptyState(symbol: "trash", title: "Corbeille vide", message: "Ce que vous supprimez, ici ou dans le Finder, attend dans la corbeille : rien n’est détruit sans votre confirmation.")
            default: EmptyView()
            }
        }
    }
}

/// The incoming place slides a few points from the side it comes from.
private struct PlaceShift: ViewModifier {
    let x: CGFloat, opacity: Double
    func body(content: Content) -> some View { content.offset(x: x).opacity(opacity) }
}

/// Shown over the browser while a drag that can be dropped here hovers it.
struct DropOverlay: View {
    let active: Bool
    let label: String
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous)
                .strokeBorder(SPDTheme.brand, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(SPDTheme.brandWash, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous))
                .padding(active ? 6 : 14)
            if !label.isEmpty {
                Label(label, systemImage: "arrow.down.doc").font(SPDTheme.Typo.bodyStrong).foregroundStyle(SPDTheme.onBrand)
                    .padding(.horizontal, SPDTheme.Space.md).padding(.vertical, SPDTheme.Space.sm).background(SPDTheme.brand, in: Capsule()).spdElevation(.e2)
                    .padding(.bottom, SPDTheme.Space.xl).offset(y: active ? 0 : 10)
            }
        }
        .opacity(active ? 1 : 0).allowsHitTesting(false)
        .spdMotion(.drop, value: active)
        .accessibilityHidden(true)
    }
}

// MARK: Drag and drop
/// Reference to an item carried by a drag inside the application.
struct ItemRef: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .spdriveItem) }
}
extension UTType { static let spdriveItem = UTType(exportedAs: "ai.spboucher.spdrive.item") }

@MainActor enum Drops {
    static let types: [UTType] = [.spdriveItem, .fileURL]
    /// What a dragged item offers: its reference (moves inside SP Drive) and, for a file, its content as a file delivered
    /// when the drop happens (Finder, Mail, any app) — fetched and verified at that moment if it is not on this Mac yet.
    static func provider(for item: DriveItem, model: AppModel) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = item.name
        let ref = (try? JSONEncoder().encode(ItemRef(id: item.id))) ?? Data()
        p.registerDataRepresentation(forTypeIdentifier: UTType.spdriveItem.identifier, visibility: .ownProcess) { done in done(ref, nil); return nil }
        guard !item.isFolder, !item.isTrashed else { return p }
        let type = UTType(filenameExtension: item.fileExtension) ?? .data
        p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let progress = Progress(totalUnitCount: 1)
            let finish = UncheckedBox(done)
            Task { @MainActor in
                do { let url = try await model.localCopy(of: item, inContainer: true); progress.completedUnitCount = 1; finish.value(url, false, nil) }
                catch { finish.value(nil, false, error) }
            }
            return progress
        }
        return p
    }
    /// Handles a drop into a folder: items of SP Drive are moved there, files and folders from the Finder are uploaded there.
    @discardableResult static func handle(_ providers: [NSItemProvider], into folderID: String, model: AppModel) -> Bool {
        let refs = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.spdriveItem.identifier) }
        let files = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.spdriveItem.identifier) && $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !refs.isEmpty || !files.isEmpty else { return false }
        if !refs.isEmpty {
            collect(refs, load: { p, done in _ = p.loadDataRepresentation(forTypeIdentifier: UTType.spdriveItem.identifier) { data, _ in done(data.flatMap { try? JSONDecoder().decode(ItemRef.self, from: $0) }?.id) } }) { ids in
                let items = ids.compactMap { model.item($0) }.filter { $0.id != folderID && $0.parentID != folderID }
                if !items.isEmpty { model.move(items, to: folderID) }
            }
        }
        if !files.isEmpty {
            collect(files, load: { p, done in _ = p.loadObject(ofClass: URL.self) { url, _ in done(url) } }) { urls in
                if !urls.isEmpty { Task { await model.upload(urls, to: folderID) } }
            }
        }
        return true
    }
    private static func collect<T: Sendable>(_ providers: [NSItemProvider], load: (NSItemProvider, @escaping @Sendable (T?) -> Void) -> Void, then: @escaping @MainActor ([T]) -> Void) {
        let box = LockedList<T>(), group = DispatchGroup()
        for p in providers { group.enter(); load(p) { v in if let v { box.append(v) }; group.leave() } }
        group.notify(queue: .main) { MainActor.assumeIsolated { then(box.values) } }
    }
}
final class LockedList<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func append(_ v: T) { lock.withLock { items.append(v) } }
    var values: [T] { lock.withLock { items } }
}
final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

// MARK: Grid cell
struct GridCell: View {
    let model: AppModel
    let nav: Navigator
    let row: BrowserRow
    let width: CGFloat
    let selected: Bool
    let moveInto: ([ItemRef]) -> Void
    @State private var hovered = false
    @State private var targeted = false

    var body: some View {
        let item = row.item, thumb = width - 32
        VStack(spacing: SPDTheme.Space.xs) {
            ZStack(alignment: .bottomTrailing) {
                ItemThumbnail(model: model, item: item, side: thumb)
                    .background(FrameAnchor(id: row.id))
                    .scaleEffect(targeted ? 1.06 : 1)
                ItemBadges(model: model, item: item).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule()).opacity(hasBadges ? 1 : 0).padding(2)
            }
            .frame(width: thumb, height: thumb)
            .padding(SPDTheme.Space.sm)
            .background((selected ? SPDTheme.selection : targeted ? SPDTheme.brandWash : hovered ? SPDTheme.surface : .clear), in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous).strokeBorder(SPDTheme.brand, lineWidth: targeted ? 2 : 0))
            if nav.renamingID == row.id {
                RenameField(initial: item.name, isFolder: item.isFolder, alignment: .center, commit: { nav.renamingID = nil; model.rename(item, to: $0) }, cancel: { nav.renamingID = nil }).frame(width: width - 8)
            } else {
                Text(item.name).font(SPDTheme.Typo.callout).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(selected ? SPDTheme.brand : .clear, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.xs + 1, style: .continuous))
                    .foregroundStyle(selected ? SPDTheme.onBrand : SPDTheme.textPrimary)
                Text(item.isFolder ? Fmt.day(row.modified) : "\(Fmt.bytes(item.size)) · \(Fmt.day(row.modified))").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary).lineLimit(1)
            }
        }
        .frame(width: width).padding(.vertical, SPDTheme.Space.xs)
        .contentShape(Rectangle())
        .opacity(item.isTrashed ? 0.75 : 1)
        .onHover { hovered = $0 }
        .onDrop(of: Drops.types, isTargeted: Binding(get: { targeted }, set: { targeted = $0 && item.isFolder && !item.isTrashed })) { providers in
            guard item.isFolder, !item.isTrashed else { return false }
            return Drops.handle(providers, into: item.id, model: model)
        }
        .spdMotion(.drop, value: targeted).spdMotion(.select, value: selected).spdMotion(.hover, value: hovered)
        .accessibilityElement(children: .combine).accessibilityLabel("\(item.name), \(row.kind)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var hasBadges: Bool {
        let i = row.item
        return model.isPending(i.id) || i.starred || model.sharedIDs.contains(i.id) || model.isPinned(i.id) || (!i.isFolder && model.isLocal(i.id)) || i.scan == "infected"
    }
}

// MARK: Path bar
/// Breadcrumbs of the current folder; each crumb accepts dropped items, long paths fold their middle into a menu.
struct PathBar: View {
    let model: AppModel
    let nav: Navigator
    var body: some View {
        let crumbs = nav.folderID.map { model.path(to: $0) } ?? []
        let folded = crumbs.count > 4 ? Array(crumbs.dropFirst().dropLast(2)) : []
        let shown = crumbs.count > 4 ? [crumbs[0]] + crumbs.suffix(2) : crumbs
        HStack(spacing: 2) {
            Crumb(model: model, nav: nav, name: "Mon Drive", symbol: "externaldrive", id: nil, current: crumbs.isEmpty)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, c in
                separator
                if index == 1, !folded.isEmpty {
                    Menu { ForEach(folded) { f in Button(f.name, systemImage: "folder") { nav.go(to: f.id, direction: .shallower) } } } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Dossiers intermédiaires")
                    separator
                }
                Crumb(model: model, nav: nav, name: c.name, symbol: "folder", id: c.id, current: c.id == crumbs.last?.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SPDTheme.Space.md).frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("Chemin")
    }
    private var separator: some View { Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(SPDTheme.textTertiary).accessibilityHidden(true) }
}
private struct Crumb: View {
    let model: AppModel
    let nav: Navigator
    let name: String, symbol: String
    let id: String?
    let current: Bool
    @State private var targeted = false
    @State private var hovered = false
    var body: some View {
        Button { nav.go(to: id, direction: .shallower) } label: {
            Label(name, systemImage: symbol).font(current ? SPDTheme.Typo.bodyStrong : SPDTheme.Typo.callout).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(targeted ? SPDTheme.selection : hovered && !current ? SPDTheme.surface : .clear, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.sm, style: .continuous).strokeBorder(SPDTheme.brand, lineWidth: targeted ? 1.5 : 0))
        }
        .buttonStyle(.plain).foregroundStyle(current ? SPDTheme.textPrimary : SPDTheme.textSecondary)
        .scaleEffect(targeted ? 1.05 : 1)
        .onHover { hovered = $0 }
        .onDrop(of: Drops.types, isTargeted: $targeted) { providers in
            guard let dest = id ?? model.rootID else { return false }
            return Drops.handle(providers, into: dest, model: model)
        }
        .spdMotion(.drop, value: targeted)
    }
}

/// Search filters: type, extension, date, size, favourites, shared, scope.
struct FilterBar: View {
    let model: AppModel
    let nav: Navigator
    var body: some View {
        @Bindable var nav = nav
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
        .background(.bar).overlay(alignment: .bottom) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
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
    let model: AppModel
    let count: Int
    let selection: [DriveItem]
    var showsGridSize = false
    var body: some View {
        HStack(spacing: SPDTheme.Space.md) {
            if selection.isEmpty { Text("\(count) élément\(count > 1 ? "s" : "")") }
            else { Text("\(selection.count) sélectionné\(selection.count > 1 ? "s" : "") · \(Fmt.bytes(selection.filter { !$0.isFolder }.reduce(0) { $0 + $1.size }))") }
            if !model.online { Label("Hors ligne — vos changements partiront au retour de la connexion", systemImage: "icloud.slash") }
            Spacer()
            if showsGridSize {
                Slider(value: Binding(get: { Double(model.settings.gridSize) }, set: { model.settings.gridSize = Int($0.rounded()) }), in: 0...2, step: 1).frame(width: 84).controlSize(.mini)
                    .accessibilityLabel("Taille des vignettes")
            }
        }
        .font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).padding(.horizontal, SPDTheme.Space.md).frame(height: 24)
        .background(.bar).overlay(alignment: .top) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
    }
}
