// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/MyDrive/ItemActions.swift
// Description      : What can be done with the selected items — context menu,
//                    toolbar, application menu and keyboard shortcuts share the
//                    same actions. Model and navigator are passed explicitly:
//                    menus and toolbars are hosted outside the SwiftUI
//                    environment.
// Module           : Features
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

import AppKit
import SPDriveCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum Pickers {
    /// Lets the person choose files and folders to send.
    static func chooseUploads() -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Téléverser"; p.message = "Choisissez les fichiers et dossiers à envoyer sur SP Drive"
        return p.runModal() == .OK ? p.urls : []
    }
    static func chooseFile(message: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false; p.message = message; p.prompt = "Choisir"
        return p.runModal() == .OK ? p.url : nil
    }
    static func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct ItemMenu: View {
    let model: AppModel
    let nav: Navigator
    let items: [DriveItem]
    let currentFolderID: String?
    var preview: (DriveItem?) -> Void = { _ in }
    var rename: ((DriveItem) -> Void)?

    var body: some View {
        if items.isEmpty {
            if let id = currentFolderID {
                Button("Nouveau dossier", systemImage: "folder.badge.plus") { nav.sheet = .newFolder(parent: id) }
                Button("Téléverser…", systemImage: "arrow.up.doc") { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: id) } } }
                Divider()
                Button(model.settings.gridView ? "Afficher en liste" : "Afficher en grille", systemImage: model.settings.gridView ? "list.bullet" : "square.grid.2x2") { model.settings.gridView.toggle() }
            }
            if nav.section == .trash { Button("Vider la corbeille…", systemImage: "trash.slash", role: .destructive) { nav.confirmEmptyTrash = true } }
        } else if items.allSatisfy(\.isTrashed) {
            Button("Restaurer", systemImage: "arrow.uturn.backward") { model.restore(items) }
            Divider()
            Button("Supprimer définitivement…", systemImage: "trash.slash", role: .destructive) { nav.confirmPurge = items }
        } else {
            let single = items.count == 1 ? items.first : nil
            if let s = single {
                Button("Ouvrir", systemImage: s.isFolder ? "folder" : "arrow.up.forward.app") { if s.isFolder { nav.go(to: s.id) } else { Task { await model.open(s) } } }
                if !s.isFolder { Button("Coup d’œil", systemImage: "eye") { preview(s) } }
                Button("Afficher dans le Finder", systemImage: "macwindow") { Task { await model.revealInFinder(s) } }
                Divider()
            }
            Button("Télécharger", systemImage: "arrow.down.circle") { Task { await model.download(items) } }
            let allPinned = items.allSatisfy { model.isPinnedItself($0.id) }
            Button(allPinned ? "Ne plus garder hors ligne" : "Garder disponible hors ligne", systemImage: allPinned ? "pin.slash" : "pin") { Task { await model.setPinned(items, !allPinned) } }
            if items.contains(where: { !$0.isFolder && model.isLocal($0.id) && !model.isPinned($0.id) }) {
                Button("Libérer l’espace sur ce Mac", systemImage: "icloud.and.arrow.up") {
                    Task {
                        let r = await model.freeUpSpace(items.filter { !$0.isFolder }.map(\.id))
                        model.banner = Banner(text: r.kept == 0 ? "\(r.freed) copie(s) locale(s) retirée(s). Les fichiers restent sur SP Drive." : "\(r.freed) copie(s) retirée(s), \(r.kept) conservée(s) (épinglées ou pas encore envoyées).", isError: false)
                    }
                }
            }
            Divider()
            if let s = single {
                Button("Partager par lien…", systemImage: "link") { nav.sheet = .share(s) }
                if s.isFolder, model.has(.collab) { Button("Membres…", systemImage: "person.2") { nav.sheet = .members(s) } }
                if model.has(.ai), !model.isPending(s.id) { Button(s.isFolder ? "Demander à ce dossier…" : "Demander à ce document…", systemImage: "sparkles") { nav.sheet = .ask(s) } }
                if s.isFolder { Button("Créer un lien de dépôt…", systemImage: "tray.and.arrow.down") { nav.sheet = .portal(folder: s) } }
                else {
                    Button("Historique des versions…", systemImage: "clock.arrow.circlepath") { nav.sheet = .versions(s) }
                    Button("Téléverser une nouvelle version…", systemImage: "arrow.up.doc") { if let u = Pickers.chooseFile(message: "Nouvelle version de « \(s.name) »") { Task { await model.uploadNewVersion(of: s, from: u) } } }
                }
                Divider()
                Button("Renommer", systemImage: "pencil") { if let rename { rename(s) } else { nav.sheet = .rename(s) } }
            }
            Button("Déplacer…", systemImage: "folder.badge.gearshape") { nav.sheet = .move(items) }
            if model.has(.ai), items.contains(where: { !$0.isFolder }) { Button("Suggestions de rangement…", systemImage: "sparkles") { nav.sheet = .suggest(items.filter { !$0.isFolder }) } }
            Button("Dupliquer", systemImage: "plus.square.on.square") { model.duplicate(items) }
            let allStarred = items.allSatisfy(\.starred)
            Button(allStarred ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: allStarred ? "star.slash" : "star") { model.setStarred(items, !allStarred) }
            Button("Lire les informations", systemImage: "info.circle") { nav.selection = Set(items.map(\.id)); nav.showInspector = true }
            Divider()
            Button("Supprimer du Drive", systemImage: "trash", role: .destructive) { model.trash(items) }
        }
    }
}

