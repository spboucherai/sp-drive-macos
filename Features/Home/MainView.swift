// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/MainView.swift
// Description: Main window: sidebar, the section shown next to it, the sheets, and the message banner.
import SPDriveCore
import SPDriveSync
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var nav = model.nav
        NavigationSplitView {
            List(selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                Section("SP Drive") {
                    row(.drive); row(.recent); row(.favorites); row(.offline)
                }
                Section("Partage") { row(.shared); row(.portals) }
                Section("Activité") {
                    row(.transfers, badge: model.status.transfers.running + model.status.transfers.queued)
                    row(.downloads)
                    row(.conflicts, badge: model.conflicts.filter(\.isOpen).count)
                    row(.trash)
                }
                Section("Ce Mac") {
                    row(.storage)
                    Button { openSettings() } label: { Label("Paramètres", systemImage: "gearshape") }.buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    switch nav.section {
                    case .drive, .recent, .favorites, .offline, .trash: BrowserView()
                    case .shared: SharesView()
                    case .portals: PortalsView()
                    case .transfers: TransfersView(downloadsOnly: false)
                    case .downloads: TransfersView(downloadsOnly: true)
                    case .conflicts: ConflictsView()
                    case .storage: StorageView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                BannerView()
            }
            FinderEnableBanner()
            }
            .animation(.default, value: model.banner)
        }
        .sheet(item: $nav.sheet) { kind in
            Group {
            switch kind {
            case .newFolder(let parent): NameSheet(title: "Nouveau dossier", initial: "Nouveau dossier", action: "Créer") { model.createFolder(in: parent, name: $0) }
            case .rename(let item): NameSheet(title: "Renommer « \(item.name) »", initial: item.name, action: "Renommer", selectStem: !item.isFolder) { model.rename(item, to: $0) }
            case .move(let items): MoveSheet(items: items)
            case .share(let item): ShareSheet(item: item)
            case .portal(let folder): PortalSheet(folder: folder)
            case .versions(let item): VersionsSheet(item: item)
            }
            }
            .environment(model)
        }
        .confirmationDialog("Supprimer définitivement \(nav.confirmPurge.count) élément(s) ?", isPresented: Binding(get: { !nav.confirmPurge.isEmpty }, set: { if !$0 { nav.confirmPurge = [] } })) {
            Button("Supprimer définitivement", role: .destructive) { let items = nav.confirmPurge; nav.confirmPurge = []; Task { await model.purge(items) } }
            Button("Annuler", role: .cancel) { nav.confirmPurge = [] }
        } message: { Text("Cette action est irréversible : les fichiers et toutes leurs versions seront effacés de SP Drive.") }
        .confirmationDialog("Vider la corbeille ?", isPresented: $nav.confirmEmptyTrash) {
            Button("Vider la corbeille", role: .destructive) { Task { await model.emptyTrash() } }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Tout le contenu de la corbeille sera effacé définitivement de SP Drive.") }
    }
    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.title, systemImage: item.symbol).badge(badge).tag(item).accessibilityIdentifier("sidebar-\(item.rawValue)")
    }
}

/// Shown while macOS keeps the Finder location off: only the person can turn it on, in System Settings.
struct FinderEnableBanner: View {
    @Environment(AppModel.self) private var model
    @AppStorage("finderBannerDismissed") private var dismissed = false
    var body: some View {
        if model.finderRegistered, !model.finderEnabled, !dismissed {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activez SP Drive dans le Finder").fontWeight(.semibold)
                    Text("macOS demande votre accord : Réglages Système › Général › Ouverture et extensions › Fournisseurs de fichiers, puis activez « \(AppEnvironment.productName) ». D’ici là, vos fichiers restent accessibles dans cette fenêtre.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Ouvrir les Réglages Système") { DriveDomain.shared.openSystemSettings() }.buttonStyle(.borderedProminent)
                Button { dismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Masquer")
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(Color.accentColor.opacity(0.10))
            .overlay(alignment: .top) { Divider() }
            .task { await model.watchFinderState() }
            .accessibilityIdentifier("finder-enable-banner")
        }
    }
}

/// Bottom of the sidebar: sync state and storage in one glance.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                SyncStatusIcon(status: model.status)
                Text(SyncStatusText.title(model.status)).font(.callout).lineLimit(1)
                Spacer()
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("sync-status")
            if let q = model.quota, q.limit > 0 {
                ProgressView(value: Double(q.used), total: Double(q.limit)).controlSize(.small).tint(Double(q.used) / Double(q.limit) > 0.9 ? .orange : .accentColor)
                Text("\(Fmt.bytes(q.used)) sur \(Fmt.bytes(q.limit))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }
}

enum SyncStatusText {
    static func title(_ s: SyncStatus) -> String {
        switch s.phase {
        case .offline: return s.pendingOperations > 0 ? "Hors ligne · \(s.pendingOperations) en attente" : "Hors ligne"
        case .paused: return "Synchronisation en pause"
        case .needsLogin: return "Reconnexion requise"
        case .error: return "Erreur de synchronisation"
        case .syncing: return "Synchronisation…"
        case .idle:
            let active = s.transfers.running + s.transfers.queued
            if active > 0 { return "\(active) transfert\(active > 1 ? "s" : "") en cours" }
            if s.pendingOperations > 0 { return "\(s.pendingOperations) opération(s) en attente" }
            return "À jour"
        }
    }
    static func detail(_ s: SyncStatus) -> String {
        if let e = s.lastError, s.phase != .idle { return e }
        if let d = s.lastSync { return "Dernière synchronisation \(Fmt.relative(d))" }
        return "Jamais synchronisé"
    }
}
struct SyncStatusIcon: View {
    let status: SyncStatus
    var body: some View {
        let busy = status.phase == .syncing || status.transfers.running > 0
        let (symbol, color): (String, Color) = {
            switch status.phase {
            case .offline: ("icloud.slash", .secondary); case .paused: ("pause.circle", .secondary); case .needsLogin: ("person.crop.circle.badge.exclamationmark", .orange)
            case .error: ("exclamationmark.icloud", .orange); case .syncing: ("arrow.triangle.2.circlepath", .accentColor)
            case .idle: status.transfers.running > 0 ? ("arrow.triangle.2.circlepath", .accentColor) : status.openConflicts > 0 ? ("exclamationmark.triangle", .orange) : ("checkmark.icloud", .green)
            }
        }()
        Image(systemName: symbol).foregroundStyle(color).symbolEffect(.pulse, isActive: busy).accessibilityHidden(true)
    }
}
