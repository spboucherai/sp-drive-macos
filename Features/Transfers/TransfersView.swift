// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Transfers/TransfersView.swift
// Description      : The transfer centre: what is moving right now (real
//                    progress, speed, time left), what the engine allows and
//                    why (adaptive concurrency, bandwidth cap, power), pause
//                    and resume of everything, priorities, retries, history —
//                    plus the journal of operations decided on this Mac, and
//                    the list of conflicts.
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
import SPDriveSync
import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var journal: [JournalOp] = []
    @State private var showJournal = false

    private func list(_ f: TransferFilter) -> [Transfer] {
        switch f {
        case .all: model.transfers
        case .uploads: model.transfers.filter { $0.direction == .upload }
        case .downloads: model.transfers.filter { $0.direction == .download }
        case .issues: model.transfers.filter { $0.state == .failed || ($0.state == .queued && $0.error != nil) }
        }
    }
    var body: some View {
        @Bindable var nav = nav
        let list = self.list(nav.transferFilter)
        VStack(spacing: 0) {
            TransferSummary(model: model).padding(SPDTheme.Space.lg)
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            if list.isEmpty && journal.isEmpty {
                SPDEmptyState(symbol: "arrow.up.arrow.down", title: nav.transferFilter == .issues ? "Rien à signaler" : "Aucun transfert",
                              message: nav.transferFilter == .downloads ? "Les fichiers téléchargés depuis SP Drive arrivent dans votre dossier Téléchargements et sont listés ici." : "Les envois et téléchargements en cours, en attente et terminés apparaissent ici. Chacun est vérifié par son empreinte SHA-256 avant d’être déclaré terminé.") {
                    if let root = model.rootID { Button("Téléverser…") { let urls = Pickers.chooseUploads(); if !urls.isEmpty { Task { await model.upload(urls, to: root) } } }.buttonStyle(.borderedProminent) }
                    if nav.transferFilter != .all { Button("Voir tous les transferts") { nav.transferFilter = .all } }
                }
            } else {
                List {
                    if list.isEmpty { Text("Aucun transfert dans cette vue.").foregroundStyle(SPDTheme.textSecondary) }
                    ForEach(list) { TransferRow(model: model, t: $0) }
                    if !journal.isEmpty {
                        DisclosureGroup(isExpanded: $showJournal) {
                            ForEach(journal) { op in
                                HStack {
                                    Image(systemName: op.state == "done" ? "checkmark.circle" : op.state == "failed" ? "xmark.octagon" : "clock").foregroundStyle(op.state == "done" ? SPDTheme.positive : op.state == "failed" ? SPDTheme.critical : SPDTheme.warning)
                                    VStack(alignment: .leading) {
                                        Text(op.summary).lineLimit(1)
                                        Text([Fmt.date(op.createdAt), op.state == "pending" ? "en attente d’envoi" : op.state == "failed" ? "refusée" : "confirmée par le serveur", op.error].compactMap { $0 }.joined(separator: " · ")).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).lineLimit(2)
                                    }
                                }
                            }
                        } label: { Text("Journal des opérations de ce Mac (\(journal.count))").font(SPDTheme.Typo.bodyStrong) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Transferts")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filtre", selection: $nav.transferFilter) { ForEach(TransferFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                Button { Task { await model.setPaused(!model.settings.syncPaused) } } label: { Label(model.settings.syncPaused ? "Reprendre" : "Tout mettre en pause", systemImage: model.settings.syncPaused ? "play.fill" : "pause.fill") }
                    .help(model.settings.syncPaused ? "Reprendre la synchronisation" : "Mettre toute la synchronisation en pause")
                Button { Task { await model.retryAllFailed() } } label: { Label("Réessayer les échecs", systemImage: "arrow.clockwise") }.disabled(!model.transfers.contains { $0.state == .failed }).help("Réessayer les transferts en échec")
                Button { Task { await model.clearFinishedTransfers() } } label: { Label("Effacer les terminés", systemImage: "checkmark.circle.badge.xmark") }.disabled(!model.transfers.contains { $0.state == .done || $0.state == .cancelled }).help("Retirer de la liste ce qui est terminé")
                Button { NSWorkspace.shared.open(model.downloadsFolder) } label: { Label("Dossier Téléchargements", systemImage: "folder") }.help("Ouvrir le dossier Téléchargements")
            }
        }
        .task(id: model.revision) { journal = (try? model.engine?.journal.history(limit: 100)) ?? []; await model.refreshPolicy() }
    }
    private var subtitle: String {
        let s = model.status.transfers
        if s.running + s.queued == 0 { return "" }
        return "\(s.running) en cours, \(s.queued) en attente"
    }
}

/// The figures of the moment and the rules the engine is applying. Shared by the transfer centre and the menu bar.
struct TransferSummary: View {
    let model: AppModel
    var compact = false
    var body: some View {
        let s = model.status.transfers, p = model.policy
        VStack(alignment: .leading, spacing: SPDTheme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: SPDTheme.Space.xl) {
                figure(s.running > 0 && s.speed > 1 ? Fmt.speed(s.speed) : "—", "Débit")
                figure(s.bytesLeft > 0 ? Fmt.bytes(s.bytesLeft) : "—", "Restant")
                figure(model.secondsRemaining.map(Fmt.duration) ?? "—", "Temps estimé")
                if !compact { figure("\(s.running) / \(p.concurrency)", "En cours / simultanés") ; figure("\(s.queued)", "En attente") }
                Spacer(minLength: 0)
            }
            if !compact || p.deferringBackground || p.paused {
                FlowRow(spacing: SPDTheme.Space.xs) {
                    if p.paused || model.settings.syncPaused { SPDPill(text: "En pause", symbol: "pause.fill", tint: SPDTheme.warning) }
                    SPDPill(text: p.manual != nil ? "\(p.concurrency) simultanés (fixé)" : "\(p.concurrency) simultanés (adaptatif, 1 à 6)", symbol: "arrow.left.arrow.right")
                    if p.errorRate > 0 { SPDPill(text: "\(Int(p.errorRate * 100)) % d’échecs récents", symbol: "exclamationmark.triangle", tint: SPDTheme.warning) }
                    if p.uploadLimit > 0 { SPDPill(text: "Envoi plafonné à \(Fmt.speed(Double(p.uploadLimit)))", symbol: "gauge.with.dots.needle.33percent") }
                    if p.downloadLimit > 0 { SPDPill(text: "Réception plafonnée à \(Fmt.speed(Double(p.downloadLimit)))", symbol: "gauge.with.dots.needle.33percent") }
                    if model.power.lowPowerMode { SPDPill(text: "Mode économie d’énergie", symbol: "battery.25", tint: SPDTheme.warning) }
                    else if model.power.onBattery, let l = model.power.level { SPDPill(text: "Sur batterie · \(Int(l * 100)) %", symbol: "battery.50", tint: model.power.isLow ? SPDTheme.warning : SPDTheme.textSecondary) }
                    if p.deferringBackground { SPDPill(text: "Arrière-plan en attente", symbol: "moon", tint: SPDTheme.warning) }
                    if !model.online { SPDPill(text: "Hors ligne", symbol: "icloud.slash", tint: SPDTheme.warning) }
                    else { SPDPill(text: SyncStatusText.channel(model.status), symbol: model.status.events == .stream ? "bolt.horizontal" : "clock.arrow.2.circlepath") }
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("transfer-summary")
    }
    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(compact ? SPDTheme.Typo.headline.monospacedDigit() : SPDTheme.Typo.figure).foregroundStyle(SPDTheme.textPrimary).contentTransition(.numericText()).lineLimit(1)
            Text(label).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right and wraps to the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing; line = max(line, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

struct TransferRow: View {
    let model: AppModel
    let t: Transfer
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: t.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill").font(compact ? .body : .title3).foregroundStyle(color).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(t.name).font(compact ? SPDTheme.Typo.callout : SPDTheme.Typo.body).lineLimit(1).truncationMode(.middle)
                    if t.priority >= TransferPriority.urgent, t.isActive { SPDPill(text: "En premier", symbol: "bolt.fill", tint: SPDTheme.brand) }
                }
                if t.state == .running || t.state == .paused || (t.state == .queued && t.done > 0) {
                    ProgressView(value: t.fraction).controlSize(.small).tint(t.state == .running ? SPDTheme.brand : SPDTheme.textTertiary).spdMotion(.progress, value: t.done)
                        .accessibilityLabel("Progression de \(t.name)").accessibilityValue("\(Int(t.fraction * 100)) %")
                }
                Text(detail).font(SPDTheme.Typo.caption).foregroundStyle(t.state == .failed ? SPDTheme.critical : SPDTheme.textSecondary).lineLimit(2).monospacedDigit()
            }
            Spacer(minLength: 4)
            if !compact { controls }
        }
        .buttonStyle(.borderless).padding(.vertical, compact ? 0 : 2)
        .contextMenu {
            if t.isActive, t.priority < TransferPriority.urgent { Button("Envoyer en premier", systemImage: "bolt") { Task { await model.prioritizeTransfer(t.id) } } }
            if t.state == .running || t.state == .queued { Button("Mettre en pause", systemImage: "pause") { Task { await model.pauseTransfer(t.id) } } }
            if t.state == .paused || t.state == .failed { Button(t.state == .failed ? "Réessayer" : "Reprendre", systemImage: "play") { Task { await model.resumeTransfer(t.id) } } }
            if t.state == .done, t.direction == .download { Button("Afficher dans le Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.localPath)]) } }
            if t.state != .done, t.state != .cancelled { Button("Annuler", systemImage: "xmark", role: .destructive) { Task { await model.cancelTransfer(t.id) } } }
            else { Button("Retirer de la liste", systemImage: "xmark") { Task { await model.removeTransfer(t.id) } } }
        }
    }
    @ViewBuilder private var controls: some View {
        switch t.state {
        case .running, .queued:
            if t.state == .queued, t.priority < TransferPriority.urgent { Button { Task { await model.prioritizeTransfer(t.id) } } label: { Image(systemName: "bolt") }.help("Envoyer en premier").accessibilityLabel("Envoyer \(t.name) en premier") }
            Button { Task { await model.pauseTransfer(t.id) } } label: { Image(systemName: "pause.fill") }.help("Mettre en pause").accessibilityLabel("Mettre en pause \(t.name)")
            Button { Task { await model.cancelTransfer(t.id) } } label: { Image(systemName: "xmark") }.help("Annuler").accessibilityLabel("Annuler \(t.name)")
        case .paused:
            Button { Task { await model.resumeTransfer(t.id) } } label: { Image(systemName: "play.fill") }.help("Reprendre").accessibilityLabel("Reprendre \(t.name)")
            Button { Task { await model.cancelTransfer(t.id) } } label: { Image(systemName: "xmark") }.help("Annuler").accessibilityLabel("Annuler \(t.name)")
        case .failed:
            Button { Task { await model.resumeTransfer(t.id) } } label: { Image(systemName: "arrow.clockwise") }.help("Réessayer").accessibilityLabel("Réessayer \(t.name)")
            Button { Task { await model.removeTransfer(t.id) } } label: { Image(systemName: "trash") }.help("Retirer de la liste").accessibilityLabel("Retirer \(t.name)")
        case .done:
            if t.direction == .download { Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.localPath)]) } label: { Image(systemName: "magnifyingglass") }.help("Afficher dans le Finder").accessibilityLabel("Afficher \(t.name) dans le Finder") }
            Button { Task { await model.removeTransfer(t.id) } } label: { Image(systemName: "xmark") }.help("Retirer de la liste").accessibilityLabel("Retirer \(t.name)")
        case .cancelled:
            Button { Task { await model.removeTransfer(t.id) } } label: { Image(systemName: "xmark") }.help("Retirer de la liste").accessibilityLabel("Retirer \(t.name)")
        }
    }
    private var color: Color { switch t.state { case .done: SPDTheme.positive; case .failed: SPDTheme.critical; case .cancelled, .paused: SPDTheme.textSecondary; default: SPDTheme.brand } }
    private var detail: String {
        switch t.state {
        case .running:
            let left = t.speed > 1024 && t.size > t.done ? " · " + Fmt.duration(Double(t.size - t.done) / t.speed) : ""
            return "\(Fmt.bytes(t.done)) sur \(Fmt.bytes(t.size))\(t.speed > 1 ? " · " + Fmt.speed(t.speed) : "")\(left)"
        case .queued:
            if let e = t.error { return "Nouvel essai automatique (tentative \(t.attempts + 1)) · \(e)" }
            if model.policy.deferringBackground, t.priority < TransferPriority.userInitiated { return "En attente : économie d’énergie" }
            return t.done > 0 ? "En attente · \(Fmt.bytes(t.done)) déjà transférés" : "En attente"
        case .paused: return "En pause · \(Fmt.bytes(t.done)) sur \(Fmt.bytes(t.size)) conservés"
        case .done: return "\(t.direction == .upload ? "Envoyé et vérifié" : "Téléchargé et vérifié (SHA-256)") · \(Fmt.bytes(t.size))\(t.finishedAt.map { " · " + Fmt.relative($0) } ?? "")"
        case .failed: return t.error ?? "Échec"
        case .cancelled: return "Annulé"
        }
    }
}

