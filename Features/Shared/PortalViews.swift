// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Shared/PortalViews.swift
// Description      : Deposit links: let someone else send files into one folder
//                    without seeing anything in it. Create (expiry, password,
//                    size limits, allowed types), copy, pause, renew, revoke,
//                    and read what was received.
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

import SPDriveCore
import SwiftUI

struct PortalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: DriveItem
    @State private var title = ""
    @State private var description = ""
    @State private var usePassword = false
    @State private var password = ""
    @State private var useExpiry = true
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var maxFileMB = 200
    @State private var maxTotalGB = 5
    @State private var maxFiles = 20
    @State private var extensions = ""
    @State private var subfolder = true
    @State private var notify = true
    // the remaining fields of a deposit request (parity with the web builder)
    @State private var instructions = ""
    @State private var confirmation = ""
    @State private var brandName = ""
    @State private var limitSubmissions = false
    @State private var maxSubmissions = 50
    @State private var perHour = 20
    @State private var askName = "optional"
    @State private var askEmail = "optional"
    @State private var askReference = "off"
    @State private var requireConsent = false
    @State private var consentText = ""
    @State private var retentionNote = ""
    @State private var busy = false
    @State private var error: String?
    @State private var created: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) { Text("Lien de dépôt vers « \(folder.name.isEmpty ? "Mon Drive" : folder.name) »").font(.headline); Text("Les déposants envoient des fichiers ; ils ne voient ni le dossier ni les dépôts des autres.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(created == nil ? "Annuler" : "Terminé") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let created {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                    Text("Lien de dépôt créé et copié").font(.title3.weight(.semibold))
                    Text(created.absoluteString).font(.callout.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                    Button("Copier de nouveau") { Pickers.copy(created.absoluteString) }
                    Text("Cette adresse n’est affichée qu’une fois. Vous pourrez la renouveler depuis « Liens de dépôt ».").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                Form {
                    Section("Présentation") {
                        TextField("Titre affiché au déposant", text: $title)
                        TextField("Consigne (facultatif)", text: $description, axis: .vertical).lineLimit(2...4)
                        TextField("Instructions détaillées (facultatif)", text: $instructions, axis: .vertical).lineLimit(2...5)
                        TextField("Message affiché après le dépôt (facultatif)", text: $confirmation, axis: .vertical).lineLimit(1...3)
                        TextField("Nom affiché en en-tête (facultatif)", text: $brandName)
                    }
                    Section("Ce que le déposant indique") {
                        Picker("Nom", selection: $askName) { fieldChoices }
                        Picker("Courriel", selection: $askEmail) { fieldChoices }
                        Picker("Référence de dossier", selection: $askReference) { fieldChoices }
                        Toggle("Exiger un consentement", isOn: $requireConsent)
                        if requireConsent { TextField("Texte du consentement", text: $consentText, axis: .vertical).lineLimit(2...4) }
                        TextField("Note sur la conservation des fichiers (facultatif)", text: $retentionNote)
                    }
                    Section("Protection") {
                        Toggle("Mot de passe", isOn: $usePassword)
                        if usePassword { SecureField("Mot de passe (4 caractères ou plus)", text: $password) }
                        Toggle("Expiration", isOn: $useExpiry)
                        if useExpiry { DatePicker("Expire le", selection: $expiry, in: Date().addingTimeInterval(300)...) }
                    }
                    Section("Limites") {
                        Stepper("Taille maximale par fichier : \(maxFileMB) Mo", value: $maxFileMB, in: 1...2048, step: 50)
                        Stepper("Total accepté : \(maxTotalGB) Go", value: $maxTotalGB, in: 1...500)
                        Stepper("Fichiers par dépôt : \(maxFiles)", value: $maxFiles, in: 1...200)
                        Toggle("Limiter le nombre de dépôts", isOn: $limitSubmissions)
                        if limitSubmissions { Stepper("Au plus \(maxSubmissions) dépôts", value: $maxSubmissions, in: 1...10000) }
                        Stepper("Dépôts par heure : \(perHour)", value: $perHour, in: 1...1000)
                        TextField("Types acceptés (ex. pdf, docx — vide = tous sauf exécutables)", text: $extensions)
                    }
                    Section("Réception") {
                        Toggle("Un sous-dossier par dépôt", isOn: $subfolder)
                        Toggle("Me notifier à chaque dépôt", isOn: $notify)
                    }
                    if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
                    HStack { Spacer(); Button { Task { await create() } } label: { Label(busy ? "Création…" : "Créer et copier le lien", systemImage: "tray.and.arrow.down") }.buttonStyle(.borderedProminent)
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || (usePassword && password.count < 4) || (requireConsent && consentText.trimmingCharacters(in: .whitespaces).isEmpty)).accessibilityIdentifier("create-portal") }
                }.formStyle(.grouped)
            }
        }
        .frame(width: 580, height: 700)
        .onAppear { if title.isEmpty { title = "Dépôt de fichiers" + (folder.name.isEmpty ? "" : " — \(folder.name)") } }
    }
    @ViewBuilder private var fieldChoices: some View { Text("Non demandé").tag("off"); Text("Facultatif").tag("optional"); Text("Obligatoire").tag("required") }
    private func create() async {
        guard let api = model.api else { return }
        busy = true; defer { busy = false }
        var s = PortalSettings()
        s.folderId = folder.isRoot ? "root" : folder.id; s.title = title; s.description = description
        s.password = usePassword ? .some(password) : nil; s.expiresAt = useExpiry ? .some(expiry) : nil
        s.maxFileBytes = Int64(maxFileMB) * 1024 * 1024; s.maxTotalBytes = Int64(maxTotalGB) * 1024 * 1024 * 1024; s.maxFilesPerSubmission = maxFiles
        s.allowedExtensions = extensions.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        s.subfolderPerSubmission = subfolder; s.notifyOwner = notify
        do {
            // the engine's settings plus the fields only the 2.0 builder knows, in one request body
            var body = (try JSONSerialization.jsonObject(with: APIClient.encoder.encode(s)) as? [String: Any]) ?? [:]
            body["instructions"] = instructions; body["confirmationMessage"] = confirmation; body["brandName"] = brandName; body["retentionNote"] = retentionNote
            body["submissionsPerHour"] = perHour; body["maxSubmissions"] = limitSubmissions ? maxSubmissions : NSNull()
            body["fields"] = ["name": askName, "email": askEmail, "reference": askReference, "custom": [Any]()] as [String: Any]
            body["requireConsent"] = requireConsent; body["consentText"] = requireConsent ? consentText : ""
            let request = try api.request("POST", "/requests", body: try JSONSerialization.data(withJSONObject: body))
            let made = try APIClient.decoder.decode(APIClient.CreatedPortal.self, from: try await api.data(for: request).0)
            created = made.url; Pickers.copy(made.url.absoluteString); error = nil
        } catch { self.error = DriveError.wrap(error).errorDescription }
    }
}