struct BrowserToolbar: ToolbarContent {
    let model: AppModel
    let nav: Navigator
    let currentFolderID: String?
    let selection: [DriveItem]
    @Binding var sort: (BrowserSort, SortOrder)

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { nav.back() } label: { Label("Précédent", systemImage: "chevron.left") }.disabled(!nav.canGoBack).help("Dossier précédent (⌘[)")
                Button { nav.forward() } label: { Label("Suivant", systemImage: "chevron.right") }.disabled(!nav.canGoForward).help("Dossier suivant (⌘])")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let id = currentFolderID {
                Menu {
                    Button("Nouveau dossier", systemImage: "folder.badge.plus") { nav.sheet = .newFolder(parent: id) }
                    Button("Téléverser des fichiers ou des dossiers…", systemImage: "arrow.up.doc") { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: id) } } }
                    if let f = model.item(id) { Button("Créer un lien de dépôt vers ce dossier…", systemImage: "tray.and.arrow.down") { nav.sheet = .portal(folder: f) } }
                } label: { Label("Ajouter", systemImage: "plus") } primaryAction: {
                    let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: id) } }
                }
                .help("Téléverser (⌘U) — maintenir pour créer un dossier (⇧⌘N)")
            }
            if nav.section == .trash {
                Button { nav.confirmEmptyTrash = true } label: { Label("Vider la corbeille", systemImage: "trash.slash") }.disabled(model.trash().isEmpty).help("Vider la corbeille")
            } else {
                Button { Task { await model.download(selection) } } label: { Label("Télécharger", systemImage: "arrow.down.circle") }.disabled(selection.isEmpty).help("Télécharger la sélection (⌥⌘D)")
                Button { if let s = selection.first { nav.sheet = .share(s) } } label: { Label("Partager", systemImage: "link") }.disabled(selection.count != 1).help("Créer ou gérer un lien de partage (⇧⌘L)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Présentation", selection: Binding(get: { model.settings.gridView }, set: { model.settings.gridView = $0 })) {
                Label("Liste", systemImage: "list.bullet").tag(false)
                Label("Grille", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented).help("Liste (⌘1) ou grille (⌘2)")
            Menu {
                Picker("Trier par", selection: Binding(get: { sort.0 }, set: { sort = ($0, sort.1) })) { ForEach(BrowserSort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline)
                Picker("Ordre", selection: Binding(get: { sort.1 == .forward }, set: { sort = (sort.0, $0 ? .forward : .reverse) })) { Text("Croissant").tag(true); Text("Décroissant").tag(false) }.pickerStyle(.inline)
            } label: { Label("Trier", systemImage: "arrow.up.arrow.down") }.help("Ordre de tri")
            if model.has(.ai) { Button { AskWindow.open() } label: { Label("Demander à mon Drive", systemImage: "sparkles") }.help("Demander à mon Drive (⌥⌘A)") }
            Button { nav.showPalette = true } label: { Label("Commandes", systemImage: "command") }.help("Palette de commandes (⌘K)")
            Button { nav.showInspector.toggle() } label: { Label("Informations", systemImage: "sidebar.trailing") }.help("Afficher les informations (⌘I)")
        }
    }
}

