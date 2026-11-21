// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Next/SharedWithMeView.swift
// Description      : "Partagés avec moi": folders other accounts shared with
//                    this one, browsed through the grant routes of the server
//                    (they are not part of this account's tree, nor of its
//                    Finder location). The interface follows the role: a reader
//                    browses, previews and downloads; an editor also creates,
//                    renames, uploads and trashes; a depositor only sends files
//                    in. An action the role does not allow is absent, and a 403
//                    from the server is said as such.
// Module           : Features
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

import AppKit
import SPDriveCore
import SPDriveNext
import SwiftUI

struct SharedWithMeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var grant: SharedGrant?
    @State private var folderID: String?
    @State private var listing: Loadable<SharedListing> = .loading
    @State private var selection: Set<String> = []
    @State private var note: String?
    @State private var renaming: (id: String, name: String)?
    @State private var newFolder = false
    @State private var newName = ""
    @State private var uploads: [String: Double] = [:]
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let g = grant { inside(g) } else { grantList }
        }
        .navigationTitle(grant?.displayName ?? "Partagés avec moi")
        .navigationSubtitle(grant.map { "Partagé par \($0.owner.displayName) · \(NextText.role($0.role))" } ?? "")
        .task { await model.refreshGrants() }
        .accessibilityIdentifier("shared-with-me")
    }
    private var grantList: some View {
        Group {
            if model.grants.isEmpty {
                SPDEmptyState(symbol: "person.2", title: "Rien n’est partagé avec vous", message: "Quand une autre personne de ce serveur vous donne accès à l’un de ses dossiers, il apparaît ici. Vous n’y voyez que ce dossier, jamais le reste de son Drive.")
            } else {
                List(model.grants) { g in
                    Button { open(g) } label: {
                        HStack(spacing: SPDTheme.Space.md) {
                            Image(systemName: g.role == .uploader ? "tray.and.arrow.down.fill" : "folder.fill.badge.person.crop").font(.title2).foregroundStyle(SPDTheme.brand).frame(width: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.displayName).font(SPDTheme.Typo.bodyStrong)
                                Text("Partagé par \(g.owner.displayName)\(g.createdAt.map { " le \(Fmt.day($0))" } ?? "")").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                            }
                            Spacer()
                            SPDPill(text: NextText.role(g.role), symbol: g.role == .viewer ? "eye" : g.role == .editor ? "pencil" : "tray.and.arrow.down", tint: SPDTheme.brand)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(SPDTheme.textTertiary)
                        }.contentShape(Rectangle()).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
        }
    }
    private func open(_ g: SharedGrant) { grant = g; folderID = nil; selection = []; note = nil; listing = .loading; Task { await load() } }

    private func crumbs(_ g: SharedGrant) -> some View {
        let list = listing.value?.breadcrumbs ?? [NextCrumb(id: g.folder.id, name: g.displayName)]
        let here = listing.value?.folder.id
        return HStack(spacing: 2) {
            Button { grant = nil } label: { Label("Partagés avec moi", systemImage: "person.2") }.buttonStyle(.plain).foregroundStyle(SPDTheme.textSecondary).font(SPDTheme.Typo.callout)
            ForEach(list) { c in
                Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(SPDTheme.textTertiary)
                Button(c.id == g.folder.id ? g.displayName : c.name) { folderID = c.id == g.folder.id ? nil : c.id; Task { await load() } }
                    .buttonStyle(.plain).font(c.id == here ? SPDTheme.Typo.bodyStrong : SPDTheme.Typo.callout)
            }
            Spacer()
        }
        .padding(.horizontal, SPDTheme.Space.md).frame(height: 30).background(.bar).overlay(alignment: .bottom) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
    }
    @ViewBuilder private func body(of g: SharedGrant) -> some View {
        if g.role == .uploader { depositOnly(g) }
        else {
            switch listing {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m): SPDEmptyState(symbol: "exclamationmark.triangle", title: "Dossier indisponible", message: m) { Button("Revenir à la liste") { grant = nil; Task { await model.refreshGrants() } } }
            case .ready(let l): browser(g, l)
            }
        }
    }
    private func dropped(_ providers: [NSItemProvider], _ g: SharedGrant) -> Bool {
        guard g.role.canUpload else { return false }
        let group = DispatchGroup(), box = LockedList<URL>()
        for p in providers { group.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { box.append(u) }; group.leave() } }
        group.notify(queue: .main) { MainActor.assumeIsolated { let urls = box.values; Task { await send(urls, g) } } }
        return true
    }
    private func progressList() -> some View {
        VStack(spacing: 4) {
            ForEach(uploads.sorted { $0.key < $1.key }, id: \.key) { name, f in HStack { Text(name).font(SPDTheme.Typo.caption).lineLimit(1); ProgressView(value: f).controlSize(.small) } }
        }.padding(SPDTheme.Space.sm)
    }
    private func inside(_ g: SharedGrant) -> some View {
        let dropLabel = g.role.canUpload ? "Déposer dans « \(listing.value?.folder.name ?? g.displayName) »" : ""
        let main = VStack(spacing: 0) {
            crumbs(g)
            if let note { Label(note, systemImage: "info.circle").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.warning).padding(SPDTheme.Space.sm).frame(maxWidth: .infinity, alignment: .leading).background(SPDTheme.warning.opacity(0.08)) }
            if !uploads.isEmpty { progressList() }
            body(of: g)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(SPDTheme.canvas)
                .overlay { DropOverlay(active: dropTargeted, label: dropLabel) }
                .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 && g.role.canUpload })) { dropped($0, g) }
        }
        return main
            .toolbar {
                ToolbarItemGroup {
                    if g.role.canUpload { Button { let urls = Pickers.chooseUploads().filter { !$0.hasDirectoryPath }; Task { await send(urls, g) } } label: { Label("Téléverser", systemImage: "arrow.up.doc") }.help("Envoyer des fichiers dans ce dossier (ils comptent dans l’espace de son propriétaire)") }
                    if g.role.canWrite { Button { newName = "Nouveau dossier"; newFolder = true } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }.help("Nouveau dossier") }
                    if g.role.canList { Button { Task { await load() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.help("Les dossiers partagés ne sont pas synchronisés en continu : actualisez pour voir les changements") }
                }
            }
            .alert("Nouveau dossier", isPresented: $newFolder) {
                TextField("Nom", text: $newName)
                Button("Créer") { Task { await act(g) { _ = try await $0.sharedCreateFolder(grant: g.grantId, parentID: folderID, name: newName) } } }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nom", text: Binding(get: { renaming?.name ?? "" }, set: { renaming?.name = $0 }))
                Button("Renommer") { if let r = renaming { Task { await act(g) { _ = try await $0.sharedUpdateItem(grant: g.grantId, itemID: r.id, name: r.name) } } } }
                Button("Annuler", role: .cancel) {}
            }
    }
    private func depositOnly(_ g: SharedGrant) -> some View {
        SPDEmptyState(symbol: "tray.and.arrow.down", title: "Dépôt seulement", message: "\(g.owner.displayName) vous permet d’envoyer des fichiers dans « \(g.displayName) », sans en voir le contenu. Glissez des fichiers ici ou choisissez-les ; ils comptent dans l’espace de \(g.owner.displayName).") {
            Button("Choisir des fichiers…") { let urls = Pickers.chooseUploads().filter { !$0.hasDirectoryPath }; Task { await send(urls, g) } }.buttonStyle(.borderedProminent)
        }
    }
    @ViewBuilder private func browser(_ g: SharedGrant, _ l: SharedListing) -> some View {
        if l.folders.isEmpty && l.files.isEmpty {
            SPDEmptyState(symbol: "folder", title: "Dossier vide", message: g.role.canWrite ? "Glissez des fichiers ici pour les ajouter à ce dossier partagé." : "Ce dossier partagé ne contient rien pour l’instant.")
        } else {
            List(selection: $selection) {
                ForEach(l.folders) { f in
                    Label(f.name, systemImage: "folder.fill").tag(f.id)
                        .contextMenu {
                            Button("Ouvrir", systemImage: "folder") { folderID = f.id; Task { await load() } }
                            if g.role.canWrite { Button("Renommer…", systemImage: "pencil") { renaming = (f.id, f.name) }; Button("Mettre à la corbeille du propriétaire", systemImage: "trash", role: .destructive) { Task { await act(g) { try await $0.sharedTrash(grant: g.grantId, folderIDs: [f.id]) } } } }
                        }
                }
                ForEach(l.files) { f in
                    HStack(spacing: SPDTheme.Space.sm) {
                        SharedThumbnail(model: model, grant: g.grantId, file: f)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Fmt.bytes(f.size)) · \(f.modified.map(Fmt.day) ?? "")").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit()
                    }
                    .tag(f.id)
                    .contextMenu {
                        Button("Coup d’œil", systemImage: "eye") { Task { await preview(f, g) } }
                        Button("Télécharger", systemImage: "arrow.down.circle") { Task { await download(f, g) } }
                        if g.role.canWrite { Divider(); Button("Renommer…", systemImage: "pencil") { renaming = (f.id, f.name) }; Button("Mettre à la corbeille du propriétaire", systemImage: "trash", role: .destructive) { Task { await act(g) { try await $0.sharedTrash(grant: g.grantId, fileIDs: [f.id]) } } } }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                guard let id = ids.first else { return }
                if l.folders.contains(where: { $0.id == id }) { folderID = id; Task { await load() } }
                else if let f = l.files.first(where: { $0.id == id }) { Task { await preview(f, g) } }
            }
        }
    }
    private func load() async {
        guard let g = grant, let next = model.next, g.role.canList else { return }
        do { listing = .ready(try await next.sharedChildren(grant: g.grantId, folderID: folderID)); selection = [] }
        catch { listing = .failed(NextError.wrap(error).isNotFound ? "Ce partage n’existe plus : l’accès a été retiré ou le dossier supprimé." : NextText.error(error)) }
    }
    /// Runs an action of the grant, then re-lists. A 403 means the role changed: say it, do not pretend the folder vanished.
    private func act(_ g: SharedGrant, _ body: (NextClient) async throws -> Void) async {
        guard let next = model.next else { return }
        do { try await body(next); note = nil } catch { note = NextText.error(error); if NextError.wrap(error).isForbidden { await model.refreshGrants(); if let fresh = model.grants.first(where: { $0.grantId == g.grantId }) { grant = fresh } } }
        await load()
    }
    private func localCopy(_ f: NextFile, _ g: SharedGrant) async throws -> URL {
        guard let next = model.next else { throw NextError.unauthenticated }
        let dest = model.cacheDirectory.appendingPathComponent("shared/\(g.grantId)/\(f.id)-\(f.sha256?.prefix(12) ?? "x")/\(NameRules.sanitize(f.name))")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let sha = try await next.downloadShared(grant: g.grantId, fileID: f.id, to: dest)
        if let want = f.sha256, !want.isEmpty, sha != want { try? FileManager.default.removeItem(at: dest); throw NextError.invalidResponse("contenu différent de son empreinte") }
        return dest
    }
    private func preview(_ f: NextFile, _ g: SharedGrant) async {
        do { let url = try await localCopy(f, g); QuickLookCoordinator.shared.onKey = nil; QuickLookCoordinator.shared.show(url: url, itemID: "shared-\(f.id)") } catch { note = NextText.error(error) }
    }
    private func download(_ f: NextFile, _ g: SharedGrant) async {
        do {
            let url = try await localCopy(f, g)
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: model.downloadsFolder.path)) ?? []).map { NameRules.key($0) })
            let dest = model.downloadsFolder.appendingPathComponent(NameRules.nextFree(NameRules.sanitize(f.name)) { taken.contains($0) })
            try FileManager.default.copyItem(at: url, to: dest)
            model.banner = Banner(text: "« \(f.name) » est dans Téléchargements (vérifié par son empreinte).", isError: false)
        } catch { note = NextText.error(error) }
    }
    private func send(_ urls: [URL], _ g: SharedGrant) async {
        guard let next = model.next, !urls.isEmpty else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            uploads[name] = 0
            do { _ = try await next.uploadShared(grant: g.grantId, file: url, folderID: folderID) { done, total in Task { @MainActor in uploads[name] = total > 0 ? Double(done) / Double(total) : 1 } }; note = nil }
            catch { note = "« \(name) » : \(NextText.error(error))" }
            uploads[name] = nil
        }
        if g.role == .uploader, note == nil { model.banner = Banner(text: "\(urls.count) fichier\(urls.count > 1 ? "s" : "") déposé\(urls.count > 1 ? "s" : "") chez \(g.owner.displayName).", isError: false) }
        await load()
    }
}

/// Thumbnail of a shared file, fetched through the grant.
private struct SharedThumbnail: View {
    let model: AppModel
    let grant: String
    let file: NextFile
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 3)) }
            else { Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: file.fileExtension) ?? .data)).resizable() }
        }
        .frame(width: 24, height: 24)
        .task(id: file.id) {
            guard file.thumb, let next = model.next, let req = try? await next.sharedPreviewRequest(grant: grant, fileID: file.id), let (data, _) = try? await next.data(for: req) else { return }
            image = NSImage(data: data)
        }
    }
}
