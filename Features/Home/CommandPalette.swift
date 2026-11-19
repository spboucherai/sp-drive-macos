// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/CommandPalette.swift
// Description: The command palette (⌘K): every action of the app by name, plus jumping to any folder or file of the local mirror. Entirely keyboard-driven; the commands are the real ones (the same closures as menus and toolbar), not shortcuts to them.
import AppKit
import SPDriveCore
import SwiftUI

struct PaletteCommand: Identifiable {
    enum Group: String { case go = "Aller à", selection = "Sélection", file = "Fichier", view = "Présentation", sync = "Synchronisation", app = "Application", item = "Dans votre Drive" }
    let id: String
    let title: String
    var subtitle = ""
    let symbol: String
    var shortcut = ""
    let group: Group
    var keywords = ""
    let run: @MainActor () -> Void
    var haystack: String { NameRules.searchKey(title + " " + keywords + " " + group.rawValue) }
}

@MainActor enum CommandCatalog {
    /// Every command that makes sense right now, in the order they are listed when nothing is typed.
    static func commands(model: AppModel, nav: Navigator, openWindow: @escaping @MainActor () -> Void, openSettings: @escaping @MainActor () -> Void) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        let selection = nav.selection.compactMap { model.item($0) }
        let live = selection.filter { !$0.isTrashed }
        let folder = nav.section == .drive ? (nav.folderID ?? model.rootID) : model.rootID
        func add(_ id: String, _ title: String, _ symbol: String, _ group: PaletteCommand.Group, shortcut: String = "", subtitle: String = "", keywords: String = "", _ run: @escaping @MainActor () -> Void) {
            out.append(PaletteCommand(id: id, title: title, subtitle: subtitle, symbol: symbol, shortcut: shortcut, group: group, keywords: keywords, run: run))
        }
        if !live.isEmpty, live.count == selection.count {
            let what = live.count == 1 ? "« \(live[0].name) »" : "\(live.count) éléments"
            if let s = live.first, live.count == 1 {
                add("sel.open", "Ouvrir \(what)", s.isFolder ? "folder" : "arrow.up.forward.app", .selection, shortcut: "⌘↓") { if s.isFolder { nav.go(to: s.id) } else { Task { await model.open(s) } } }
                add("sel.share", "Partager \(what) par lien…", "link", .selection, shortcut: "⇧⌘L", keywords: "lien") { nav.sheet = .share(s) }
                if s.isFolder, model.has(.collab) { add("sel.members", "Membres de \(what)…", "person.2", .selection, keywords: "partage privé rôle inviter") { nav.sheet = .members(s) } }
                if model.has(.ai) { add("sel.ask", "Demander à \(what)…", "sparkles", .selection, keywords: "question ia") { nav.sheet = .ask(s) } }
                add("sel.rename", "Renommer \(what)", "pencil", .selection, shortcut: "↩") { nav.renamingID = s.id }
                if !s.isFolder { add("sel.versions", "Historique des versions de \(what)…", "clock.arrow.circlepath", .selection) { nav.sheet = .versions(s) } }
                add("sel.reveal", "Afficher \(what) dans le Finder", "macwindow", .selection, shortcut: "⇧⌘R") { Task { await model.revealInFinder(s) } }
            }
            add("sel.download", "Télécharger \(what)", "arrow.down.circle", .selection, shortcut: "⌥⌘D") { Task { await model.download(live) } }
            add("sel.move", "Déplacer \(what)…", "folder.badge.gearshape", .selection, shortcut: "⇧⌘M") { nav.sheet = .move(live) }
            add("sel.duplicate", "Dupliquer \(what)", "plus.square.on.square", .selection, shortcut: "⌘D") { model.duplicate(live) }
            let starred = live.allSatisfy(\.starred)
            add("sel.star", starred ? "Retirer \(what) des favoris" : "Ajouter \(what) aux favoris", starred ? "star.slash" : "star", .selection, shortcut: "⌃⌘F", keywords: "étoile favori") { model.setStarred(live, !starred) }
            let pinned = live.allSatisfy { model.isPinnedItself($0.id) }
            add("sel.pin", pinned ? "Ne plus garder \(what) hors ligne" : "Garder \(what) disponible hors ligne", pinned ? "pin.slash" : "pin", .selection, shortcut: "⇧⌘P", keywords: "épingler offline") { Task { await model.setPinned(live, !pinned) } }
            add("sel.info", "Lire les informations", "info.circle", .selection, shortcut: "⌘I") { nav.showInspector = true }
            add("sel.trash", "Supprimer \(what) du Drive", "trash", .selection, shortcut: "⌘⌫", keywords: "corbeille effacer") { model.trash(live) }
        }
        for s in [SidebarItem.drive, .recent, .favorites, .offline, .shared, .sharedWithMe, .portals, .collections, .transfers, .conflicts, .activity, .trash, .storage, .admin] where model.isAvailable(s) {
            add("go.\(s.rawValue)", s.title, s.symbol, .go, keywords: "aller ouvrir section") { nav.section = s }
        }
        if nav.section == .drive, let id = nav.folderID, let f = model.item(id) { add("go.parent", "Dossier parent", "arrow.up", .go, shortcut: "⌘↑") { nav.go(to: f.parentID == model.rootID ? nil : f.parentID, direction: .shallower) } }
        if nav.canGoBack { add("go.back", "Précédent", "chevron.left", .go, shortcut: "⌘[") { nav.back() } }
        if let folder {
            add("file.newFolder", "Nouveau dossier", "folder.badge.plus", .file, shortcut: "⇧⌘N", keywords: "créer") { if nav.section != .drive { nav.section = .drive }; nav.sheet = .newFolder(parent: folder) }
            add("file.upload", "Téléverser des fichiers ou des dossiers…", "arrow.up.doc", .file, shortcut: "⌘U", keywords: "envoyer ajouter importer upload") {
                let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: folder) } }
            }
            if let f = model.item(folder) { add("file.portal", "Créer un lien de dépôt…", "tray.and.arrow.down", .file, keywords: "portail recevoir") { nav.sheet = .portal(folder: f) } }
        }
        if model.has(.ai) { add("ai.ask", "Demander à mon Drive…", "sparkles", .file, shortcut: "⌥⌘A", keywords: "question ia ai intelligence modèle") { AskWindow.open() } }
        if model.has(.collections) { add("file.collection", "Nouvelle collection…", "square.stack.3d.up", .file, keywords: "règle intelligente") { nav.sheet = .collection(nil) } }
        add("file.window", "Nouvelle fenêtre", "macwindow.badge.plus", .file, shortcut: "⌘N") { openWindow() }
        add("view.list", "Afficher en liste", "list.bullet", .view, shortcut: "⌘1") { model.settings.gridView = false }
        add("view.grid", "Afficher en grille", "square.grid.2x2", .view, shortcut: "⌘2", keywords: "vignettes icônes") { model.settings.gridView = true }
        add("view.inspector", nav.showInspector ? "Masquer les informations" : "Afficher les informations", "sidebar.trailing", .view, shortcut: "⌘I", keywords: "inspecteur") { nav.showInspector.toggle() }
        add("view.search", "Rechercher dans le Drive", "magnifyingglass", .view, shortcut: "⌘F") { DispatchQueue.main.async { WindowTools.focusSearch(in: WindowTools.keyBrowserWindow) } }
        add("sync.now", "Synchroniser maintenant", "arrow.clockwise", .sync, shortcut: "⌘R") { Task { await model.syncNow() } }
        add("sync.pause", model.settings.syncPaused ? "Reprendre la synchronisation" : "Mettre la synchronisation en pause", model.settings.syncPaused ? "play.fill" : "pause.fill", .sync, keywords: "pause reprendre transferts") { Task { await model.setPaused(!model.settings.syncPaused) } }
        if model.transfers.contains(where: { $0.state == .failed }) { add("sync.retry", "Réessayer les transferts en échec", "arrow.clockwise.circle", .sync) { Task { await model.retryAllFailed() } } }
        if model.transfers.contains(where: { $0.state == .done || $0.state == .cancelled }) { add("sync.clear", "Effacer les transferts terminés", "checkmark.circle.badge.xmark", .sync) { Task { await model.clearFinishedTransfers() } } }
        if let c = model.conflicts.first(where: \.isOpen) { add("sync.conflict", "Régler le conflit sur « \(c.itemName) »…", "exclamationmark.triangle", .sync) { nav.sheet = .conflict(c) } }
        if model.finderReady { add("app.finder", "Ouvrir SP Drive dans le Finder", "folder", .app, shortcut: "⇧⌘O") { Task { await DriveDomain.shared.openInFinder() } } }
        if !model.trash().isEmpty { add("app.emptyTrash", "Vider la corbeille…", "trash.slash", .app) { nav.section = .trash; nav.confirmEmptyTrash = true } }
        add("app.settings", "Paramètres…", "gearshape", .app, shortcut: "⌘,", keywords: "réglages préférences") { openSettings() }
        return out
    }
    /// Commands and items matching what was typed (every word must appear, accents and case ignored).
    static func results(for query: String, commands: [PaletteCommand], model: AppModel, nav: Navigator) -> [PaletteCommand] {
        let words = NameRules.searchKey(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return commands }
        var hits = commands.filter { c in let h = c.haystack; return words.allSatisfy { h.contains($0) } }
        // commands whose title starts with what was typed come first
        let first = words[0]
        hits.sort { a, b in let pa = NameRules.searchKey(a.title).hasPrefix(first), pb = NameRules.searchKey(b.title).hasPrefix(first); return pa && !pb }
        if query.trimmingCharacters(in: .whitespaces).count >= 2 {
            var q = LocalSearch(); q.text = query; q.limit = 8
            for item in model.search(q) {
                let path = model.path(to: item.id).dropLast().map(\.name).joined(separator: " › ")
                hits.append(PaletteCommand(id: "item.\(item.id)", title: item.name, subtitle: path.isEmpty ? "Mon Drive" : "Mon Drive › " + path, symbol: item.isFolder ? "folder" : "doc", group: .item) {
                    if item.isFolder { nav.go(to: item.id) }
                    else { nav.go(to: item.parentID == model.rootID ? nil : item.parentID); nav.selection = [item.id] }
                })
            }
        }
        return hits
    }
}

