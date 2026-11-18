// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Settings/SettingsView.swift
// Description: Settings window: general (Finder location, start at login, menu bar), synchronisation (pause, bandwidth, parallel transfers), notifications, account and security (devices, biometric lock, sign out).
import ServiceManagement
import SPDriveCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Général", systemImage: "gearshape") }
            SyncSettings().tabItem { Label("Synchronisation", systemImage: "arrow.triangle.2.circlepath") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            AccountSettings().tabItem { Label("Compte", systemImage: "person.crop.circle") }
        }
        .frame(width: 560, height: 460)
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
            Section("Transferts simultanés") {
                Picker("Nombre", selection: Binding(get: { s.parallelTransfers }, set: { s.parallelTransfers = $0; Task { await model.applyTransferSettings() } })) {
                    Text("Automatique (selon le débit mesuré)").tag(0)
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Text("En automatique, SP Drive ajoute des transferts tant que le débit total augmente, et se limite sur un partage de connexion ou en mode Données réduites.").font(.caption).foregroundStyle(.secondary)
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
            }
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