/// Menu-bar commands and their keyboard shortcuts. They act on the window that has the focus, and enable themselves from
/// what that window publishes (`WindowFocus`).
struct AppCommands: Commands {
    let model: AppModel
    /// State of the key window, kept current by the model: that is what re-validates the menus.
    @ObservedObject var bridge: MenuBridge
    private var info: WindowFocus? { bridge.focus }
    @Environment(\.openWindow) private var openWindow
    private var nav: Navigator { model.activeNav ?? model.nav }
    private var selection: [DriveItem] { nav.selection.compactMap { model.item($0) } }
    private var folder: String? { nav.section == .drive ? (nav.folderID ?? model.rootID) : nil }
    /// A signed-in, unlocked window has the focus.
    private var ready: Bool { info.map { !$0.locked } ?? false }
    private var count: Int { ready ? (info?.selectionCount ?? 0) : 0 }
    private var live: Bool { !(info?.selectionHasTrashed ?? false) }
    private func parent() { guard let id = nav.folderID, let f = model.item(id) else { return }; nav.go(to: f.parentID == model.rootID ? nil : f.parentID, direction: .shallower) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouvelle fenêtre") { openWindow(id: "main") }.keyboardShortcut("n")
            Button("Nouveau dossier") { if let f = folder { nav.sheet = .newFolder(parent: f) } }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!ready || info?.hasFolder != true)
            Button("Téléverser…") { if let f = folder { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: f) } } } }.keyboardShortcut("u").disabled(!ready || info?.hasFolder != true)
            Divider()
            Button("Ouvrir") { if let s = selection.first { if s.isFolder { nav.go(to: s.id) } else { Task { await model.open(s) } } } }.keyboardShortcut(.downArrow).disabled(count != 1 || !live)
            Button("Dossier parent") { parent() }.keyboardShortcut(.upArrow).disabled(!ready || info?.folderID == nil || info?.section != .drive)
            Button("Précédent") { nav.back() }.keyboardShortcut("[").disabled(!ready || info?.canGoBack != true)
            Button("Suivant") { nav.forward() }.keyboardShortcut("]").disabled(!ready || info?.canGoForward != true)
            Divider()
            Button("Télécharger") { Task { await model.download(selection) } }.keyboardShortcut("d", modifiers: [.command, .option]).disabled(count == 0 || !live)
            Button("Afficher dans le Finder") { if let s = selection.first { Task { await model.revealInFinder(s) } } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(count != 1 || !live)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Renommer") { if let s = selection.first { nav.renamingID = s.id } }.disabled(count != 1 || !live)
            Button("Déplacer…") { nav.sheet = .move(selection) }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(count == 0 || !live)
            Button("Dupliquer") { model.duplicate(selection) }.keyboardShortcut("d").disabled(count == 0 || !live)
            Button("Ajouter aux favoris") { model.setStarred(selection, true) }.keyboardShortcut("f", modifiers: [.command, .control]).disabled(count == 0 || !live)
            Button("Garder disponible hors ligne") { Task { await model.setPinned(selection, true) } }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(count == 0 || !live)
            Button("Partager…") { if let s = selection.first { nav.sheet = .share(s) } }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(count != 1 || !live)
            Button("Supprimer du Drive") { model.trash(selection) }.keyboardShortcut(.delete).disabled(count == 0 || !live)
            Divider()
            Button("Rechercher") { WindowTools.focusSearch(in: WindowTools.keyBrowserWindow) }.keyboardShortcut("f").disabled(!ready)
            Button("Palette de commandes…") { nav.showPalette.toggle() }.keyboardShortcut("k").disabled(!ready)
        }
        CommandGroup(after: .sidebar) {
            Button("En liste") { model.settings.gridView = false }.keyboardShortcut("1").disabled(!ready)
            Button("En grille") { model.settings.gridView = true }.keyboardShortcut("2").disabled(!ready)
            Button("Informations") { nav.showInspector.toggle() }.keyboardShortcut("i").disabled(!ready)
            Divider()
            ForEach(Array([SidebarItem.drive, .recent, .favorites, .offline, .transfers, .trash].enumerated()), id: \.element) { i, s in
                Button(s.title) { nav.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 3)")), modifiers: [.command, .option]).disabled(!ready)
            }
        }
        CommandMenu("Synchronisation") {
            Button("Synchroniser maintenant") { Task { await model.syncNow() } }.keyboardShortcut("r").disabled(!ready)
            Button(info?.paused == true ? "Reprendre la synchronisation" : "Mettre en pause") { Task { await model.setPaused(!model.settings.syncPaused) } }.disabled(!ready)
            Button("Demander à mon Drive") { AskWindow.open() }.keyboardShortcut("a", modifiers: [.command, .option]).disabled(!ready || !model.has(.ai))
            Button("Centre de transferts") { nav.section = .transfers }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(!ready)
            Divider()
            Button("Ouvrir SP Drive dans le Finder") { Task { await DriveDomain.shared.openInFinder() } }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(info?.finderReady != true)
        }
    }
}