struct CommandPalette: View {
    let model: AppModel
    let nav: Navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        let all = CommandCatalog.commands(model: model, nav: nav, openWindow: { openWindow(id: "main") }, openSettings: { NSApp.activate(ignoringOtherApps: true); openSettings() })
        let results = CommandCatalog.results(for: query, commands: all, model: model, nav: nav)
        VStack(spacing: 0) {
            HStack(spacing: SPDTheme.Space.sm) {
                Image(systemName: "command").foregroundStyle(SPDTheme.brand).font(.system(size: 15, weight: .medium))
                TextField("Une commande, un dossier, un fichier…", text: $query).textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                    .onSubmit { run(results) }.accessibilityIdentifier("palette-field")
                Text("esc").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary).padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SPDTheme.hairline))
            }
            .padding(.horizontal, SPDTheme.Space.lg).frame(height: 50)
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            if results.isEmpty {
                Text("Aucune commande ni aucun élément pour « \(query) ».").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).padding(SPDTheme.Space.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                                if i == 0 || results[i - 1].group != c.group { Text(c.group.rawValue).spdEyebrow().padding(.horizontal, SPDTheme.Space.md).padding(.top, SPDTheme.Space.sm).padding(.bottom, 2) }
                                PaletteRow(command: c, selected: i == index).id(c.id)
                                    .onTapGesture { index = i; run(results) }
                            }
                        }
                        .padding(SPDTheme.Space.sm)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: index) { _, i in if results.indices.contains(i) { proxy.scrollTo(results[i].id) } }
                }
            }
        }
        .frame(width: SPDTheme.Size.palette)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.lg, style: .continuous).strokeBorder(SPDTheme.hairline))
        .spdElevation(.e2)
        .background(KeyCatcher { e in
            guard nav.showPalette else { return false }
            switch e.keyCode {
            case Key.down: index = min(index + 1, max(results.count - 1, 0)); return true
            case Key.up: index = max(index - 1, 0); return true
            case Key.escape: close(); return true
            case Key.return, Key.enter: run(results); return true
            default: return false
            }
        })
        .onChange(of: query) { _, _ in index = 0 }
        .onAppear { focused = true }
        .accessibilityAddTraits(.isModal).accessibilityLabel("Palette de commandes")
    }
    private func close() { spdAnimate(.dismiss) { nav.showPalette = false } }
    private func run(_ results: [PaletteCommand]) {
        guard results.indices.contains(index) else { return }
        let c = results[index]
        close()
        c.run()
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let selected: Bool
    var body: some View {
        HStack(spacing: SPDTheme.Space.md) {
            Image(systemName: command.symbol).frame(width: 20).foregroundStyle(selected ? SPDTheme.onBrand : SPDTheme.brand)
            VStack(alignment: .leading, spacing: 0) {
                Text(command.title).font(SPDTheme.Typo.body).lineLimit(1).truncationMode(.middle)
                if !command.subtitle.isEmpty { Text(command.subtitle).font(SPDTheme.Typo.caption).foregroundStyle(selected ? SPDTheme.onBrand.opacity(0.8) : SPDTheme.textTertiary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            if !command.shortcut.isEmpty { Text(command.shortcut).font(SPDTheme.Typo.callout).foregroundStyle(selected ? SPDTheme.onBrand.opacity(0.85) : SPDTheme.textTertiary) }
        }
        .padding(.horizontal, SPDTheme.Space.md).padding(.vertical, 6)
        .foregroundStyle(selected ? SPDTheme.onBrand : SPDTheme.textPrimary)
        .background(selected ? SPDTheme.brand : .clear, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
