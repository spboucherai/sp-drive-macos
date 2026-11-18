// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/MyDrive/ItemActions.swift
// Description: What can be done with the selected items — context menu, toolbar, application menu and keyboard shortcuts share the same actions.
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
    @Environment(AppModel.self) private var model
    let items: [DriveItem]
    let currentFolderID: String?
    var preview: (DriveItem?) -> Void = { _ in }

    var body: some View {
        let nav = model.nav
        if items.isEmpty {
            if let id = currentFolderID {
                Button("Nouveau dossier", systemImage: "folder.badge.plus") { nav.sheet = .newFolder(parent: id) }
                Button("Téléverser…", systemImage: "arrow.up.doc") { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: id) } } }
            }
            if nav.section == .trash { Button("Vider la corbeille…", systemImage: "trash.slash", role: .destructive) { nav.confirmEmptyTrash = true } }
        } else if items.allSatisfy(\.isTrashed) {
            Button("Restaurer", systemImage: "arrow.uturn.backward") { model.restore(items) }
            Divider()
            Button("Supprimer définitivement…", systemImage: "trash.slash", role: .destructive) { nav.confirmPurge = items }
        } else {
            let single = items.count == 1 ? items.first : nil
            if let s = single {
                Button(s.isFolder ? "Ouvrir" : "Ouvrir", systemImage: "arrow.up.forward.app") { if s.isFolder { nav.open(folder: s.id) } else { Task { await model.open(s) } } }
                if !s.isFolder { Button("Coup d’œil", systemImage: "eye") { preview(s) } }
                Button("Afficher dans le Finder", systemImage: "folder") { Task { await model.revealInFinder(s) } }
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
                Button("Partager…", systemImage: "link") { nav.sheet = .share(s) }
                if s.isFolder { Button("Créer un lien de dépôt…", systemImage: "tray.and.arrow.down") { nav.sheet = .portal(folder: s) } }
                else {
                    Button("Historique des versions…", systemImage: "clock.arrow.circlepath") { nav.sheet = .versions(s) }
                    Button("Téléverser une nouvelle version…", systemImage: "arrow.up.doc") { if let u = Pickers.chooseFile(message: "Nouvelle version de « \(s.name) »") { Task { await model.uploadNewVersion(of: s, from: u) } } }
                }
                Divider()
                Button("Renommer…", systemImage: "pencil") { nav.sheet = .rename(s) }
            }
            Button("Déplacer…", systemImage: "folder.badge.gearshape") { nav.sheet = .move(items) }
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
    let currentFolderID: String?
    let selection: [DriveItem]

    var body: some ToolbarContent {
        let nav = model.nav
        ToolbarItem(placement: .navigation) {
            Button { goUp() } label: { Label("Dossier parent", systemImage: "chevron.left") }
                .disabled(nav.section != .drive || nav.folderID == nil).help("Remonter au dossier parent (⌘↑)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let id = currentFolderID {
                Button { nav.sheet = .newFolder(parent: id) } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }.help("Nouveau dossier (⇧⌘N)")
                Button { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: id) } } } label: { Label("Téléverser", systemImage: "arrow.up.doc") }.help("Téléverser des fichiers ou des dossiers (⌘U)")
            }
            if nav.section == .trash {
                Button { nav.confirmEmptyTrash = true } label: { Label("Vider la corbeille", systemImage: "trash.slash") }.disabled(model.trash().isEmpty).help("Vider la corbeille")
            } else {
                Button { Task { await model.download(selection) } } label: { Label("Télécharger", systemImage: "arrow.down.circle") }.disabled(selection.isEmpty).help("Télécharger la sélection")
                Button { if let s = selection.first { nav.sheet = .share(s) } } label: { Label("Partager", systemImage: "link") }.disabled(selection.count != 1).help("Créer ou gérer un lien de partage")
            }
            Picker("Présentation", selection: Binding(get: { model.settings.gridView }, set: { model.settings.gridView = $0 })) {
                Label("Liste", systemImage: "list.bullet").tag(false)
                Label("Grille", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented).help("Liste ou grille")
            Button { nav.showInspector.toggle() } label: { Label("Informations", systemImage: "sidebar.trailing") }.help("Afficher les informations (⌘I)")
        }
    }
    private func goUp() {
        guard let id = model.nav.folderID, let f = model.item(id) else { model.nav.folderID = nil; return }
        model.nav.folderID = f.parentID == model.rootID ? nil : f.parentID
    }
}

