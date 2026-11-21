// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Settings/SettingsView.swift
// Description      : Settings window: general (Finder location, start at login,
//                    menu bar), synchronisation (pause, bandwidth, parallel
//                    transfers), notifications, account and security (devices,
//                    biometric lock, sign out).
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

import ServiceManagement
import SPDriveCore
import SPDriveNext
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("Général", systemImage: "gearshape") }.tag("general")
            SyncSettings().tabItem { Label("Synchronisation", systemImage: "arrow.triangle.2.circlepath") }.tag("sync")
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }.tag("notifications")
            AccountSettings().tabItem { Label("Compte", systemImage: "person.crop.circle") }.tag("account")
        }
        .frame(width: 600, height: 580)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Finder") {
                Toggle("Afficher SP Drive dans le Finder", isOn: Binding(get: { s.finderIntegration }, set: { s.finderIntegration = $0; Task { await model.applyFinderIntegration() } }))
                if model.finderRegistered, !model.finderEnabled {
                    Label("L’emplacement attend votre accord dans Réglages Système › Général › Ouverture et extensions › Fournisseurs de fichiers.", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    Button("Ouvrir les Réglages Système") { DriveDomain.shared.openSystemSettings() }
                }
                Text(model.finderReady ? "SP Drive est un emplacement du Finder : ouvrez, modifiez et enregistrez vos fichiers depuis vos applications, les changements sont synchronisés." : "Sans l’emplacement du Finder, les fichiers se consultent et se téléchargent depuis l’application ; la disponibilité hors ligne n’est pas gérée.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.finderReady { Button("Ouvrir SP Drive dans le Finder") { Task { await DriveDomain.shared.openInFinder() } } }
            }
            Section("Démarrage") {
                Toggle("Ouvrir SP Drive à l’ouverture de session", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil } catch { loginError = error.localizedDescription }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Toggle("Afficher l’icône dans la barre de menus", isOn: $s.showMenuBarIcon)
                Text("Avec l’icône de la barre de menus, SP Drive continue de synchroniser quand sa fenêtre est fermée.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bureau et recherche") {
                Toggle("Zone de dépôt flottante sur le bureau", isOn: Binding(get: { s.dropZone }, set: { s.dropZone = $0; DropZoneController.shared.update(model: model) }))
                if s.dropZone {
                    Picker("Destination", selection: Binding(get: { s.dropZoneFolderID ?? "" }, set: { s.dropZoneFolderID = $0.isEmpty ? nil : $0 })) {
                        Text("Mon Drive").tag("")
                        ForEach((model.rootID.map { model.children(of: $0) } ?? []).filter(\.isFolder)) { f in Text(f.name).tag(f.id) }
                    }
                }
                Text("Une petite tuile reste au-dessus des fenêtres : glissez-y des fichiers depuis n’importe quelle application. Elle se déplace à la souris et ne prend jamais le focus.").font(.caption).foregroundStyle(.secondary)
                Toggle("Retrouver mes éléments dans Spotlight (noms seulement)", isOn: Binding(get: { s.spotlightIndex }, set: { on in
                    s.spotlightIndex = on
                    Task { if on { await SpotlightIndexer.shared.sync(model: model) } else { await SpotlightIndexer.shared.removeAll() } }
                }))
                Text("Seuls le nom, le type, les dates et l’emplacement sont indexés sur ce Mac — jamais le contenu des fichiers. L’index est effacé si vous décochez cette case ou vous déconnectez. Inutile si l’emplacement du Finder est actif : macOS indexe déjà ses fichiers.").font(.caption).foregroundStyle(.secondary)
            }
            Section("À propos") {
                LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                LabeledContent("Serveur", value: AppEnvironment.serverURL.host ?? "")
                Text("Les fichiers sont chiffrés en transit (TLS) et au repos sur le serveur. Ce n’est pas un chiffrement de bout en bout : le serveur MacLustr détient les clés.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("État") {
                LabeledContent("Synchronisation") { HStack { SyncStatusIcon(status: model.status); Text(SyncStatusText.title(model.status)) } }
                LabeledContent("Détail", value: SyncStatusText.detail(model.status))
                Toggle("Mettre la synchronisation en pause", isOn: Binding(get: { s.syncPaused }, set: { on in Task { await model.setPaused(on) } }))
                Button("Synchroniser maintenant") { Task { await model.syncNow() } }.disabled(s.syncPaused)
            }
            Section("Bande passante") {
                Picker("Envoi", selection: Binding(get: { s.uploadLimitKB }, set: { s.uploadLimitKB = $0; Task { await model.applyTransferSettings() } })) { limits }
                Picker("Réception", selection: Binding(get: { s.downloadLimitKB }, set: { s.downloadLimitKB = $0; Task { await model.applyTransferSettings() } })) { limits }
            }
            Section("Énergie") {
                Toggle("Ménager la batterie", isOn: Binding(get: { s.respectPower }, set: { s.respectPower = $0; Task { await model.applyTransferSettings() } }))
                Text("En mode Économie d’énergie, ou sous 10 % de batterie, seuls les transferts que vous demandez passent, un à la fois ; le reste attend. Sous 20 %, deux transferts au plus.").font(.caption).foregroundStyle(.secondary)
                if model.power.lowPowerMode || model.power.onBattery {
                    LabeledContent("Maintenant", value: model.power.lowPowerMode ? "Mode Économie d’énergie" : "Sur batterie\(model.power.level.map { " · \(Int($0 * 100)) %" } ?? "")")
                }
            }
            Section("Transferts simultanés") {
                Picker("Nombre", selection: Binding(get: { s.parallelTransfers }, set: { s.parallelTransfers = $0; Task { await model.applyTransferSettings() } })) {
                    Text("Automatique (selon le débit mesuré)").tag(0)
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Text("En automatique, SP Drive ajoute des transferts (jusqu’à 6) tant que le débit total augmente, en retire quand les échecs se répètent, et se limite sur un partage de connexion ou en mode Données réduites.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("En ce moment", value: "\(model.policy.concurrency) simultané\(model.policy.concurrency > 1 ? "s" : "") · \(SyncStatusText.channel(model.status).lowercased())")
            }
        }.formStyle(.grouped)
    }
    @ViewBuilder private var limits: some View {
        Text("Sans limite").tag(0)
        ForEach([256, 512, 1024, 2048, 5120, 10240, 51200], id: \.self) { kb in Text(kb < 1024 ? "\(kb) Ko/s" : "\(kb / 1024) Mo/s").tag(kb) }
    }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Toggle("Transferts terminés (une notification par lot)", isOn: $s.notifyTransfers)
                Toggle("Conflits à régler", isOn: $s.notifyConflicts)
                Toggle("Nouveaux dépôts reçus", isOn: $s.notifyDeposits)
            } footer: { Text("Les erreurs de synchronisation persistantes et le manque d’espace sont toujours signalés. Le style et le son se règlent dans Réglages Système › Notifications.") }
        }.formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [DeviceSession] = []
    @State private var confirmSignOut = false
    @State private var error: String?
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Compte") {
                LabeledContent("Nom", value: model.account?.displayName ?? "—")
                LabeledContent("Courriel", value: model.account?.email ?? "—")
                LabeledContent("Ce Mac", value: AppEnvironment.deviceName)
            }
            Section("Sécurité") {
                Toggle("Verrouiller l’application avec Touch ID", isOn: $s.biometricLock)
                Text("Le jeton de session de ce Mac est gardé dans le trousseau. Le verrou demande Touch ID (ou le mot de passe du Mac) à l’ouverture et après une absence.").font(.caption).foregroundStyle(.secondary)
            }
            if model.meta.api >= 2 { AIConsentSection(model: model); DevicesSection(model: model) } else {
            Section("Appareils connectés") {
                if sessions.isEmpty { Text(error ?? "Chargement…").foregroundStyle(.secondary) }
                ForEach(sessions) { d in
                    HStack {
                        Image(systemName: d.kind == "device" ? "laptopcomputer" : "globe").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text((d.deviceName?.isEmpty == false ? d.deviceName! : (d.kind == "device" ? "Application" : "Navigateur")) + (d.current ? " — cet appareil" : "")).lineLimit(1)
                            Text("\(d.ip) · vu \(Fmt.relative(d.lastSeenAt))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !d.current { Button("Révoquer") { Task { try? await model.api?.revokeSession(d.id); await load() } }.controlSize(.small) }
                    }
                }
            } }
            Section {
                Button("Se déconnecter de ce Mac…", role: .destructive) { confirmSignOut = true }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .confirmationDialog("Se déconnecter de SP Drive ?", isPresented: $confirmSignOut) {
            Button("Se déconnecter", role: .destructive) { Task { await model.signOut() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(model.unsyncedCount > 0 ? "Attention : \(model.unsyncedCount) modification(s) de ce Mac ne sont pas encore envoyées au serveur. Les opérations en attente de l’application seront perdues ; les fichiers modifiés dans le Finder et non envoyés seront conservés dans un dossier à part." : "La session de ce Mac sera révoquée et l’emplacement SP Drive retiré du Finder. Vos fichiers restent sur SP Drive.")
        }
    }
    private func load() async {
        do { sessions = try await model.api?.sessions() ?? []; error = nil } catch { self.error = DriveError.wrap(error).errorDescription }
    }
}

/// The account's own consent to external AI providers. Off by default; the local provider needs none.
struct AIConsentSection: View {
    let model: AppModel
    @State private var providers: AIProviders?
    @State private var error: String?
    var body: some View {
        Section("SP Drive AI") {
            if let p = providers {
                let local = p.providers.filter { $0.local && $0.configured }, external = p.providers.filter { !$0.local && $0.configured }
                LabeledContent("Modèle local", value: local.isEmpty ? "aucun configuré sur ce serveur" : local.flatMap { $0.models.map(\.label) }.joined(separator: ", "))
                Toggle("Autoriser les fournisseurs externes pour mon compte", isOn: Binding(get: { p.external?.account ?? false }, set: { on in Task { await set(on) } }))
                    .accessibilityIdentifier("ai-external-toggle")
                Text(p.external?.server == true
                     ? (external.isEmpty ? "Le serveur autorise les fournisseurs externes, mais aucun n’est configuré." : "Fournisseurs externes configurés : \(external.map(\.label).joined(separator: ", ")). Activé, des passages de vos documents leur sont envoyés à chaque question que vous posez avec l’un de leurs modèles.")
                     : "L’administrateur de ce serveur n’a pas activé les fournisseurs externes : ce réglage est sans effet tant que c’est le cas. Avec le modèle local, rien ne quitte l’infrastructure MacLustr.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(error ?? "Chargement…").foregroundStyle(.secondary) }
        }
        .task { await load() }
    }
    private func load() async { do { providers = try await model.next?.aiProviders(); error = nil } catch { self.error = NextText.error(error) } }
    private func set(_ on: Bool) async { do { try await model.next?.setExternalAI(on) } catch { self.error = NextText.error(error) }; await load() }
}
