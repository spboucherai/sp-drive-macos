// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Offline/StorageView.swift
// Description: Storage dashboard: space on MacLustr, what is on this Mac (local copies, pinned, cache), counts, the largest files, and the two distinct actions — free local space (the files stay on SP Drive) versus delete from the Drive.
import SPDriveCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var counts = MetadataStore.Counts(files: 0, folders: 0, bytes: 0, trashed: 0)
    @State private var local = MetadataStore.LocalUsage(files: 0, bytes: 0, pinnedBytes: 0)
    @State private var cache: Int64 = 0
    @State private var largest: [DriveItem] = []
    @State private var confirmFree = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let q = model.quota, q.limit > 0 {
                    card("Sur MacLustr", symbol: "server.rack") {
                        ProgressView(value: Double(min(q.used, q.limit)), total: Double(q.limit)).tint(Double(q.used) / Double(q.limit) > 0.9 ? .orange : .accentColor)
                        HStack { stat("Utilisé", Fmt.bytes(q.used)); stat("Disponible", Fmt.bytes(q.free)); stat("Total", Fmt.bytes(q.limit)) }
                        Text("L’espace utilisé compte chaque contenu une fois, versions et corbeille comprises.").font(.caption).foregroundStyle(.secondary)
                    }
                } else { card("Sur MacLustr", symbol: "server.rack") { Text("Espace indisponible hors ligne.").foregroundStyle(.secondary) } }
                card("Bibliothèque", symbol: "folder") {
                    HStack { stat("Fichiers", "\(counts.files)"); stat("Dossiers", "\(counts.folders)"); stat("Taille", Fmt.bytes(counts.bytes)); stat("Corbeille", "\(counts.trashed)") }
                    HStack { stat("Transferts en attente", "\(model.status.transfers.running + model.status.transfers.queued + model.status.transfers.paused)"); stat("Opérations en attente", "\(model.status.pendingOperations)"); stat("En attente dans le Finder", "\(model.pendingInFinder)") }
                }
                card("Sur ce Mac", symbol: "laptopcomputer") {
                    HStack { stat("Copies locales", "\(local.files)"); stat("Taille locale", Fmt.bytes(local.bytes)); stat("Dont épinglées", Fmt.bytes(local.pinnedBytes)); stat("Cache", Fmt.bytes(cache)) }
                    if !model.finderReady { Label("L’emplacement SP Drive du Finder n’est pas actif : aucune copie locale n’est gérée. Activez-le dans Paramètres › Général.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Button("Libérer l’espace des copies non épinglées…") { confirmFree = true }.disabled(local.bytes - local.pinnedBytes <= 0)
                        Button("Vider le cache d’aperçus") { model.clearCache(); refresh() }.disabled(cache == 0)
                        Button("Gérer les éléments hors ligne") { model.nav.section = .offline }
                    }
                    Text("« Libérer l’espace » retire seulement la copie de ce Mac : les fichiers restent sur SP Drive et se retéléchargent à l’ouverture. Les éléments épinglés et les modifications pas encore envoyées ne sont jamais retirés.").font(.caption).foregroundStyle(.secondary)
                }
                card("Fichiers les plus volumineux", symbol: "chart.bar") {
                    if largest.isEmpty { Text("Aucun fichier.").foregroundStyle(.secondary) }
                    ForEach(largest) { f in
                        HStack {
                            ItemIcon(item: f, size: 18)
                            Text(f.name).lineLimit(1).truncationMode(.middle)
                            ItemBadges(model: model, item: f)
                            Spacer()
                            Text(Fmt.bytes(f.size)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Afficher") { model.nav.open(folder: f.parentID == model.rootID ? nil : f.parentID); model.nav.selection = [f.id] }.controlSize(.small)
                        }
                    }
                }
            }
            .padding(20).frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Stockage")
        .task(id: model.revision) { refresh(); await model.refreshAccount() }
        .confirmationDialog("Libérer l’espace local ?", isPresented: $confirmFree) {
            Button("Libérer \(Fmt.bytes(local.bytes - local.pinnedBytes))") {
                Task { let r = await model.freeUpAllUnpinned(); model.banner = Banner(text: "\(r.freed) copie(s) locale(s) retirée(s)\(r.kept > 0 ? ", \(r.kept) conservée(s)" : ""). Rien n’a été supprimé de SP Drive.", isError: false); refresh() }
            }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Les copies locales non épinglées seront retirées de ce Mac. Les fichiers restent sur SP Drive.") }
    }
    private func refresh() {
        counts = (try? model.store?.counts()) ?? counts
        local = (try? model.store?.localUsage()) ?? local
        largest = (try? model.store?.largestFiles(limit: 12)) ?? []
        cache = model.cacheBytes()
    }
    private func card<C: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: symbol).font(.headline); content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(value).font(.title3.weight(.semibold)).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