struct PortalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var portals: [DepositPortal] = []
    @State private var loading = true
    @State private var error: String?
    @State private var submissions: [String: [PortalSubmission]] = [:]
    @State private var fresh: [String: URL] = [:]

    static func state(_ s: String) -> (String, Color) {
        switch s { case "open": ("Ouvert", .green); case "paused": ("En pause", .secondary); case "revoked": ("Révoqué", .secondary); case "expired": ("Expiré", .orange); case "full": ("Plein", .orange); default: ("Dossier supprimé", .secondary) }
    }
    var body: some View {
        Group {
            if portals.isEmpty {
                if loading { ProgressView() }
                else { ContentUnavailableView { Label("Aucun lien de dépôt", systemImage: "tray.and.arrow.down") } description: { Text(error ?? "Créez un lien de dépôt depuis le menu contextuel d’un dossier : d’autres personnes pourront y envoyer des fichiers sans rien voir de son contenu.") } actions: {
                    Button("Créer un lien vers Mon Drive") { if let id = model.rootID, let root = model.item(id) { nav.sheet = .portal(folder: root) } }
                } }
            } else {
                List {
                    ForEach(portals) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).fontWeight(.medium)
                                    Text(["dans « \(p.folderName?.isEmpty == false ? p.folderName! : "Mon Drive") »", "\(p.submissions) dépôt(s)", "\(Fmt.bytes(p.bytesReceived)) reçus sur \(Fmt.bytes(p.maxTotalBytes))", p.expiresAt.map { "expire le \(Fmt.date($0))" }, p.hasPassword ? "mot de passe" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let (text, color) = PortalsView.state(p.state)
                                Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
                                Menu {
                                    Button("Voir le dossier de réception", systemImage: "folder") { nav.open(folder: p.folderId == model.rootID ? nil : p.folderId) }
                                    Button(submissions[p.id] == nil ? "Afficher les dépôts reçus" : "Masquer les dépôts", systemImage: "list.bullet") { Task { await toggleSubmissions(p) } }
                                    if p.revokedAt == nil {
                                        Button(p.active ? "Mettre en pause" : "Rouvrir", systemImage: p.active ? "pause.circle" : "play.circle") { Task { await setActive(p, !p.active) } }
                                        Button("Renouveler l’adresse et copier", systemImage: "arrow.triangle.2.circlepath") { Task { await rotate(p) } }
                                        Button("Révoquer", systemImage: "xmark.circle", role: .destructive) { Task { await revoke(p, delete: false) } }
                                    } else { Button("Retirer de la liste", systemImage: "trash", role: .destructive) { Task { await revoke(p, delete: true) } } }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions du lien de dépôt")
                            }
                            if let u = fresh[p.id] { HStack { Text(u.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled); Button("Copier") { Pickers.copy(u.absoluteString) }.controlSize(.small) } }
                            if let subs = submissions[p.id] {
                                if subs.isEmpty { Text("Aucun dépôt reçu.").font(.caption).foregroundStyle(.secondary) }
                                ForEach(subs) { s in
                                    HStack {
                                        Image(systemName: s.status == "completed" ? "checkmark.circle" : s.status == "rejected" ? "xmark.circle" : "clock").foregroundStyle(s.status == "completed" ? .green : .secondary)
                                        Text("\(Fmt.date(s.createdAt)) · \(s.name.isEmpty ? "Anonyme" : s.name) · \(s.placed) fichier(s) accepté(s)\(s.rejected > 0 ? ", \(s.rejected) refusé(s)" : "") · \(Fmt.bytes(s.bytes))").font(.caption)
                                        Spacer()
                                        if let f = s.folderId { Button("Ouvrir") { nav.open(folder: f == model.rootID ? nil : f) }.controlSize(.small) }
                                    }
                                }
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Liens de dépôt")
        .toolbar { ToolbarItem { Button { Task { await reload() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") } } }
        .task(id: nav.sheet == nil) { await reload() }
    }
    private func reload() async {
        guard let api = model.api else { return }
        do { portals = try await api.portals(); error = nil } catch { self.error = DriveError.wrap(error).errorDescription }
        loading = false
    }
    private func fail(_ e: Error) { model.banner = Banner(text: DriveError.wrap(e).errorDescription ?? "échec", isError: true) }
    private func toggleSubmissions(_ p: DepositPortal) async {
        if submissions[p.id] != nil { submissions[p.id] = nil; return }
        do { submissions[p.id] = try await model.api?.portalSubmissions(p.id) ?? [] } catch { fail(error) }
    }
    private func setActive(_ p: DepositPortal, _ on: Bool) async {
        var s = PortalSettings(); s.active = on
        do { _ = try await model.api?.updatePortal(p.id, s); await reload() } catch { fail(error) }
    }
    private func rotate(_ p: DepositPortal) async {
        do { if let u = try await model.api?.rotatePortal(p.id) { fresh[p.id] = u; Pickers.copy(u.absoluteString); model.banner = Banner(text: "Nouvelle adresse copiée. L’ancienne ne fonctionne plus.", isError: false) } } catch { fail(error) }
    }
    private func revoke(_ p: DepositPortal, delete: Bool) async {
        do { try await model.api?.revokePortal(p.id, delete: delete); fresh[p.id] = nil; await reload() } catch { fail(error) }
    }
}

/// Version history of a file: read, download an old version, restore one (which adds a version: history only grows), delete one.
struct VersionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: DriveItem
    @State private var details: FileDetails?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { ItemIcon(item: item, size: 28); VStack(alignment: .leading) { Text("Versions de « \(item.name) »").font(.headline).lineLimit(1); Text("Restaurer une version en crée une nouvelle : rien n’est remplacé.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Divider()
            if let d = details {
                List(d.versions) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text("Version \(v.seq)").fontWeight(.medium); if v.current { Text("Actuelle").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()) } }
                            Text("\(Fmt.date(v.createdAt)) · \(Fmt.bytes(v.size))\(v.note.isEmpty ? "" : " · \(v.note)")\(sizeDelta(v, in: d.versions))").font(.caption).foregroundStyle(.secondary)
                            Text(v.sha256.prefix(16) + "…").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Télécharger") { Task { await model.download([item], version: v) } }.controlSize(.small)
                        if !v.current {
                            Button("Restaurer") { Task { await restore(v) } }.controlSize(.small).disabled(busy)
                            Button(role: .destructive) { Task { await delete(v) } } label: { Image(systemName: "trash") }.controlSize(.small).disabled(busy).help("Supprimer cette version").accessibilityLabel("Supprimer la version \(v.seq)")
                        }
                    }.padding(.vertical, 2)
                }
            } else if let error { ContentUnavailableView("Historique indisponible", systemImage: "wifi.slash", description: Text(error)) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 560, height: 480)
        .task { await reload() }
    }
    /// Size difference with the version just before, as a comparison of metadata.
    private func sizeDelta(_ v: FileVersion, in all: [FileVersion]) -> String {
        guard let prev = all.first(where: { $0.seq == v.seq - 1 }) else { return "" }
        let d = v.size - prev.size
        return d == 0 ? (v.sha256 == prev.sha256 ? " · identique à la précédente" : " · même taille") : " · \(d > 0 ? "+" : "−")\(Fmt.bytes(abs(d)))"
    }
    private func reload() async {
        do { details = try await model.api?.fileDetails(item.id); error = nil } catch { self.error = DriveError.wrap(error).errorDescription }
    }
    private func restore(_ v: FileVersion) async {
        busy = true; defer { busy = false }
        do { if let updated = try await model.api?.restoreVersion(fileID: item.id, versionID: v.id) { try? model.store?.upsert([updated]) }; await model.syncNow(); await reload() }
        catch { self.error = DriveError.wrap(error).errorDescription }
    }
    private func delete(_ v: FileVersion) async {
        busy = true; defer { busy = false }
        do { try await model.api?.deleteVersion(fileID: item.id, versionID: v.id); await reload() } catch { self.error = DriveError.wrap(error).errorDescription }
    }
}
