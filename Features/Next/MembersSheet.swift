// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Next/MembersSheet.swift
// Description      : Private sharing of a folder with other accounts of the
//                    server: members and their roles, the workspace name, and
//                    the folder's activity (members' actions included). An
//                    address is looked up exactly — there is no directory to
//                    browse. Also the QR code of a share link, drawn on this
//                    Mac with Core Image (the address never leaves it).
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

import CoreImage.CIFilterBuiltins
import SPDriveCore
import SPDriveNext
import SwiftUI

struct MembersSheet: View {
    let model: AppModel
    let nav: Navigator
    let folder: DriveItem
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<FolderMembers> = .loading
    @State private var activity: [ActivityEvent] = []
    @State private var email = ""
    @State private var role = GrantRole.viewer
    @State private var workspace = ""
    @State private var busy = false
    @State private var error: String?
    @State private var found: ResolvedUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SPDTheme.Space.md) {
                Image(systemName: "person.2.fill").font(.title2).foregroundStyle(SPDTheme.brand)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Membres de « \(folder.name) »").font(SPDTheme.Typo.title).lineLimit(1)
                    Text("Ces comptes voient ce dossier dans « Partagés avec moi ». Rien d’autre de votre Drive ne leur est visible.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                }
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(SPDTheme.Space.lg)
            Form {
                Section("Inviter") {
                    HStack {
                        TextField("Adresse courriel exacte du compte", text: $email).textContentType(.emailAddress).onSubmit { Task { await add() } }.accessibilityIdentifier("member-email")
                        Picker("Rôle", selection: $role) { ForEach(GrantRole.allCases) { Text(NextText.role($0)).tag($0) } }.labelsHidden().frame(width: 150)
                        Button(busy ? "Ajout…" : "Ajouter") { Task { await add() } }.buttonStyle(.borderedProminent).disabled(busy || !email.contains("@")).accessibilityIdentifier("add-member")
                    }
                    Text(NextText.roleDetail(role) + ".").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SPDTheme.critical).font(SPDTheme.Typo.callout) }
                }
                Section("Membres") {
                    switch state {
                    case .loading: ProgressView().controlSize(.small)
                    case .failed(let m): Text(m).foregroundStyle(SPDTheme.textSecondary)
                    case .ready(let r):
                        if r.members.isEmpty { Text("Personne d’autre que vous.").foregroundStyle(SPDTheme.textSecondary) }
                        ForEach(r.members) { m in
                            HStack {
                                Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(SPDTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 0) { Text(m.displayName).font(SPDTheme.Typo.bodyStrong); Text([m.email, m.createdAt.map { "depuis le \(Fmt.day($0))" }].compactMap { $0 }.joined(separator: " · ")).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary) }
                                Spacer()
                                Picker("Rôle de \(m.displayName)", selection: Binding(get: { m.role }, set: { r in Task { await change(m, r) } })) { ForEach(GrantRole.allCases) { Text(NextText.role($0)).tag($0) } }.labelsHidden().frame(width: 150)
                                Button(role: .destructive) { Task { await remove(m) } } label: { Image(systemName: "person.badge.minus") }.help("Retirer l’accès de \(m.displayName) (immédiat)").accessibilityLabel("Retirer \(m.displayName)")
                            }
                        }
                    }
                }
                Section("Espace de travail") {
                    HStack {
                        TextField("Nom affiché aux membres (facultatif)", text: $workspace)
                        Button("Enregistrer") { Task { await rename() } }.disabled(workspace.trimmingCharacters(in: .whitespaces) == (state.value?.folder.workspaceName ?? ""))
                    }
                    Text("Sans nom, les membres voient le nom du dossier.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                }
                if !activity.isEmpty { Section("Activité du dossier") { ForEach(activity.prefix(8)) { ActivityRow(event: $0, compact: true, showsTarget: true) } } }
            }.formStyle(.grouped)
        }
        .frame(width: 640, height: 620)
        .task { await reload() }
        .accessibilityIdentifier("members-sheet")
    }
    private func reload() async {
        guard let next = model.next else { return }
        do { let r = try await next.members(of: folder.id); state = .ready(r); workspace = r.folder.workspaceName ?? "" } catch { state = .failed(NextText.error(error)) }
        activity = (try? await next.folderActivity(folder.id, limit: 12).events) ?? []
    }
    private func add() async {
        guard let next = model.next else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            _ = try await next.addMember(to: folder.id, email: email.trimmingCharacters(in: .whitespaces), as: role) // by exact address only; unknown and one's own address answer the same
            email = ""; await reload()
        } catch { self.error = NextError.wrap(error).isNotFound ? "Aucun autre compte de ce serveur n’a cette adresse." : NextText.error(error) }
    }
    private func change(_ m: FolderMember, _ r: GrantRole) async { do { _ = try await model.next?.updateMember(of: folder.id, userID: m.userId, role: r); await reload() } catch { self.error = NextText.error(error) } }
    private func remove(_ m: FolderMember) async { do { try await model.next?.removeMember(of: folder.id, userID: m.userId); await reload() } catch { self.error = NextText.error(error) } }
    private func rename() async {
        let n = workspace.trimmingCharacters(in: .whitespaces)
        do { _ = try await model.next?.setWorkspaceName(of: folder.id, n.isEmpty ? nil : n); await reload() } catch { self.error = NextText.error(error) }
    }
}

/// A QR code generated locally with Core Image.
enum QRCode {
    static func image(_ text: String, side: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scale = max(1, floor(side * 2 / out.extent.width))
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }
}
struct QRCodeView: View {
    let text: String
    var side: CGFloat = 150
    var body: some View {
        if let img = QRCode.image(text, side: side) {
            Image(nsImage: img).interpolation(.none).resizable().frame(width: side, height: side).padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.sm).strokeBorder(SPDTheme.hairline))
                .accessibilityLabel("Code QR de l’adresse du lien").contextMenu { Button("Copier l’image") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]) } }
        }
    }
}
