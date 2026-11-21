// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Next/NextSupport.swift
// Description      : What the SP Drive 2.0 screens share: turning the server's
//                    2.0 objects into the app's items, French wording of the
//                    2.0 errors and activity events, a row for a file that
//                    comes from a 2.0 answer, highlighted search snippets.
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
import SwiftUI

extension NextFile {
    /// The app's item for this file: the mirror's when it knows the file, otherwise built from the answer.
    @MainActor func item(_ model: AppModel) -> DriveItem {
        if let known = model.item(id) { return known }
        return DriveItem(id: id, kind: .file, name: name, parentID: folderId, size: size, sha256: sha256 ?? "", versionID: versionId, versionSeq: versionSeq ?? 1, versionCount: versions ?? 1,
                         contentAt: contentAt ?? updatedAt ?? Date(), createdAt: createdAt ?? Date(), updatedAt: updatedAt ?? Date(), starred: starred, trashedAt: trashedAt, rev: rev ?? 0,
                         scan: scan ?? "clean", hasThumbnail: thumb, previewKind: kind ?? "none")
    }
}
extension NextFolder {
    @MainActor func item(_ model: AppModel) -> DriveItem {
        model.item(id) ?? DriveItem(id: id, kind: .folder, name: name, parentID: parentId, createdAt: createdAt ?? Date(), updatedAt: updatedAt ?? Date(), starred: starred, trashedAt: trashedAt, rev: rev ?? 0)
    }
}

enum NextText {
    /// A sentence for an error of the 2.0 endpoints.
    static func error(_ error: Error) -> String {
        let e = NextError.wrap(error)
        switch e.code {
        case "offline": return "Serveur injoignable. Réessayez une fois la connexion revenue."
        case "unauthenticated": return "La session est terminée. Reconnectez-vous."
        case "forbidden": return "Votre rôle dans ce dossier partagé ne permet pas cette action."
        case "not_found": return "Introuvable : l’élément a été supprimé, déplacé, ou l’accès a été retiré."
        case "rate_limited": return "Trop de demandes en peu de temps : réessayez dans un instant."
        case "busy": return "Le modèle du serveur est occupé\(e.retryAfterSeconds.map { " : réessayez dans \(Int($0)) s" } ?? " : réessayez dans un instant")."
        case "too_many_streams": return "Le serveur a atteint son nombre maximal de connexions en direct ; la synchronisation continue par vérification périodique."
        case "too_many_pending_uploads": return "Trop d’envois inachevés dans ce dossier partagé : terminez-les ou attendez leur expiration (24 h)."
        case "ai_unavailable": return "Aucun modèle n’est configuré sur ce serveur."
        case "ai_external_disabled": return "Les fournisseurs externes ne sont pas autorisés (réglage du serveur ou de votre compte)."
        case "provider_not_configured": return "Ce fournisseur n’est pas configuré sur le serveur."
        case "provider_unknown", "model_unknown": return "Ce modèle n’est pas proposé par le serveur."
        case "ai_bad_answer": return "Le modèle a répondu dans un format inutilisable."
        case "provider_auth": return "Le serveur n’a pas pu s’authentifier auprès du fournisseur du modèle."
        case "provider_unreachable", "provider_unavailable": return "Le fournisseur du modèle ne répond pas."
        case "provider_rate_limited": return "Le fournisseur du modèle limite les demandes : réessayez plus tard."
        case "provider_refused": return "Le modèle a refusé de répondre à cette question."
        case "already_member": return "Cette personne a déjà accès à ce dossier."
        case "root_immutable": return "Le dossier racine ne peut pas être partagé."
        case "name_conflict": return "Ce nom est déjà pris."
        case "too_many_collections": return "Vous avez atteint le nombre maximal de collections (100)."
        case "invalid_request": return "Demande refusée par le serveur (valeur invalide)."
        case "quota_exceeded": return "Espace insuffisant chez le propriétaire du dossier."
        default: return e.errorDescription ?? e.code
        }
    }
    static func role(_ r: GrantRole) -> String { switch r { case .viewer: "Lecture"; case .editor: "Modification"; case .uploader: "Dépôt seulement" } }
    static func roleDetail(_ r: GrantRole) -> String {
        switch r { case .viewer: "Parcourir, lire, télécharger"; case .editor: "Lire, créer, renommer, déplacer, téléverser, mettre à la corbeille"; case .uploader: "Envoyer des fichiers, sans rien voir du dossier" }
    }
    static func kind(_ k: String) -> String {
        ["image": "Images", "pdf": "PDF", "document": "Documents", "sheet": "Feuilles de calcul", "video": "Vidéos", "audio": "Audio", "archive": "Archives", "text": "Texte", "other": "Autres"][k] ?? k
    }
    static func kindColor(_ k: String) -> Color {
        switch k { case "image": Color(red: 0.36, green: 0.62, blue: 0.95); case "pdf": Color(red: 0.86, green: 0.33, blue: 0.30); case "document": SPDTheme.brandIndigo; case "sheet": Color(red: 0.20, green: 0.62, blue: 0.42)
        case "video": Color(red: 0.80, green: 0.45, blue: 0.85); case "audio": Color(red: 0.93, green: 0.60, blue: 0.22); case "archive": Color(red: 0.55, green: 0.48, blue: 0.40); case "text": SPDTheme.brand; default: SPDTheme.textTertiary }
    }
    /// What happened, in words (API-NEXT §7.2).
    static func activity(_ e: ActivityEvent) -> (symbol: String, text: String) {
        let m = e.meta ?? [:]
        func n(_ key: String) -> Int { m[key]?.int ?? 0 }
        func items() -> String { let f = n("files"), d = n("folders"); return [f > 0 ? "\(f) fichier\(f > 1 ? "s" : "")" : nil, d > 0 ? "\(d) dossier\(d > 1 ? "s" : "")" : nil].compactMap { $0 }.joined(separator: " et ") }
        switch e.action {
        case "file.uploaded": return ("arrow.up.doc", "Fichier ajouté")
        case "file.version_added": return ("doc.badge.plus", "Nouvelle version")
        case "file.version_restored": return ("clock.arrow.circlepath", "Version \(n("from")) restaurée")
        case "file.version_deleted": return ("minus.circle", "Version supprimée")
        case "file.renamed", "folder.renamed": return ("pencil", m["from"]?.string.map { "Renommé (avant : « \($0) »)" } ?? "Renommé")
        case "ai.suggested": return ("sparkles", "Suggestions de rangement demandées")
        case "file.downloaded": return ("arrow.down.circle", "Téléchargé")
        case "folder.created": return ("folder.badge.plus", "Dossier créé")
        case "items.moved": return ("folder", "Déplacement de \(items())")
        case "items.copied": return ("plus.square.on.square", "Copie de \(items())")
        case "items.trashed": return ("trash", "Mise à la corbeille de \(items())")
        case "items.restored": return ("arrow.uturn.backward", "Restauration de \(items())")
        case "items.purged": return ("trash.slash", m["all"]?.bool == true ? "Corbeille vidée" : "Suppression définitive de \(items())")
        case "zip.downloaded": return ("archivebox", "Archive téléchargée (\(n("files")) fichiers)")
        case "share.created": return ("link.badge.plus", "Lien de partage créé")
        case "share.updated": return ("link", "Lien de partage modifié")
        case "share.revoked": return ("link.badge.minus", "Lien de partage révoqué")
        case "share.deleted": return ("link.badge.minus", "Lien de partage retiré")
        case "share.rotated": return ("arrow.triangle.2.circlepath", "Adresse du lien renouvelée")
        case "submission.completed": return ("tray.and.arrow.down", "Dépôt reçu (\(n("placed")) fichier\(n("placed") > 1 ? "s" : ""))")
        case "scan.infected": return ("exclamationmark.shield", "Fichier bloqué par l’antivirus")
        case "collab.member_added": return ("person.badge.plus", "Membre ajouté (\(GrantRole(rawValue: m["role"]?.string ?? "").map(role) ?? "?"))")
        case "collab.member_updated": return ("person.crop.circle.badge.checkmark", "Rôle d’un membre modifié (\(GrantRole(rawValue: m["role"]?.string ?? "").map(role) ?? "?"))")
        case "collab.member_removed": return ("person.badge.minus", "Membre retiré")
        case "collab.workspace_named": return ("character.cursor.ibeam", "Espace de travail nommé")
        default: return ("circle", e.action)
        }
    }
    static func actor(_ e: ActivityEvent) -> String {
        switch e.actor.kind { case "system": "SP Drive"; case "anonymous": "Visiteur anonyme"; default: e.actor.me == true ? "Vous" : (e.actor.displayName ?? "Quelqu’un") }
    }
}