/// Files changed on two devices: both versions were kept; the person chooses, in a sheet that shows both.
struct ConflictsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    var body: some View {
        let open = model.conflicts.filter(\.isOpen), settled = model.conflicts.filter { !$0.isOpen }
        Group {
            if model.conflicts.isEmpty {
                SPDEmptyState(symbol: "checkmark.seal", title: "Aucun conflit", message: "Quand un fichier est modifié sur deux appareils, SP Drive garde les deux versions et vous demande ici laquelle conserver. Rien n’est jamais écrasé en silence.") { Button("Ouvrir Mon Drive") { nav.section = .drive } }
            } else {
                List {
                    if !open.isEmpty {
                        Section("À régler") {
                            ForEach(open) { c in
                                HStack(spacing: SPDTheme.Space.md) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SPDTheme.warning).font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.itemName).font(SPDTheme.Typo.bodyStrong)
                                        Text("Modifié sur ce Mac et sur un autre appareil le \(Fmt.date(c.detectedAt)). Les deux versions sont conservées.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                                    }
                                    Spacer()
                                    Button("Afficher") { if let item = model.item(c.itemID) { nav.go(to: item.parentID == model.rootID ? nil : item.parentID); nav.selection = Set([c.itemID, c.copyID].compactMap { $0 }) } }.buttonStyle(.link)
                                    Button("Comparer et choisir…") { nav.sheet = .conflict(c) }.buttonStyle(.borderedProminent).accessibilityIdentifier("resolve-conflict")
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    if !settled.isEmpty {
                        Section("Historique") {
                            ForEach(settled) { c in
                                HStack { Image(systemName: "checkmark.circle").foregroundStyle(SPDTheme.positive); VStack(alignment: .leading) { Text(c.itemName); Text("\(Fmt.date(c.detectedAt)) · \(["keepBoth": "les deux versions gardées", "keepMine": "version de ce Mac gardée", "keepMineVersion": "version de ce Mac gardée (nouvelle version)", "keepServer": "version du serveur gardée"][c.resolution ?? ""] ?? "réglé")").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary) } }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Conflits")
    }
}
