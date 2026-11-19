// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/MainView.swift
// Description: Main window: the sidebar (library, sharing, activity), the section shown next to it, the command palette above, the sheets, and the message banner.
import SPDriveCore
import SPDriveNext
import SPDriveSync
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var nav = nav
        let openConflicts = model.conflicts.filter(\.isOpen).count
        NavigationSplitView {
            List(selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                Section("Bibliothèque") { row(.drive); row(.recent); row(.favorites); row(.offline) }
                // SP Drive 2.0: listed only when the connected server offers them
                if model.isAvailable(.collections) {
                    Section("Collections") {
                        ForEach(model.collections) { c in
                            Button { nav.collectionID = c.id; nav.section = .collections } label: {
                                Label { Text(c.name).lineLimit(1) } icon: { Image(systemName: CollectionLook.symbol(c.icon)).foregroundStyle(CollectionLook.color(c.color)) }.badge(c.count ?? 0)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(nav.section == .collections && (nav.collectionID ?? model.collections.first?.id) == c.id ? RoundedRectangle(cornerRadius: 6).fill(SPDTheme.selection).padding(.horizontal, 10) : nil)
                            .contextMenu { Button("Modifier la règle…") { nav.sheet = .collection(c) } }
                            .accessibilityIdentifier("sidebar-collection")
                        }
                        Button { nav.sheet = .collection(nil) } label: { Label("Nouvelle collection…", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(SPDTheme.textSecondary)
                    }
                }
                Section("Partage") {
                    row(.shared)
                    if model.isAvailable(.sharedWithMe) { row(.sharedWithMe, badge: model.grants.count) }
                    row(.portals)
                }
                Section("Activité") {
                    row(.transfers, badge: model.status.transfers.running + model.status.transfers.queued)
                    if openConflicts > 0 || nav.section == .conflicts { row(.conflicts, badge: openConflicts) } // shown when there is something to settle
                    if model.isAvailable(.activity) { row(.activity) }
                    row(.trash)
                }
                Section("Ce Mac") { row(.storage) }
                if model.isAvailable(.admin) { Section("Serveur") { row(.admin) } }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(model: model, nav: nav) }
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Group {
                        switch nav.section {
                        case .drive, .recent, .favorites, .offline, .trash: BrowserView()
                        case .shared: SharesView()
                        case .portals: PortalsView()
                        case .transfers, .downloads: TransfersView()
                        case .conflicts: ConflictsView()
                        case .storage: StorageView()
                        case .collections: CollectionsView()
                        case .sharedWithMe: SharedWithMeView()
                        case .activity: ActivityView()
                        case .admin: AdminView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    BannerView()
                }
                FinderEnableBanner()
            }
            .spdMotion(.reveal, value: model.banner)
        }
        .overlay(alignment: .top) {
            if nav.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.14).ignoresSafeArea().onTapGesture { nav.showPalette = false }
                    CommandPalette(model: model, nav: nav).padding(.top, 72)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .spdMotion(.reveal, value: nav.showPalette)
        .sheet(item: $nav.sheet) { kind in
            Group {
                switch kind {
                case .newFolder(let parent): NameSheet(title: "Nouveau dossier", initial: "Nouveau dossier", action: "Créer") { if let f = model.createFolder(in: parent, name: $0) { nav.selection = [f.id] } }
                case .rename(let item): NameSheet(title: "Renommer « \(item.name) »", initial: item.name, action: "Renommer", selectStem: !item.isFolder) { model.rename(item, to: $0) }
                case .move(let items): MoveSheet(items: items)
                case .share(let item): ShareSheet(item: item)
                case .portal(let folder): PortalSheet(folder: folder)
                case .versions(let item): if model.meta.api >= 2 { VersionsTimeline(model: model, nav: nav, item: item) } else { VersionsSheet(item: item) }
                case .members(let folder): MembersSheet(model: model, nav: nav, folder: folder)
                case .collection(let c): CollectionEditor(model: model, nav: nav, existing: c)
                case .ask(let item): AskView(model: model, nav: nav, item: item, onOpen: { nav.sheet = nil }, onClose: { nav.sheet = nil }).frame(width: 620, height: 640)
                case .conflict(let c): ConflictSheet(model: model, nav: nav, conflict: c)
                }
            }
            .environment(model).environment(nav)
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
            HStack(spacing: SPDTheme.Space.md) {
                Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(SPDTheme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activez SP Drive dans le Finder").font(SPDTheme.Typo.bodyStrong)
                    Text("macOS demande votre accord : Réglages Système › Général › Ouverture et extensions › Fournisseurs de fichiers, puis activez « \(AppEnvironment.productName) ». D’ici là, vos fichiers restent accessibles dans cette fenêtre.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                }
                Spacer()
                Button("Ouvrir les Réglages Système") { DriveDomain.shared.openSystemSettings() }.buttonStyle(.borderedProminent)
                Button { dismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Masquer")
            }
            .padding(.horizontal, SPDTheme.Space.lg).padding(.vertical, 10).background(SPDTheme.brandWash)
            .overlay(alignment: .top) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
            .task { await model.watchFinderState() }
            .accessibilityIdentifier("finder-enable-banner")
        }
    }
}

/// Bottom of the sidebar: sync state and storage in one glance; a click opens the transfer centre.
struct SidebarFooter: View {
    let model: AppModel
    let nav: Navigator
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            Button { nav.section = .transfers } label: {
                HStack(spacing: 6) {
                    SyncStatusIcon(status: model.status)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(SyncStatusText.title(model.status)).font(SPDTheme.Typo.callout).lineLimit(1)
                        if model.status.transfers.speed > 1024 { Text(Fmt.speed(model.status.transfers.speed) + (model.secondsRemaining.map { " · " + Fmt.duration($0) } ?? "")).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary).monospacedDigit() }
                    }
                    Spacer()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(SyncStatusText.detail(model.status))
            .accessibilityElement(children: .combine).accessibilityIdentifier("sync-status")
            if let q = model.quota, q.limit > 0 {
                Button { nav.section = .storage } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        QuotaBar(used: q.used, limit: q.limit)
                        Text("\(Fmt.bytes(q.free)) libres sur \(Fmt.bytes(q.limit))").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
        .background(.bar) // rows of a long sidebar scroll under it
    }
}

/// A slim storage meter; turns to the warning colour (with a symbol next to it where shown) above 90 %.
struct QuotaBar: View {
    let used: Int64, limit: Int64
    var body: some View {
        let f = limit > 0 ? min(1, Double(used) / Double(limit)) : 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(SPDTheme.hairline)
                Capsule().fill(f > 0.9 ? SPDTheme.warning : SPDTheme.brand).frame(width: max(f > 0 ? 4 : 0, g.size.width * f))
            }
        }
        .frame(height: 4).spdMotion(.progress, value: used)
        .accessibilityElement().accessibilityLabel("Stockage").accessibilityValue("\(Int(f * 100)) % utilisés")
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
            if s.openConflicts > 0 { return "\(s.openConflicts) conflit\(s.openConflicts > 1 ? "s" : "") à régler" }
            return "À jour"
        }
    }
    static func detail(_ s: SyncStatus) -> String {
        if let e = s.lastError, s.phase != .idle { return e }
        if let d = s.lastSync { return "Dernière synchronisation \(Fmt.relative(d))" }
        return "Jamais synchronisé"
    }
    /// How this Mac learns of changes made elsewhere.
    static func channel(_ s: SyncStatus) -> String {
        switch s.events { case .stream: "Changements reçus en direct"; case .polling: "Vérification toutes les 30 s"; case .off: "Écoute arrêtée" }
    }
}
struct SyncStatusIcon: View {
    let status: SyncStatus
    var body: some View {
        let busy = status.phase == .syncing || status.transfers.running > 0
        let (symbol, color): (String, Color) = {
            switch status.phase {
            case .offline: ("icloud.slash", SPDTheme.textSecondary); case .paused: ("pause.circle", SPDTheme.textSecondary); case .needsLogin: ("person.crop.circle.badge.exclamationmark", SPDTheme.warning)
            case .error: ("exclamationmark.icloud", SPDTheme.warning); case .syncing: ("arrow.triangle.2.circlepath", SPDTheme.brand)
            case .idle: status.transfers.running > 0 ? ("arrow.triangle.2.circlepath", SPDTheme.brand) : status.openConflicts > 0 ? ("exclamationmark.triangle", SPDTheme.warning) : ("checkmark.icloud", SPDTheme.positive)
            }
        }()
        Image(systemName: symbol).foregroundStyle(color).symbolEffect(.pulse, isActive: busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).accessibilityHidden(true)
    }
}
