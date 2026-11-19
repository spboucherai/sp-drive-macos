// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Shared/ShareSheet.swift
// Description: Share links of one file or folder: create (permission, password, expiry, limits, single use), copy, renew the address, revoke, and read the access history. A link's address exists only when it is created or renewed: the server keeps a hash.
import SPDriveCore
import SwiftUI

struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: DriveItem
    @State private var links: [DriveShare] = []
    @State private var loading = true
    @State private var error: String?
    @State private var freshURL: [String: URL] = [:]   // addresses shown once, by link
    @State private var events: [String: [ShareAccessEvent]] = [:]
    // new link
    @State private var label = ""
    @State private var canDownload = true
    @State private var usePassword = false
    @State private var password = ""
    @State private var useExpiry = false
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var limitDownloads = false
    @State private var maxDownloads = 10
    @State private var singleUse = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ItemIcon(item: item, size: 28)
                VStack(alignment: .leading) { Text("Partager « \(item.name) »").font(.headline).lineLimit(1); Text(item.isFolder ? "Lien vers ce dossier et son contenu, rien d’autre." : "Lien vers ce fichier, rien d’autre.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            Form {
                Section("Nouveau lien") {
                    TextField("Libellé (pour vous y retrouver)", text: $label)
                    Picker("Permission", selection: $canDownload) { Text("Consultation et téléchargement").tag(true); Text("Consultation seulement").tag(false) }
                    Toggle("Protéger par un mot de passe", isOn: $usePassword)
                    if usePassword { SecureField("Mot de passe (4 caractères ou plus)", text: $password) }
                    Toggle("Expiration", isOn: $useExpiry)
                    if useExpiry { DatePicker("Expire le", selection: $expiry, in: Date().addingTimeInterval(300)...) }
                    Toggle("Limiter le nombre de téléchargements", isOn: $limitDownloads)
                    if limitDownloads { Stepper("Au plus \(maxDownloads) téléchargement\(maxDownloads > 1 ? "s" : "")", value: $maxDownloads, in: 1...1000) }
                    Toggle("Usage unique (une seule ouverture)", isOn: $singleUse)
                    HStack { Spacer(); Button { Task { await create() } } label: { Label(busy ? "Création…" : "Créer et copier le lien", systemImage: "link.badge.plus") }.buttonStyle(.borderedProminent).disabled(busy || (usePassword && password.count < 4)).accessibilityIdentifier("create-share") }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
                Section("Liens existants") {
                    if loading { ProgressView() }
                    else if links.isEmpty { Text("Aucun lien pour cet élément.").foregroundStyle(.secondary) }
                    ForEach(links) { l in ShareRow(link: l, url: freshURL[l.id], events: events[l.id], copy: { copy(l) }, rotate: { Task { await rotate(l) } }, revoke: { Task { await revoke(l) } }, history: { Task { await history(l) } }) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 640)
        .task { await reload() }
    }
    private func reload() async {
        guard let api = model.api else { return }
        do { links = try await api.shares(of: item); error = nil } catch { self.error = DriveError.wrap(error).errorDescription }
        loading = false
        await model.refreshShares()
    }
    private func create() async {
        guard let api = model.api else { return }
        busy = true; defer { busy = false }
        do {
            let s = ShareSettings(label: label, canDownload: canDownload, password: usePassword ? .some(password) : nil, expiresAt: useExpiry ? .some(expiry) : nil,
                                  maxDownloads: limitDownloads ? .some(maxDownloads) : nil, singleUse: singleUse)
            let made = try await api.createShare(for: item, settings: s)
            freshURL[made.share.id] = made.url
            Pickers.copy(made.url.absoluteString)
            model.banner = Banner(text: "Lien copié dans le presse-papiers.", isError: false)
            label = ""; password = ""; usePassword = false
            await reload()
        } catch { self.error = DriveError.wrap(error).errorDescription }
    }
    private func copy(_ l: DriveShare) { if let u = freshURL[l.id] { Pickers.copy(u.absoluteString); model.banner = Banner(text: "Lien copié.", isError: false) } }
    private func rotate(_ l: DriveShare) async {
        guard let api = model.api else { return }
        do { let u = try await api.rotateShare(l.id); freshURL[l.id] = u; Pickers.copy(u.absoluteString); model.banner = Banner(text: "Nouvelle adresse copiée. L’ancienne ne fonctionne plus.", isError: false) }
        catch { self.error = DriveError.wrap(error).errorDescription }
    }
    private func revoke(_ l: DriveShare) async {
        guard let api = model.api else { return }
        do { try await api.revokeShare(l.id, delete: !l.isActive); freshURL[l.id] = nil; await reload() } catch { self.error = DriveError.wrap(error).errorDescription }
    }
    private func history(_ l: DriveShare) async {
        guard let api = model.api else { return }
        if events[l.id] != nil { events[l.id] = nil; return }
        events[l.id] = (try? await api.shareEvents(l.id)) ?? []
    }
}

struct ShareRow: View {
    let link: DriveShare
    let url: URL?
    let events: [ShareAccessEvent]?
    let copy: () -> Void, rotate: () -> Void, revoke: () -> Void, history: () -> Void
    static func status(_ s: String) -> (String, Color) {
        switch s { case "active": ("Actif", .green); case "revoked": ("Révoqué", .secondary); case "expired": ("Expiré", .orange); case "exhausted": ("Limite atteinte", .orange); default: ("Cible supprimée", .secondary) }
    }
    var body: some View {
        let (text, color) = ShareRow.status(link.status)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(link.label.isEmpty ? "Lien du \(Fmt.date(link.createdAt))" : link.label).fontWeight(.medium).lineLimit(1)
                Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
                Spacer()
                Menu {
                    if link.isActive {
                        Button("Renouveler l’adresse et copier", systemImage: "arrow.triangle.2.circlepath", action: rotate)
                        Button("Révoquer", systemImage: "xmark.circle", role: .destructive, action: revoke)
                    } else { Button("Retirer de la liste", systemImage: "trash", role: .destructive, action: revoke) }
                    Button(events == nil ? "Afficher l’historique d’accès" : "Masquer l’historique", systemImage: "list.bullet.rectangle", action: history)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions du lien")
            }
            Text([link.canDownload ? "Téléchargement permis" : "Consultation seule", link.hasPassword ? "mot de passe" : nil, link.expiresAt.map { "expire le \(Fmt.date($0))" },
                  link.maxDownloads.map { "\(link.downloadCount)/\($0) téléchargements" } ?? "\(link.downloadCount) téléchargement(s)", "\(link.viewCount) ouverture(s)", link.singleUse ? "usage unique" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let url {
                HStack { Text(url.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled); Button("Copier", action: copy).controlSize(.small) }
                HStack(alignment: .top, spacing: 12) {
                    QRCodeView(text: url.absoluteString, side: 110)
                    Text("Code QR de cette adresse, dessiné sur ce Mac. Comme l’adresse, il n’est disponible que maintenant : renouvelez le lien pour en obtenir un autre.").font(.caption).foregroundStyle(.secondary)
                }
            } else if link.isActive {
                Text("L’adresse n’est affichée qu’à la création : renouvelez-la pour en obtenir une nouvelle.").font(.caption).foregroundStyle(.tertiary)
            }
            if let events {
                if events.isEmpty { Text("Aucun accès enregistré.").font(.caption).foregroundStyle(.secondary) }
                ForEach(events.prefix(20)) { e in
                    HStack { Image(systemName: e.ok ? "checkmark.circle" : "xmark.circle").foregroundStyle(e.ok ? .green : .orange); Text("\(Fmt.date(e.at)) · \(e.kind) · \(e.ip)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Partagés par moi": every share link of the account.
struct SharesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var loading = true
    var body: some View {
        Group {
            if model.shares.isEmpty {
                if loading { ProgressView() }
                else { ContentUnavailableView("Aucun lien de partage", systemImage: "link", description: Text("Créez un lien depuis le menu contextuel d’un fichier ou d’un dossier.")) }
            } else {
                List(model.shares) { l in
                    HStack {
                        Image(systemName: l.type == .folder ? "folder" : "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.targetName.isEmpty ? "(élément supprimé)" : l.targetName).fontWeight(.medium)
                            Text([l.label.isEmpty ? nil : l.label, "créé le \(Fmt.date(l.createdAt))", l.expiresAt.map { "expire le \(Fmt.date($0))" }, l.hasPassword ? "mot de passe" : nil, "\(l.viewCount) ouverture(s)"].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let (text, color) = ShareRow.status(l.status)
                        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
                        Button("Gérer") { if let id = l.targetId, let item = model.item(id) { nav.sheet = .share(item) } }.disabled(l.targetId.flatMap { model.item($0) } == nil)
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        if let id = l.targetId, let item = model.item(id) { Button("Afficher l’élément") { nav.open(folder: item.isFolder ? item.id : (item.parentID == model.rootID ? nil : item.parentID)); nav.selection = [item.id] } }
                        if l.isActive { Button("Révoquer", role: .destructive) { Task { try? await model.api?.revokeShare(l.id); await model.refreshShares() } } }
                    }
                }
            }
        }
        .navigationTitle("Partagés par moi")
        .toolbar { ToolbarItem { Button { Task { await model.refreshShares() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") } } }
        .task { await model.refreshShares(); loading = false }
    }
}
