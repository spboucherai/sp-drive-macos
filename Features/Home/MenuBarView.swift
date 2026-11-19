// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/MenuBarView.swift
// Description: The menu bar Command Center: connection, sync activity, live transfers (progress, speed, time left), errors and conflicts, storage, recent files, pause and resume, quick upload, and the way into the window. It reads the same model as the transfer centre and only redraws when that state changes.
import AppKit
import SPDriveCore
import SPDriveSync
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let s = model.status
        let symbol: String = {
            if model.phase != .signedIn { return "externaldrive.badge.questionmark" }
            switch s.phase {
            case .offline: return "externaldrive.badge.wifi"
            case .paused: return "pause.circle"
            case .needsLogin, .error: return "externaldrive.badge.exclamationmark"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .idle: return s.transfers.running > 0 ? "arrow.triangle.2.circlepath" : (s.openConflicts > 0 || s.transfers.failed > 0) ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark"
            }
        }()
        Image(systemName: symbol).accessibilityLabel("SP Drive : \(model.phase == .signedIn ? SyncStatusText.title(s) : "déconnecté")")
            .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") }; AppDelegate.openAskWindow = { openWindow(id: "ask") } }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.phase == .signedIn {
                divider
                activity
                attention
                storage
                recents
                divider
                actions
            } else {
                divider
                VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
                    Text("Connectez-vous pour synchroniser vos fichiers.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                    Button("Ouvrir SP Drive") { show(nil) }.buttonStyle(.borderedProminent)
                }.padding(SPDTheme.Space.lg)
            }
            divider
            HStack {
                Button { NSApp.activate(ignoringOtherApps: true); openSettings(); dismiss() } label: { Label("Paramètres…", systemImage: "gearshape") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quitter", systemImage: "power") }
            }
            .buttonStyle(.plain).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).padding(.horizontal, SPDTheme.Space.lg).padding(.vertical, SPDTheme.Space.sm)
        }
        .frame(width: 348)
        .task(id: model.revision) { await model.refreshPolicy() }
    }
    private var divider: some View { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }

    private var header: some View {
        HStack(spacing: SPDTheme.Space.md) {
            DriveMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppEnvironment.productName).font(SPDTheme.Typo.headline)
                Text(model.account?.email ?? "Non connecté").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).lineLimit(1)
            }
            Spacer()
            if model.phase == .signedIn { connection }
        }
        .padding(SPDTheme.Space.lg)
    }
    @ViewBuilder private var connection: some View {
        if !model.online || model.status.phase == .offline { SPDPill(text: "Hors ligne", symbol: "icloud.slash", tint: SPDTheme.warning) }
        else if model.status.phase == .needsLogin { SPDPill(text: "Session fermée", symbol: "person.crop.circle.badge.exclamationmark", tint: SPDTheme.critical) }
        else { SPDPill(text: "Connecté", symbol: "checkmark.circle.fill", tint: SPDTheme.positive).help(SyncStatusText.channel(model.status)) }
    }

    private var activity: some View {
        let running = model.transfers.filter { $0.state == .running }
        let s = model.status.transfers
        return VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
            HStack(spacing: 6) {
                SyncStatusIcon(status: model.status)
                Text(SyncStatusText.title(model.status)).font(SPDTheme.Typo.bodyStrong)
                Spacer()
                Text(SyncStatusText.detail(model.status)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary).lineLimit(1)
            }
            if s.running + s.queued > 0 {
                TransferSummary(model: model, compact: true)
                ForEach(running.prefix(4)) { TransferRow(model: model, t: $0, compact: true) }
                let more = s.queued + max(0, running.count - 4)
                if more > 0 { Button("\(more) autre\(more > 1 ? "s" : "") en attente — ouvrir le centre de transferts") { show(.transfers) }.buttonStyle(.link).font(SPDTheme.Typo.caption) }
            } else if model.policy.deferringBackground {
                TransferSummary(model: model, compact: true)
            }
        }
        .padding(SPDTheme.Space.lg)
        .accessibilityElement(children: .contain).accessibilityIdentifier("menubar-activity")
    }
    @ViewBuilder private var attention: some View {
        let failed = model.transfers.filter { $0.state == .failed }
        let open = model.conflicts.filter(\.isOpen)
        if !failed.isEmpty || !open.isEmpty || isError {
            VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
                if isError, let e = model.status.lastError { issue("exclamationmark.icloud", e, SPDTheme.warning, "Réessayer") { Task { await model.syncNow() } } }
                if let f = failed.first {
                    issue("xmark.octagon", failed.count == 1 ? "« \(f.name) » : \(f.error ?? "échec")" : "\(failed.count) transferts en échec — \(f.error ?? "")", SPDTheme.critical, "Réessayer") { Task { await model.retryAllFailed() } }
                }
                if let c = open.first {
                    issue("exclamationmark.triangle", open.count == 1 ? "Conflit sur « \(c.itemName) »" : "\(open.count) conflits à régler", SPDTheme.warning, "Régler…") { model.nav.sheet = .conflict(c); show(nil) }
                }
            }
            .padding(.horizontal, SPDTheme.Space.lg).padding(.bottom, SPDTheme.Space.md)
        }
    }
    private var isError: Bool { if case .error = model.status.phase { return true }; return false }
    private func issue(_ symbol: String, _ text: String, _ tint: Color, _ action: String, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SPDTheme.Space.sm) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(SPDTheme.Typo.callout).lineLimit(2)
            Spacer(minLength: 4)
            Button(action, action: run).controlSize(.small)
        }
        .padding(SPDTheme.Space.sm).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: SPDTheme.Radius.sm, style: .continuous))
    }
    @ViewBuilder private var storage: some View {
        if let q = model.quota, q.limit > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Stockage").spdEyebrow(); Spacer(); Text("\(Fmt.bytes(q.free)) libres sur \(Fmt.bytes(q.limit))").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit() }
                QuotaBar(used: q.used, limit: q.limit)
            }
            .padding(.horizontal, SPDTheme.Space.lg).padding(.bottom, SPDTheme.Space.md)
        }
    }
    @ViewBuilder private var recents: some View {
        let _ = model.revision
        let recent = Array(model.recent().prefix(5))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Récents").spdEyebrow().padding(.horizontal, SPDTheme.Space.lg).padding(.bottom, 2)
                ForEach(recent) { f in
                    Button { reveal(f) } label: {
                        HStack(spacing: SPDTheme.Space.sm) {
                            ItemThumbnail(model: model, item: f, side: 18)
                            Text(f.name).font(SPDTheme.Typo.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.relative(f.contentAt)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
                        }
                        .padding(.horizontal, SPDTheme.Space.lg).padding(.vertical, 3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Afficher « \(f.name) » dans SP Drive")
                }
            }
            .padding(.bottom, SPDTheme.Space.md)
        }
    }
    private var actions: some View {
        HStack(spacing: SPDTheme.Space.sm) {
            tile(model.settings.syncPaused ? "Reprendre" : "Pause", model.settings.syncPaused ? "play.fill" : "pause.fill") { Task { await model.setPaused(!model.settings.syncPaused) } }
            tile("Téléverser", "arrow.up.doc") { quickUpload() }
            tile("Ouvrir", "macwindow") { show(nil) }
            if model.finderReady { tile("Finder", "folder") { Task { await DriveDomain.shared.openInFinder() }; dismiss() } }
        }
        .padding(SPDTheme.Space.md)
    }
    private func tile(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 3) { Image(systemName: symbol).font(.system(size: 14)).frame(height: 16); Text(title).font(SPDTheme.Typo.caption) }
                .frame(maxWidth: .infinity).padding(.vertical, SPDTheme.Space.sm)
                .background(SPDTheme.surface, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous).strokeBorder(SPDTheme.hairline))
        }
        .buttonStyle(.plain).accessibilityLabel(title)
    }

    /// Opens the window (bringing an existing one forward rather than opening another).
    private func show(_ section: SidebarItem?) {
        if let section { model.nav.section = section }
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
    private func reveal(_ f: DriveItem) {
        model.nav.go(to: f.parentID == model.rootID ? nil : f.parentID); model.nav.selection = [f.id]
        show(nil)
    }
    /// Sends files chosen in an open panel to the root of Mon Drive, without opening the window.
    private func quickUpload() {
        guard let root = model.rootID else { return }
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        let urls = Pickers.chooseUploads()
        if !urls.isEmpty { Task { await model.upload(urls, to: root) } }
    }
}
