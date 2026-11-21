// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/MyDrive/Inspector.swift
// Description      : The contextual inspector: what the selection is (picture,
//                    name, kind), where it lives, its state on this Mac, its
//                    recent versions, its share links, and the actions that go
//                    with it. It follows the selection without ever taking the
//                    focus or moving the browser.
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

import SPDriveCore
import SPDriveNext
import SPDriveSync
import SwiftUI

struct InspectorView: View {
    let model: AppModel
    let nav: Navigator
    let items: [DriveItem]
    var body: some View {
        Group {
            if let item = items.first, items.count == 1 { SingleInspector(model: model, nav: nav, item: item) }
            else if items.isEmpty { SPDEmptyState(symbol: "info.circle", title: "Aucune sélection", message: "Sélectionnez un élément pour voir ses informations, ses versions et ses partages.", width: 220) }
            else { multiple }
        }
        .background(SPDTheme.surface)
    }
    private var multiple: some View {
        let files = items.filter { !$0.isFolder }
        return VStack(spacing: SPDTheme.Space.md) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, it in ItemThumbnail(model: model, item: it, side: 72).rotationEffect(.degrees(Double(i - 1) * 7)).offset(x: CGFloat(i - 1) * 14) }
            }.frame(height: 96)
            Text("\(items.count) éléments").font(SPDTheme.Typo.title)
            Text("\(files.count) fichier\(files.count > 1 ? "s" : ""), \(items.count - files.count) dossier\(items.count - files.count > 1 ? "s" : "") · \(Fmt.bytes(files.reduce(0) { $0 + $1.size }))").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
            if !items.contains(where: \.isTrashed) {
                HStack {
                    Button("Télécharger", systemImage: "arrow.down.circle") { Task { await model.download(items) } }
                    Button("Déplacer…", systemImage: "folder") { nav.sheet = .move(items) }
                }.controlSize(.small)
            }
        }
        .padding(SPDTheme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SingleInspector: View {
    let model: AppModel
    let nav: Navigator
    let item: DriveItem
    @State private var details: FileDetails?
    @State private var detailsError: String?

    private var links: [DriveShare] { model.shares.filter { $0.targetId == item.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SPDTheme.Space.lg) {
                header
                if !item.isTrashed { actions }
                section("Informations") {
                    if !item.isFolder { line("Taille", Fmt.bytes(item.size)) }
                    line("Emplacement", "Mon Drive" + model.path(to: item.id).dropLast().map { " › " + $0.name }.joined())
                    line("Créé", Fmt.date(item.createdAt))
                    line("Modifié", Fmt.date(item.isFolder ? item.updatedAt : item.contentAt))
                    if let t = item.trashedAt { line("Mis à la corbeille", Fmt.date(t)) }
                }
                section("Sur ce Mac") {
                    HStack { Text("État").foregroundStyle(SPDTheme.textSecondary); Spacer(); SyncStateLabel(model: model, item: item) }.font(SPDTheme.Typo.callout)
                    if !item.isTrashed {
                        Toggle("Garder disponible hors ligne", isOn: Binding(get: { model.isPinnedItself(item.id) }, set: { on in Task { await model.setPinned([item], on) } })).font(SPDTheme.Typo.callout).toggleStyle(.switch).controlSize(.mini)
                        if model.isPinned(item.id), !model.isPinnedItself(item.id) { Text("Inclus dans un dossier gardé hors ligne.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary) }
                    }
                }
                if !item.isTrashed, model.has(.ai), !model.isPending(item.id) {
                    Button { nav.sheet = .ask(item) } label: {
                        Label(item.isFolder ? "Demander à ce dossier…" : "Demander à ce document…", systemImage: "sparkles").frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.buttonStyle(.bordered).tint(SPDTheme.brand).accessibilityIdentifier("inspector-ask")
                }
                if !item.isTrashed { sharing }
                if !item.isFolder { versions; integrity }
                if !item.isTrashed, model.has(.activity), !model.isPending(item.id) { section("Activité") { FileActivitySection(model: model, item: item) } }
            }
            .padding(SPDTheme.Space.lg)
        }
        .task(id: "\(item.id)|\(item.versionID ?? "")|\(model.online)") {
            details = nil; detailsError = nil
            guard !item.isFolder, !model.isPending(item.id), let api = model.api else { return }
            do { details = try await api.fileDetails(item.id) } catch { detailsError = DriveError.wrap(error).isTransient ? "Disponible une fois en ligne." : DriveError.wrap(error).errorDescription }
        }
    }
    private var header: some View {
        VStack(spacing: SPDTheme.Space.sm) {
            ItemThumbnail(model: model, item: item, side: 132)
                .frame(maxWidth: .infinity).padding(.vertical, SPDTheme.Space.sm)
                .background(SPDTheme.sunken, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous))
            Text(item.name).font(SPDTheme.Typo.headline).multilineTextAlignment(.center).textSelection(.enabled).lineLimit(4)
            Text(Fmt.kind(item)).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
            HStack(spacing: SPDTheme.Space.xs) {
                if item.starred { SPDPill(text: "Favori", symbol: "star.fill", tint: SPDTheme.warning) }
                if !links.filter(\.isActive).isEmpty { SPDPill(text: "Partagé", symbol: "link", tint: SPDTheme.brand) }
                if item.scan == "infected" { SPDPill(text: "Bloqué", symbol: "exclamationmark.shield.fill", tint: SPDTheme.critical) }
                if item.isTrashed { SPDPill(text: "Corbeille", symbol: "trash") }
            }
        }
        .frame(maxWidth: .infinity)
    }
    private var actions: some View {
        HStack(spacing: SPDTheme.Space.sm) {
            action("Ouvrir", "arrow.up.forward.app") { if item.isFolder { nav.go(to: item.id) } else { Task { await model.open(item) } } }
            action("Télécharger", "arrow.down.circle") { Task { await model.download([item]) } }
            action("Partager", "link") { nav.sheet = .share(item) }
            action(item.starred ? "Retirer" : "Favori", item.starred ? "star.slash" : "star") { model.setStarred([item], !item.starred) }
        }
    }
    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 3) { Image(systemName: symbol).font(.system(size: 15)); Text(title).font(SPDTheme.Typo.caption).lineLimit(1).minimumScaleFactor(0.75) }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity).padding(.vertical, SPDTheme.Space.sm)
                .background(SPDTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous).strokeBorder(SPDTheme.hairline))
        }
        .buttonStyle(.plain).foregroundStyle(SPDTheme.brand).accessibilityLabel(title)
    }
    @ViewBuilder private var sharing: some View {
        section("Partage") {
            let active = links.filter(\.isActive)
            if active.isEmpty { Text("Aucun lien actif : seul votre compte y a accès.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) }
            ForEach(active.prefix(3)) { l in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: l.hasPassword ? "lock" : "link").foregroundStyle(SPDTheme.brand).font(SPDTheme.Typo.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.label.isEmpty ? "Lien du \(Fmt.day(l.createdAt))" : l.label).font(SPDTheme.Typo.callout).lineLimit(1)
                        Text([l.canDownload ? "téléchargement permis" : "consultation seule", l.expiresAt.map { "expire le \(Fmt.day($0))" }, "\(l.viewCount) ouverture\(l.viewCount > 1 ? "s" : "")"].compactMap { $0 }.joined(separator: " · ")).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
                    }
                }
            }
            Button(active.isEmpty ? "Créer un lien…" : "Gérer les liens…") { nav.sheet = .share(item) }.buttonStyle(.link).font(SPDTheme.Typo.callout)
            if item.isFolder, model.has(.collab) { Button("Membres et rôles…") { nav.sheet = .members(item) }.buttonStyle(.link).font(SPDTheme.Typo.callout) }
            if item.isFolder { Button("Créer un lien de dépôt…") { nav.sheet = .portal(folder: item) }.buttonStyle(.link).font(SPDTheme.Typo.callout) }
        }
    }
    @ViewBuilder private var versions: some View {
        section("Versions") {
            if let d = details {
                ForEach(d.versions.prefix(4)) { v in
                    HStack {
                        Text("v\(v.seq)").font(SPDTheme.Typo.mono).foregroundStyle(v.current ? SPDTheme.brand : SPDTheme.textSecondary).frame(width: 30, alignment: .leading)
                        Text(Fmt.date(v.createdAt)).font(SPDTheme.Typo.callout)
                        Spacer()
                        Text(Fmt.bytes(v.size)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary).monospacedDigit()
                    }
                }
                Button(d.versions.count > 4 ? "Les \(d.versions.count) versions…" : "Historique des versions…") { nav.sheet = .versions(item) }.buttonStyle(.link).font(SPDTheme.Typo.callout)
            } else {
                line("Nombre", "\(item.versionCount)")
                if let detailsError { Text(detailsError).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary) }
            }
        }
    }
    private var integrity: some View {
        section("Intégrité") {
            line("Antivirus", ["clean": "Sain", "pending": "Analyse en attente", "infected": "Bloqué", "error": "Non analysé"][item.scan] ?? item.scan)
            VStack(alignment: .leading, spacing: 2) {
                Text("SHA-256").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                Text(item.sha256.isEmpty ? "—" : item.sha256).font(SPDTheme.Typo.mono).foregroundStyle(SPDTheme.textTertiary).textSelection(.enabled).lineLimit(3)
            }
        }
    }
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
            Text(title).spdEyebrow()
            VStack(alignment: .leading, spacing: SPDTheme.Space.sm) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .spdCard(padding: SPDTheme.Space.md, radius: SPDTheme.Radius.md)
        }
    }
    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(SPDTheme.textSecondary); Spacer(minLength: SPDTheme.Space.md); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .font(SPDTheme.Typo.callout).accessibilityElement(children: .combine)
    }
}
