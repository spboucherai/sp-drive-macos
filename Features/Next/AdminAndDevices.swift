// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Next/AdminAndDevices.swift
// Description      : The devices dashboard (every session of the account with
//                    its platform, app version and last activity, revocable)
//                    and, for administrators only, the infrastructure view of
//                    the server: worker, job queue, conversions, antivirus
//                    signatures, content index, event streams, backups.
//                    Read-only: no control surface.
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

struct DevicesSection: View {
    let model: AppModel
    @State private var sessions: Loadable<[NextSession]> = .loading
    var body: some View {
        Section("Appareils connectés") {
            switch sessions {
            case .loading: Text("Chargement…").foregroundStyle(.secondary)
            case .failed(let m): Text(m).foregroundStyle(.secondary)
            case .ready(let list):
                ForEach(list) { d in
                    HStack(spacing: SPDTheme.Space.md) {
                        Image(systemName: symbol(d)).font(.title3).foregroundStyle(d.current ? SPDTheme.brand : SPDTheme.textSecondary).frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(d.deviceName?.isEmpty == false ? d.deviceName! : (d.kind == "device" ? "Application" : "Navigateur")).lineLimit(1)
                                if d.current { SPDPill(text: "Cet appareil", tint: SPDTheme.brand) }
                            }
                            Text([platform(d), d.client.map { "SP Drive \($0.version)" }, "vu \(Fmt.relative(d.lastSeenAt))", d.ip].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Connecté le \(Fmt.date(d.createdAt)) par \(d.method == "passkey" ? "passkey" : d.method)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if !d.current { Button("Révoquer") { Task { try? await model.next?.revokeSession(d.id); await load() } }.controlSize(.small).help("Ferme cette session immédiatement") }
                    }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("device-row")
                }
            }
        }
        .task { await load() }
    }
    private func symbol(_ d: NextSession) -> String {
        switch d.client?.platform { case "macos": "laptopcomputer"; case "ios": "iphone"; case "ipados": "ipad"; default: d.kind == "device" ? "desktopcomputer" : "globe" }
    }
    private func platform(_ d: NextSession) -> String? {
        guard let c = d.client else { return d.kind == "device" ? "Application (version non déclarée)" : "Navigateur web" }
        let name = ["macos": "macOS", "ios": "iOS", "ipados": "iPadOS"][c.platform] ?? c.platform
        return c.os.map { "\(name) \($0)" } ?? name
    }
    private func load() async {
        guard let next = model.next else { return }
        do { sessions = .ready(try await next.sessions()) } catch { sessions = .failed(NextText.error(error)) }
    }
}

