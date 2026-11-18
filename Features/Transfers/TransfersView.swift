// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Transfers/TransfersView.swift
// Description: Uploads and downloads: progress and speed, pause, resume, cancel, retry, and the history of what was done — plus the journal of operations decided on this Mac. Also the conflicts to settle.
import AppKit
import SPDriveCore
import SPDriveSync
import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var model
    /// "Téléchargements": finished and running downloads only.
    let downloadsOnly: Bool
    @State private var journal: [JournalOp] = []

    private var list: [Transfer] { downloadsOnly ? model.transfers.filter { $0.direction == .download } : model.transfers }
    var body: some View {
        let list = self.list
        Group {
            if list.isEmpty && (downloadsOnly || journal.isEmpty) {
                ContentUnavailableView(downloadsOnly ? "Aucun téléchargement" : "Aucun transfert", systemImage: downloadsOnly ? "arrow.down.circle" : "arrow.up.arrow.down",
                                       description: Text(downloadsOnly ? "Les fichiers téléchargés depuis SP Drive arrivent dans votre dossier Téléchargements et sont listés ici." : "Les envois et téléchargements en cours, en attente et terminés apparaissent ici."))
            } else {
                List {
                    if !list.isEmpty {
                        Section(downloadsOnly ? "Téléchargements" : "Transferts") { ForEach(list) { TransferRow(t: $0) } }
                    }
                    if !downloadsOnly, !journal.isEmpty {
                        Section("Journal des opérations de ce Mac") {
                            ForEach(journal) { op in
                                HStack {
                                    Image(systemName: op.state == "done" ? "checkmark.circle" : op.state == "failed" ? "xmark.octagon" : "clock").foregroundStyle(op.state == "done" ? .green : op.state == "failed" ? .red : .orange)
                                    VStack(alignment: .leading) {
                                        Text(op.summary).lineLimit(1)
                                        Text([Fmt.date(op.createdAt), op.state == "pending" ? "en attente d’envoi" : op.state == "failed" ? "refusée" : "confirmée par le serveur", op.error].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(downloadsOnly ? "Téléchargements" : "Transferts")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if downloadsOnly { Button { NSWorkspace.shared.open(model.downloadsFolder) } label: { Label("Ouvrir le dossier Téléchargements", systemImage: "folder") } }
                else {
                    Button { Task { await model.setPaused(!model.settings.syncPaused) } } label: { Label(model.settings.syncPaused ? "Reprendre" : "Tout mettre en pause", systemImage: model.settings.syncPaused ? "play.fill" : "pause.fill") }
                }
                Button { Task { await model.clearFinishedTransfers() } } label: { Label("Effacer les terminés", systemImage: "checkmark.circle.badge.xmark") }.disabled(!list.contains { $0.state == .done || $0.state == .cancelled })
            }
        }
        .task(id: model.revision) { journal = (try? model.engine?.journal.history(limit: 100)) ?? [] }
    }
    private var subtitle: String {
        let s = model.status.transfers
        if s.running + s.queued == 0 { return "" }
        return "\(s.running) en cours, \(s.queued) en attente · \(Fmt.bytes(s.bytesLeft)) restants\(s.speed > 0 ? " · " + Fmt.speed(s.speed) : "")"
    }
}

struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let t: Transfer
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: t.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill").font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name).lineLimit(1).truncationMode(.middle)
                if t.state == .running || t.state == .paused || (t.state == .queued && t.done > 0) { ProgressView(value: t.fraction).controlSize(.small) }
                Text(detail).font(.caption).foregroundStyle(t.state == .failed ? .red : .secondary).lineLimit(2)
            }
            Spacer()
            switch t.state {
            case .running, .queued:
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
        .buttonStyle(.borderless).padding(.vertical, 2)
    }
    private var color: Color { switch t.state { case .done: .green; case .failed: .red; case .cancelled, .paused: .secondary; default: .accentColor } }
    private var detail: String {
        switch t.state {
        case .running: return "\(Fmt.bytes(t.done)) sur \(Fmt.bytes(t.size))\(t.speed > 0 ? " · " + Fmt.speed(t.speed) : "")"
        case .queued: return t.error.map { "Nouvel essai automatique · \($0)" } ?? "En attente"
        case .paused: return "En pause · \(Fmt.bytes(t.done)) sur \(Fmt.bytes(t.size)) conservés"
        case .done: return "\(t.direction == .upload ? "Envoyé et vérifié" : "Téléchargé et vérifié (SHA-256)") · \(Fmt.bytes(t.size))\(t.finishedAt.map { " · " + Fmt.relative($0) } ?? "")"
        case .failed: return t.error ?? "Échec"
        case .cancelled: return "Annulé"
        }
    }
}

/// Files changed on two devices: both versions were kept; the person chooses.
struct ConflictsView: View {
    @Environment(AppModel.self) private var model
    @State private var busy: String?
    var body: some View {
        let open = model.conflicts.filter(\.isOpen), settled = model.conflicts.filter { !$0.isOpen }
        Group {
            if model.conflicts.isEmpty {
                ContentUnavailableView("Aucun conflit", systemImage: "checkmark.seal", description: Text("Quand un fichier est modifié sur deux appareils, SP Drive garde les deux versions et vous demande ici laquelle conserver. Rien n’est jamais écrasé en silence."))
            } else {
                List {
                    if !open.isEmpty {
                        Section("À régler") {
                            ForEach(open) { c in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(c.itemName, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).fontWeight(.medium)
                                    Text("Modifié sur ce Mac et sur un autre appareil le \(Fmt.date(c.detectedAt)). La version de ce Mac est conservée sous « \(c.copyName) » ; la version du serveur garde le nom d’origine.").font(.callout).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Garder les deux") { settle(c, .keepBoth) }
                                        Button("Garder la version de ce Mac") { settle(c, .keepMine) }
                                        Button("Garder la version du serveur") { settle(c, .keepServer) }
                                        if busy == c.id { ProgressView().controlSize(.small) }
                                        Spacer()
                                        Button("Afficher") { if let item = model.item(c.itemID) { model.nav.open(folder: item.parentID == model.rootID ? nil : item.parentID); model.nav.selection = Set([c.itemID, c.copyID].compactMap { $0 }) } }.buttonStyle(.link)
                                    }.disabled(busy != nil)
                                    Text("La version écartée va dans la corbeille de SP Drive : elle reste récupérable.").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    if !settled.isEmpty {
                        Section("Historique") {
                            ForEach(settled) { c in
                                HStack { Image(systemName: "checkmark.circle").foregroundStyle(.green); VStack(alignment: .leading) { Text(c.itemName); Text("\(Fmt.date(c.detectedAt)) · \(["keepBoth": "les deux versions gardées", "keepMine": "version de ce Mac gardée", "keepServer": "version du serveur gardée"][c.resolution ?? ""] ?? "réglé")").font(.caption).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Conflits")
    }
    private func settle(_ c: SyncConflict, _ choice: ConflictChoice) { busy = c.id; Task { await model.resolve(c, choice); busy = nil } }
}