/// Menu-bar commands and their keyboard shortcuts.
struct AppCommands: Commands {
    let model: AppModel
    private var nav: Navigator { model.nav }
    private var selection: [DriveItem] { nav.selection.compactMap { model.item($0) } }
    private var folder: String? { nav.section == .drive ? (nav.folderID ?? model.rootID) : nil }
    private var signedIn: Bool { model.phase == .signedIn && !model.locked }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouveau dossier") { if let f = folder { nav.sheet = .newFolder(parent: f) } }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!signedIn || folder == nil)
            Button("Téléverser…") { if let f = folder { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: f) } } } }.keyboardShortcut("u").disabled(!signedIn || folder == nil)
            Divider()
            Button("Ouvrir") { if let s = selection.first { if s.isFolder { nav.open(folder: s.id) } else { Task { await model.open(s) } } } }.keyboardShortcut(.downArrow).disabled(selection.count != 1)
            Button("Dossier parent") { if let id = nav.folderID, let f = model.item(id) { nav.folderID = f.parentID == model.rootID ? nil : f.parentID } }.keyboardShortcut(.upArrow).disabled(nav.folderID == nil)
            Button("Télécharger") { Task { await model.download(selection) } }.keyboardShortcut("d", modifiers: [.command, .option]).disabled(selection.isEmpty)
            Button("Afficher dans le Finder") { if let s = selection.first { Task { await model.revealInFinder(s) } } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(selection.count != 1)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Renommer…") { if let s = selection.first { nav.sheet = .rename(s) } }.disabled(selection.count != 1 || selection.first?.isTrashed == true)
            Button("Déplacer…") { nav.sheet = .move(selection) }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(selection.isEmpty || selection.contains(where: \.isTrashed))
            Button("Dupliquer") { model.duplicate(selection) }.keyboardShortcut("d").disabled(selection.isEmpty || selection.contains(where: \.isTrashed))
            Button("Ajouter aux favoris") { model.setStarred(selection, true) }.keyboardShortcut("f", modifiers: [.command, .control]).disabled(selection.isEmpty)
            Button("Garder disponible hors ligne") { Task { await model.setPinned(selection, true) } }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(selection.isEmpty)
            Button("Partager…") { if let s = selection.first { nav.sheet = .share(s) } }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(selection.count != 1)
            Button("Supprimer du Drive") { model.trash(selection) }.keyboardShortcut(.delete).disabled(selection.isEmpty || selection.contains(where: \.isTrashed))
        }
        CommandGroup(after: .sidebar) {
            Button("En liste") { model.settings.gridView = false }.keyboardShortcut("1")
            Button("En grille") { model.settings.gridView = true }.keyboardShortcut("2")
            Button("Informations") { nav.showInspector.toggle() }.keyboardShortcut("i")
            Divider()
            ForEach(Array([SidebarItem.drive, .recent, .favorites, .offline, .transfers, .trash].enumerated()), id: \.element) { i, s in
                Button(s.title) { nav.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 3)")), modifiers: [.command, .option])
            }
        }
        CommandMenu("Synchronisation") {
            Button("Synchroniser maintenant") { Task { await model.syncNow() } }.keyboardShortcut("r").disabled(!signedIn)
            Button(model.settings.syncPaused ? "Reprendre la synchronisation" : "Mettre en pause") { Task { await model.setPaused(!model.settings.syncPaused) } }.disabled(!signedIn)
            Divider()
            Button("Ouvrir SP Drive dans le Finder") { Task { await DriveDomain.shared.openInFinder() } }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.finderReady)
        }
    }
}