struct AdminView: View {
    @Environment(AppModel.self) private var model
    @State private var system: Loadable<AdminSystem> = .loading
    var body: some View {
        ScrollView {
            switch system {
            case .loading: ProgressView().padding(40)
            case .failed(let m): SPDEmptyState(symbol: "server.rack", title: "Vue indisponible", message: m) { Button("Réessayer") { Task { await load() } } }
            case .ready(let s): content(s).padding(20).frame(maxWidth: 860, alignment: .leading)
            }
        }
        .background(SPDTheme.surface)
        .navigationTitle("Administration").navigationSubtitle("Infrastructure du serveur — lecture seule")
        .toolbar { ToolbarItem { Button { Task { await load() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") } } }
        .task { await load() }
        .accessibilityIdentifier("admin-view")
    }
    @ViewBuilder private func content(_ s: AdminSystem) -> some View {
        let raw = s.raw
        VStack(alignment: .leading, spacing: 18) {
            card("Serveur", "server.rack") {
                line("Version", s.version ?? "—")
                line("Fonctions actives", s.features.joined(separator: ", "))
                if let e = raw["events"]?.object { line("Flux d’événements ouverts", "\(e["streams"]?.int ?? 0) pour \(e["owners"]?.int ?? 0) compte(s)") }
            }
            card("Traitements", "gearshape.2") {
                state("Processus de traitement", s.worker?.alive, yes: "actif\(s.worker?.heartbeatAgeS.map { " · dernier signe de vie il y a \(Fmt.duration($0))" } ?? "")", no: "aucun signe de vie depuis plus de 3 minutes", unknown: "jamais vu")
                if s.jobs.isEmpty { Text("Aucune tâche en file ni terminée depuis 24 h.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) }
                ForEach(s.jobs) { j in
                    HStack { Text(j.kind).font(SPDTheme.Typo.mono); SPDPill(text: j.status, tint: j.status == "failed" ? SPDTheme.critical : j.status == "done" ? SPDTheme.positive : SPDTheme.warning); Spacer(); Text("\(j.count)\(j.oldestAgeS.map { " · la plus ancienne attend depuis \(Fmt.duration($0))" } ?? "")").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit() }
                }
                ForEach(s.previewFailures) { f in Label("Aperçus « \(f.kind) » en échec : \(f.count)\(f.lastError.map { " — \($0)" } ?? "")", systemImage: "exclamationmark.triangle").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.warning).lineLimit(2) }
            }
            card("Outils du nœud", "wrench.and.screwdriver") {
                state("Convertisseur de documents", raw["converter"]?["available"]?.bool, yes: raw["converter"]?["path"]?.string ?? "disponible", no: "absent : pas d’aperçu ni d’indexation des anciens formats Office", unknown: "pas encore rapporté")
                state("Extraction de texte et OCR", raw["textkit"]?["available"]?.bool, yes: raw["textkit"]?["contextual"]?.bool == true ? "disponible, avec le modèle de phrases" : "disponible, sans modèle de phrases", no: "absent", unknown: "pas encore rapporté")
                if let av = raw["antivirusSignatures"]?.object { line("Antivirus", "moteur \(av["engine"]?.string ?? "?") · \(av["signatures"]?.int ?? 0) signatures\(av["ageS"]?.double.map { " · mises à jour il y a \(Fmt.duration($0))" } ?? "")") }
                else { line("Antivirus", "aucune information rapportée") }
            }
            if let index = raw["index"]?.object {
                card("Index du contenu", "text.magnifyingglass") {
                    state("Indexation", index["enabled"]?.bool, yes: index["ocr"]?.bool == true ? "active, avec OCR" : "active, sans OCR", no: "désactivée", unknown: "?")
                    if let by = index["byStatus"]?.object, !by.isEmpty { line("Contenus", by.sorted { $0.key < $1.key }.map { "\($0.key) : \($0.value.int ?? 0)" }.joined(separator: " · ")) }
                    if let sem = index["semantic"]?.object { state("Recherche par le sens", sem["available"]?.bool, yes: "\(sem["model"]?.string ?? "modèle") · \(sem["dim"]?.int ?? 0) dimensions", no: "indisponible", unknown: "?") }
                }
            }
            if let b = raw["backup"]?.object {
                card("Sauvegardes", "externaldrive.badge.timemachine") {
                    line("Dossier", b["dir"]?.string ?? "—")
                    backup("Dernière sauvegarde", b["last"]) { o in "\(Fmt.bytes(Int64(o["dumpBytes"]?.double ?? 0))) de base, \(o["blobs"]?.int ?? 0) objets" }
                    backup("Essai de restauration", b["restoreTest"]) { o in "\(o["files"]?.int ?? 0) fichiers relus" }
                    backup("Vérification", b["verify"]) { o in "\(o["sampled"]?.int ?? 0) objets contrôlés, \(o["mismatched"]?.int ?? 0) différents, \(o["missing"]?.int ?? 0) manquants" }
                    backup("Copie hors du nœud", b["offNode"]) { o in o["host"]?.string ?? "" }
                }
            }
        }
    }
    private func backup(_ title: String, _ v: NextJSON?, detail: ([String: NextJSON]) -> String) -> some View {
        Group {
            if let o = v?.object { state(title, o["ok"]?.bool, yes: "\(detail(o))\(o["ageS"]?.double.map { " · il y a \(Fmt.duration($0))" } ?? "")", no: o["error"]?.string ?? "échec", unknown: "état inconnu") }
            else { state(title, nil, yes: "", no: "", unknown: "jamais exécuté sur ce serveur") }
        }
    }
    private func state(_ title: String, _ ok: Bool?, yes: String, no: String, unknown: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.octagon.fill" : "questionmark.circle").foregroundStyle(ok == true ? SPDTheme.positive : ok == false ? SPDTheme.critical : SPDTheme.textTertiary)
            Text(title).font(SPDTheme.Typo.callout)
            Spacer(minLength: 12)
            Text(ok == true ? yes : ok == false ? no : unknown).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).multilineTextAlignment(.trailing).lineLimit(2)
        }.accessibilityElement(children: .combine)
    }
    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary); Spacer(minLength: 12); Text(value).font(SPDTheme.Typo.callout).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }
    private func card<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: symbol).font(SPDTheme.Typo.headline); content() }.frame(maxWidth: .infinity, alignment: .leading).spdCard()
    }
    private func load() async {
        guard let next = model.next else { return }
        do { system = .ready(try await next.adminSystem()) } catch { system = .failed(NextError.wrap(error).isNotFound ? "Cette vue est réservée aux administrateurs du serveur." : NextText.error(error)) }
    }
}
