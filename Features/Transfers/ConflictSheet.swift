// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Transfers/ConflictSheet.swift
// Description: Settling a version conflict: this Mac's version and the server's side by side (dates, sizes, pictures, Quick Look), and three explicit choices — keep both, keep mine as a new version, keep the server's. Whatever is set aside stays recoverable; nothing is ever overwritten silently.
import SPDriveCore
import SPDriveSync
import SwiftUI

struct ConflictSheet: View {
    let model: AppModel
    let nav: Navigator
    let conflict: SyncConflict
    @Environment(\.dismiss) private var dismiss
    @State private var mine: DriveItem?
    @State private var server: DriveItem?
    @State private var loaded = false
    @State private var busy: AppModel.ConflictDecision?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SPDTheme.Space.xs) {
                Label("Conflit de versions", systemImage: "exclamationmark.triangle.fill").font(SPDTheme.Typo.caption.weight(.semibold)).foregroundStyle(SPDTheme.warning).textCase(.uppercase)
                Text("Deux versions de « \(conflict.itemName) »").font(SPDTheme.Typo.title).lineLimit(2)
                Text("Ce fichier a été modifié sur ce Mac pendant qu’un autre appareil le modifiait aussi. SP Drive a gardé les deux : choisissez laquelle doit porter le nom d’origine.")
                    .font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], SPDTheme.Space.xl).padding(.bottom, SPDTheme.Space.lg)
            HStack(alignment: .top, spacing: SPDTheme.Space.lg) {
                side("Sur ce Mac", "laptopcomputer", mine, other: server, missing: "La copie de ce Mac n’existe plus sur SP Drive.", id: "conflict-mine")
                side("Sur le serveur", "server.rack", server, other: mine, missing: "Le fichier d’origine n’existe plus sur SP Drive.", id: "conflict-server")
            }
            .padding(.horizontal, SPDTheme.Space.xl)
            if let mine, let server, mine.sha256 == server.sha256, !mine.sha256.isEmpty {
                Label("Les deux versions ont exactement le même contenu (même empreinte SHA-256).", systemImage: "equal.circle").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).padding(.horizontal, SPDTheme.Space.xl).padding(.top, SPDTheme.Space.md)
            }
            if let note { Label(note, systemImage: "exclamationmark.circle").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.critical).padding(.horizontal, SPDTheme.Space.xl).padding(.top, SPDTheme.Space.md) }
            Spacer(minLength: SPDTheme.Space.lg)
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            HStack(alignment: .top, spacing: SPDTheme.Space.md) {
                choice(.keepBoth, "Garder les deux", "Les deux fichiers restent côte à côte dans le dossier.", prominent: false, enabled: true)
                choice(.mineAsVersion, "Garder la mienne", "Elle devient la nouvelle version du fichier ; celle du serveur reste dans l’historique des versions.", prominent: true, enabled: mine != nil)
                choice(.server, "Garder celle du serveur", "La copie de ce Mac va à la corbeille de SP Drive, d’où elle reste récupérable.", prominent: false, enabled: server != nil)
            }
            .padding(SPDTheme.Space.lg)
            .disabled(busy != nil || !loaded)
            HStack {
                Text("Rien n’est jamais remplacé en silence : si le fichier change encore pendant votre choix, SP Drive s’arrête et vous le dit.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
                Spacer()
                Button("Plus tard") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, SPDTheme.Space.lg).padding(.bottom, SPDTheme.Space.lg)
        }
        .frame(width: 720, height: 640)
        .background(SPDTheme.surface)
        .task { await load() }
        .accessibilityIdentifier("conflict-sheet")
    }

    private func side(_ title: String, _ symbol: String, _ item: DriveItem?, other: DriveItem?, missing: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: SPDTheme.Space.md) {
            HStack {
                Label(title, systemImage: symbol).spdEyebrow()
                Spacer()
                if let item, let other, item.contentAt > other.contentAt { SPDPill(text: "Plus récente", symbol: "clock", tint: SPDTheme.brand) }
            }
            if let item {
                ConflictPreview(model: model, item: item)
                Text(item.name).font(SPDTheme.Typo.bodyStrong).lineLimit(2).truncationMode(.middle)
                VStack(alignment: .leading, spacing: 4) {
                    fact("Modifié", Fmt.date(item.contentAt))
                    fact("Taille", Fmt.bytes(item.size) + (other.map { o in o.size == item.size ? "" : " (\(item.size > o.size ? "+" : "−")\(Fmt.bytes(abs(item.size - o.size))))" } ?? ""))
                    fact("Version", "v\(item.versionSeq)")
                    fact("Empreinte", String(item.sha256.prefix(12)) + "…")
                }
                Button("Coup d’œil", systemImage: "eye") { Task { if let url = try? await model.localCopy(of: item, inContainer: true) { QuickLookCoordinator.shared.onKey = nil; QuickLookCoordinator.shared.show(url: url, itemID: "conflict-\(item.id)") } } }.controlSize(.small)
            } else if loaded {
                Label(missing, systemImage: "questionmark.folder").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 200) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .spdCard()
        .accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(SPDTheme.textSecondary).frame(width: 70, alignment: .leading); Text(value).monospacedDigit().textSelection(.enabled) }.font(SPDTheme.Typo.callout)
    }
    private func choice(_ d: AppModel.ConflictDecision, _ title: String, _ caption: String, prominent: Bool, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: SPDTheme.Space.xs) {
            Group {
                if prominent { Button { settle(d) } label: { label(d, title) }.buttonStyle(.borderedProminent) }
                else { Button { settle(d) } label: { label(d, title) }.buttonStyle(.bordered) }
            }
            .controlSize(.large).disabled(!enabled)
            Text(caption).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func label(_ d: AppModel.ConflictDecision, _ title: String) -> some View {
        HStack { if busy == d { ProgressView().controlSize(.small) }; Text(title) }.frame(maxWidth: .infinity)
    }
    private func settle(_ d: AppModel.ConflictDecision) {
        busy = d; note = nil
        Task {
            let ok = await model.resolve(conflict, d)
            busy = nil
            if ok { dismiss() } else { note = "Le choix n’a pas pu être appliqué. Les deux versions sont toujours là."; await load() }
        }
    }
    /// Both sides as the server describes them now (the mirror when it cannot be reached).
    private func load() async {
        func fetch(_ id: String?) async -> DriveItem? {
            guard let id else { return nil }
            if let api = model.api, let fresh = try? await api.item(id, kind: .file) { return fresh.isTrashed ? nil : fresh }
            return model.item(id).flatMap { $0.isTrashed ? nil : $0 }
        }
        mine = await fetch(conflict.copyID); server = await fetch(conflict.itemID); loaded = true
    }
}

/// A picture of one side: the server's thumbnail, or a Quick Look thumbnail of a verified copy fetched for the comparison (files up to 30 MB).
private struct ConflictPreview: View {
    let model: AppModel
    let item: DriveItem
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous).fill(SPDTheme.sunken)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: SPDTheme.Radius.sm, style: .continuous)).padding(SPDTheme.Space.sm).spdElevation(.e1) }
            else { ItemIcon(item: item, size: 72) }
        }
        .frame(height: 140).frame(maxWidth: .infinity)
        .task(id: ThumbnailStore.key(item)) {
            if let img = await model.thumbnails.image(for: item) { image = img; return }
            guard item.size <= 30 * 1024 * 1024, let url = try? await model.localCopy(of: item, inContainer: true) else { return }
            image = await model.thumbnails.local(item, url: url, side: 320)
        }
        .accessibilityHidden(true)
    }
}
