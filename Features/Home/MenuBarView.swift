// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/MenuBarView.swift
// Description: The menu bar item: sync state at a glance, active transfers, storage, pause and resume, and shortcuts to the window, the Finder location and the settings. It only redraws when the state changes.
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
            case .idle: return s.transfers.running > 0 ? "arrow.triangle.2.circlepath" : s.openConflicts > 0 ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark"
            }
        }()
        Image(systemName: symbol).accessibilityLabel("SP Drive : \(model.phase == .signedIn ? SyncStatusText.title(s) : "déconnecté")")
            .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DriveMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppEnvironment.productName).font(.headline)
                    Text(model.account?.email ?? "Non connecté").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            if model.phase == .signedIn {
                Divider()
                HStack(spacing: 6) { SyncStatusIcon(status: model.status); Text(SyncStatusText.title(model.status)).fontWeight(.medium) }
                Text(SyncStatusText.detail(model.status)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                let active = model.transfers.filter { $0.state == .running }.prefix(3)
                ForEach(Array(active)) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Image(systemName: t.direction == .upload ? "arrow.up" : "arrow.down").font(.caption2); Text(t.name).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Text(Fmt.speed(t.speed)).font(.caption2).foregroundStyle(.secondary) }
                        ProgressView(value: t.fraction).controlSize(.small)
                    }
                }
                if model.status.transfers.queued > 0 { Text("\(model.status.transfers.queued) transfert(s) en attente").font(.caption).foregroundStyle(.secondary) }
                if model.status.openConflicts > 0 {
                    Button { show(.conflicts) } label: { Label("\(model.status.openConflicts) conflit(s) à régler", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor) }.buttonStyle(.link)
                }
                if let q = model.quota, q.limit > 0 {
                    ProgressView(value: Double(min(q.used, q.limit)), total: Double(q.limit)).controlSize(.small)
                    Text("\(Fmt.bytes(q.used)) utilisés · \(Fmt.bytes(q.free)) disponibles").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Button { Task { await model.setPaused(!model.settings.syncPaused) } } label: { Label(model.settings.syncPaused ? "Reprendre la synchronisation" : "Mettre en pause", systemImage: model.settings.syncPaused ? "play.fill" : "pause.fill") }
                Button { Task { await model.syncNow() } } label: { Label("Synchroniser maintenant", systemImage: "arrow.clockwise") }.disabled(model.settings.syncPaused)
            }
            Divider()
            Button { show(nil) } label: { Label("Ouvrir SP Drive", systemImage: "macwindow") }
            if model.finderReady { Button { Task { await DriveDomain.shared.openInFinder() } } label: { Label("Ouvrir dans le Finder", systemImage: "folder") } }
            if model.phase == .signedIn { Button { show(.transfers) } label: { Label("Transferts", systemImage: "arrow.up.arrow.down") } }
            Button { NSApp.activate(ignoringOtherApps: true); openSettings() } label: { Label("Paramètres…", systemImage: "gearshape") }
            Divider()
            Button { NSApp.terminate(nil) } label: { Label("Quitter SP Drive", systemImage: "power") }
        }
        .buttonStyle(.plain).labelStyle(.titleAndIcon)
        .padding(14).frame(width: 300)
    }
    private func show(_ section: SidebarItem?) {
        if let section { model.nav.section = section }
        openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
    }
}