/// A search snippet with its matched words set off (weight and a quiet wash — never colour alone).
struct SnippetText: View {
    let match: SearchMatch
    var body: some View {
        var out = AttributedString()
        for run in match.snippetRuns {
            var piece = AttributedString(run.text)
            if run.matched { piece.font = SPDTheme.Typo.callout.weight(.semibold); piece.foregroundColor = SPDTheme.textPrimary; piece.backgroundColor = SPDTheme.brandWash }
            out.append(piece)
        }
        return Text(out).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).lineLimit(3)
    }
}

/// One file of a 2.0 answer (collection, storage, duplicates, activity…): picture, name, where it is, and a trailing detail.
struct NextFileRow<Trailing: View>: View {
    let model: AppModel
    let file: NextFile
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        let item = file.item(model)
        HStack(spacing: SPDTheme.Space.sm) {
            ItemThumbnail(model: model, item: item, side: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(SPDTheme.Typo.body).lineLimit(1).truncationMode(.middle)
                Text(subtitle ?? location(item)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: SPDTheme.Space.sm)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
    private func location(_ item: DriveItem) -> String {
        let path = model.path(to: item.id).dropLast().map(\.name).joined(separator: " › ")
        return path.isEmpty ? "Mon Drive" : "Mon Drive › " + path
    }
}
extension NextFileRow where Trailing == Text {
    init(model: AppModel, file: NextFile, subtitle: String? = nil) { self.init(model: model, file: file, subtitle: subtitle) { Text(Fmt.bytes(file.size)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit() } }
}
extension AppModel {
    /// Shows a file of a 2.0 answer in the browser: its folder, with the file selected.
    func show(_ file: NextFile, in nav: Navigator) {
        nav.searchText = ""; nav.go(to: file.folderId == rootID ? nil : file.folderId); nav.selection = [file.id]
    }
}

/// Loading, failing or showing: the three states of a screen fed by one request.
enum Loadable<T> { case loading, failed(String), ready(T)
    var value: T? { if case .ready(let v) = self { return v }; return nil }
}
