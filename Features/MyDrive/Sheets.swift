// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/MyDrive/Sheets.swift
// Description: Sheets of the browser: naming (new folder, rename), choosing a destination folder, and the information inspector.
import SPDriveCore
import SwiftUI

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: String
    let run: (String) -> Void
    @State private var name: String
    @FocusState private var focused: Bool
    init(title: String, initial: String, action: String, selectStem: Bool = false, run: @escaping (String) -> Void) {
        self.title = title; self.action = action; self.run = run; _name = State(initialValue: initial)
    }
    private var clean: String { NameRules.sanitize(name, fallback: "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Nom", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit).accessibilityIdentifier("name-field")
            if !name.isEmpty, clean != name.trimmingCharacters(in: .whitespaces), !clean.isEmpty {
                Text("Sera enregistré sous « \(clean) » (caractères non admis remplacés).").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button(action, action: submit).keyboardShortcut(.defaultAction).disabled(clean.isEmpty) }
        }
        .padding(20).frame(width: 420).onAppear { focused = true }
    }
    private func submit() { guard !clean.isEmpty else { return }; run(name); dismiss() }
}

/// Folder tree of the mirror to choose where to move items.
struct MoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [DriveItem]
    @State private var target: String?
    struct Node: Identifiable { let id: String; let name: String; var children: [Node]? }

    private func nodes(of parent: String, excluding: Set<String>, depth: Int = 0) -> [Node] {
        guard depth < 12 else { return [] }
        return model.children(of: parent).filter { $0.isFolder && !excluding.contains($0.id) }.map { f in
            let kids = nodes(of: f.id, excluding: excluding, depth: depth + 1)
            return Node(id: f.id, name: f.name, children: kids.isEmpty ? nil : kids)
        }
    }
    var body: some View {
        let moving = Set(items.map(\.id))
        let root = model.rootID ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Text("Déplacer \(items.count == 1 ? "« \(items[0].name) »" : "\(items.count) éléments") vers…").font(.headline)
            List(selection: $target) {
                Label("Mon Drive", systemImage: "externaldrive").tag(root)
                OutlineGroup(nodes(of: root, excluding: moving), children: \.children) { n in Label(n.name, systemImage: "folder").tag(n.id) }
            }
            .frame(minHeight: 280).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Déplacer") { if let t = target { model.move(items, to: t) }; dismiss() }.keyboardShortcut(.defaultAction).disabled(target == nil || items.allSatisfy { $0.parentID == target })
            }
        }
        .padding(20).frame(width: 460, height: 440)
    }
}

/// Details of the selection: where it is, its state on this Mac, its versions and links.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let items: [DriveItem]
    var body: some View {
        Group {
            if let item = items.first, items.count == 1 { single(item) }
            else if items.isEmpty { ContentUnavailableView("Aucune sélection", systemImage: "info.circle", description: Text("Sélectionnez un élément pour voir ses informations.")) }
            else {
                ContentUnavailableView("\(items.count) éléments", systemImage: "square.stack", description: Text(Fmt.bytes(items.filter { !$0.isFolder }.reduce(0) { $0 + $1.size })))
            }
        }
    }
    private func single(_ item: DriveItem) -> some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ItemIcon(item: item, size: 44)
                    VStack(alignment: .leading, spacing: 2) { Text(item.name).font(.headline).textSelection(.enabled).lineLimit(3); Text(Fmt.kind(item)).foregroundStyle(.secondary) }
                }
            }
            Section("Informations") {
                if !item.isFolder { LabeledContent("Taille", value: Fmt.bytes(item.size)) }
                LabeledContent("Emplacement", value: "Mon Drive" + model.path(to: item.id).dropLast().map { " › " + $0.name }.joined())
                LabeledContent("Créé", value: Fmt.date(item.createdAt))
                LabeledContent("Modifié", value: Fmt.date(item.isFolder ? item.updatedAt : item.contentAt))
                if !item.isFolder { LabeledContent("Versions", value: "\(item.versionCount)") }
                if let t = item.trashedAt { LabeledContent("Mis à la corbeille", value: Fmt.date(t)) }
            }
            Section("Sur ce Mac") {
                LabeledContent("État") { SyncStateLabel(model: model, item: item) }
                if !item.isTrashed {
                    Toggle("Garder disponible hors ligne", isOn: Binding(get: { model.isPinnedItself(item.id) }, set: { on in Task { await model.setPinned([item], on) } }))
                    if model.isPinned(item.id), !model.isPinnedItself(item.id) { Text("Inclus dans un dossier gardé hors ligne.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !item.isFolder {
                Section("Intégrité") {
                    LabeledContent("SHA-256") { Text(item.sha256.isEmpty ? "—" : item.sha256).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
                    LabeledContent("Antivirus", value: ["clean": "Sain", "pending": "Analyse en attente", "infected": "Bloqué", "error": "Non analysé"][item.scan] ?? item.scan)
                }
            }
            if !item.isTrashed {
                Section {
                    Button("Partager…", systemImage: "link") { model.nav.sheet = .share(item) }
                    if !item.isFolder { Button("Historique des versions…", systemImage: "clock.arrow.circlepath") { model.nav.sheet = .versions(item) } }
                    else { Button("Créer un lien de dépôt…", systemImage: "tray.and.arrow.down") { model.nav.sheet = .portal(folder: item) } }
                }
            }
        }
        .formStyle(.grouped)
    }
}
