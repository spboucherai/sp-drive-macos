// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/CollectionsView.swift
// Description: Smart collections: saved rules that gather files wherever they are (a collection references files, it never copies them). The section lists a collection's files; the rule builder composes conditions with the fields, operators and values the server accepts, and shows the live result before saving.
import SPDriveCore
import SPDriveNext
import SwiftUI

enum CollectionLook {
    static func color(_ name: String?) -> Color {
        switch name { case "red": Color(red: 0.84, green: 0.27, blue: 0.25); case "orange": Color(red: 0.93, green: 0.52, blue: 0.18); case "amber": Color(red: 0.85, green: 0.65, blue: 0.13); case "green": Color(red: 0.20, green: 0.62, blue: 0.40)
        case "teal": Color(red: 0.16, green: 0.60, blue: 0.62); case "blue": Color(red: 0.25, green: 0.48, blue: 0.92); case "violet": SPDTheme.brand; case "pink": Color(red: 0.88, green: 0.36, blue: 0.62); default: SPDTheme.textSecondary }
    }
    static func colorName(_ c: String) -> String { ["slate": "Ardoise", "red": "Rouge", "orange": "Orange", "amber": "Ambre", "green": "Vert", "teal": "Sarcelle", "blue": "Bleu", "violet": "Violet", "pink": "Rose"][c] ?? c }
    /// The server stores a free identifier; the clients agree on SF Symbol names.
    static func symbol(_ icon: String?) -> String { (icon?.isEmpty == false ? icon! : "square.stack.3d.up") }
    static let symbols = ["square.stack.3d.up", "doc.text", "photo", "film", "music.note", "tablecells", "archivebox", "star", "clock", "link", "tray.full", "briefcase"]
    static func field(_ f: String) -> String {
        ["kind": "Type", "ext": "Extension", "name": "Nom", "text": "Contenu", "size": "Taille", "modified": "Modifié", "created": "Créé", "starred": "Favori", "shared": "Partagé", "untagged": "Sans étiquette", "folder": "Dossier", "tag": "Étiquette"][f] ?? f
    }
    static func op(_ o: String, field: String) -> String {
        switch o { case "is": ["starred", "shared", "untagged"].contains(field) ? "est" : (field == "folder" ? "est dans" : "est"); case "isNot": field == "folder" ? "n’est pas dans" : "n’est pas"; case "contains": "contient"
        case "gt": ["modified", "created"].contains(field) ? "après le" : "plus grand que"; case "lt": ["modified", "created"].contains(field) ? "avant le" : "plus petit que"; case "within": "dans les derniers"; default: o }
    }
    /// A rule said in words.
    @MainActor static func describe(_ rule: CollectionRule, model: AppModel) -> String {
        rule.conditions.map { c -> String in
            let v: String
            switch c.value {
            case .bool(let b): v = b ? "oui" : "non"
            case .number(let n): v = c.field == "size" ? Fmt.bytes(Int64(n)) : (c.op == "within" ? "\(Int(n)) jours" : "\(Int(n))")
            case .string(let s): v = c.field == "kind" ? NextText.kind(s) : c.field == "folder" ? "« \(model.item(s)?.name ?? "dossier") »" : "« \(s) »"
            }
            return "\(field(c.field).lowercased()) \(op(c.op, field: c.field)) \(v)"
        }.joined(separator: rule.match == "any" ? " ou " : " et ")
    }
}

struct CollectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var items: Loadable<CollectionItems> = .loading
    @State private var confirmDelete: SmartCollection?

    private var current: SmartCollection? { model.collections.first { $0.id == nav.collectionID } ?? model.collections.first }
    var body: some View {
        Group {
            if model.collections.isEmpty {
                SPDEmptyState(symbol: "square.stack.3d.up", title: "Aucune collection", message: "Une collection rassemble des fichiers selon une règle — « les PDF modifiés ce mois-ci », « les images de plus de 10 Mo » — où qu’ils soient rangés. Elle se met à jour toute seule et ne copie rien.") {
                    Button("Créer une collection…") { nav.sheet = .collection(nil) }.buttonStyle(.borderedProminent).accessibilityIdentifier("new-collection")
                }
            } else if let c = current {
                VStack(spacing: 0) {
                    HStack(spacing: SPDTheme.Space.sm) {
                        Image(systemName: CollectionLook.symbol(c.icon)).foregroundStyle(CollectionLook.color(c.color)).font(.title3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name).font(SPDTheme.Typo.headline)
                            Text((c.rule.match == "any" ? "Au moins une condition : " : "Toutes les conditions : ") + CollectionLook.describe(c.rule, model: model)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(SPDTheme.Space.md).background(.bar).overlay(alignment: .bottom) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
                    switch items {
                    case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed(let m): SPDEmptyState(symbol: "wifi.slash", title: "Collection indisponible", message: m) { Button("Réessayer") { Task { await load(c) } } }
                    case .ready(let r):
                        if r.files.isEmpty { SPDEmptyState(symbol: CollectionLook.symbol(c.icon), title: "Rien pour l’instant", message: "Aucun fichier ne répond à cette règle en ce moment. La collection se remplira d’elle-même.") { Button("Modifier la règle…") { nav.sheet = .collection(c) } } }
                        else {
                            List(selection: Binding(get: { nav.selection }, set: { nav.selection = $0 })) {
                                ForEach(r.files) { f in
                                    NextFileRow(model: model, file: f) { Text("\(Fmt.bytes(f.size)) · \(f.modified.map(Fmt.day) ?? "")").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit() }
                                        .tag(f.id).padding(.vertical, 2)
                                        .contextMenu {
                                            Button("Afficher dans son dossier", systemImage: "folder") { model.show(f, in: nav) }
                                            Button("Ouvrir", systemImage: "arrow.up.forward.app") { Task { await model.open(f.item(model)) } }
                                            Button("Télécharger", systemImage: "arrow.down.circle") { Task { await model.download([f.item(model)]) } }
                                        }
                                }
                                if r.total > r.files.count { Text("\(r.total - r.files.count) autres fichiers répondent à la règle.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary) }
                            }
                            .listStyle(.inset)
                            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in if let f = r.files.first(where: { ids.contains($0.id) }) { model.show(f, in: nav) } }
                        }
                    }
                }
                .task(id: "\(c.id)|\(c.updatedAt?.timeIntervalSince1970 ?? 0)|\(model.revision)") { await load(c) }
            }
        }
        .navigationTitle(current?.name ?? "Collections")
        .navigationSubtitle(items.value.map { "\($0.total) fichier\($0.total > 1 ? "s" : "")" } ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { nav.sheet = .collection(nil) } label: { Label("Nouvelle collection", systemImage: "plus") }.help("Nouvelle collection")
                if let c = current {
                    Button { nav.sheet = .collection(c) } label: { Label("Modifier", systemImage: "slider.horizontal.3") }.help("Modifier la règle")
                    Button(role: .destructive) { confirmDelete = c } label: { Label("Supprimer la collection", systemImage: "trash") }.help("Supprimer la collection (les fichiers ne sont pas touchés)")
                }
            }
        }
        .confirmationDialog("Supprimer la collection « \(confirmDelete?.name ?? "") » ?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Supprimer la collection", role: .destructive) { if let c = confirmDelete { Task { try? await model.next?.deleteCollection(c.id); nav.collectionID = nil; await model.refreshCollections() } } }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Seule la règle est supprimée. Aucun fichier n’est modifié ni supprimé.") }
    }
    private func load(_ c: SmartCollection) async {
        guard let next = model.next else { return }
        do { items = .ready(try await next.collectionItems(c.id)) } catch { items = .failed(NextText.error(error)) }
    }
}

/// One condition being edited (kept loosely typed while the person composes it).
struct ConditionDraft: Identifiable {
    let id = UUID()
    var field = "kind", op = "is"
    var text = "pdf", number = 30.0, flag = true, date = Date(), unit = 1_000_000.0
    init() {}
    init(_ c: RuleCondition) {
        field = c.field; op = c.op
        switch c.value {
        case .bool(let b): flag = b
        case .number(let n): if c.field == "size" { unit = n >= 1e9 ? 1e9 : n >= 1e6 ? 1e6 : 1e3; number = n / unit } else { number = n }
        case .string(let s): if ["modified", "created"].contains(c.field), let d = NextClient.parseDate(s) { date = d } else { text = s }
        }
    }
    var valueKind: String { CollectionRule.fields.first { $0.field == field }?.value ?? "string" }
    var ops: [String] { CollectionRule.fields.first { $0.field == field }?.ops ?? ["is"] }
    /// nil while the condition is incomplete.
    var condition: RuleCondition? {
        switch valueKind {
        case "bool": return RuleCondition(field: field, op: "is", value: .bool(flag))
        case "bytes": return number > 0 ? RuleCondition(field: field, op: op, value: .number((number * unit).rounded())) : nil
        case "date":
            if op == "within" { return number >= 1 ? RuleCondition(field: field, op: op, value: .number(number.rounded())) : nil }
            let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
            return RuleCondition(field: field, op: op, value: .string(f.string(from: date)))
        default:
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : RuleCondition(field: field, op: op, value: .string(field == "ext" ? t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) : t))
        }
    }
}

struct CollectionEditor: View {
    let model: AppModel
    let nav: Navigator
    let existing: SmartCollection?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "square.stack.3d.up"
    @State private var color = "violet"
    @State private var matchAll = true
    @State private var conditions: [ConditionDraft] = [ConditionDraft()]
    @State private var sortBy = "updated"
    @State private var sortDesc = true
    @State private var preview: Loadable<CollectionItems> = .loading
    @State private var error: String?
    @State private var busy = false

    private var rule: CollectionRule? {
        let c = conditions.compactMap(\.condition)
        guard c.count == conditions.count, !c.isEmpty else { return nil }
        return CollectionRule(match: matchAll ? "all" : "any", conditions: c, sort: .init(by: sortBy, dir: sortDesc ? "desc" : "asc"))
    }
    private var folders: [DriveItem] { model.rootID.map { root in model.children(of: root).filter(\.isFolder).flatMap { f in [f] + model.children(of: f.id).filter(\.isFolder) } } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "Nouvelle collection" : "Modifier la collection").font(SPDTheme.Typo.title)
                Text("Une règle, pas un dossier : les fichiers restent où ils sont.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
            }.padding(SPDTheme.Space.lg)
            Form {
                Section("Présentation") {
                    TextField("Nom", text: $name).accessibilityIdentifier("collection-name")
                    Picker("Symbole", selection: $icon) { ForEach(CollectionLook.symbols, id: \.self) { Image(systemName: $0).tag($0) } }.pickerStyle(.segmented)
                    Picker("Couleur", selection: $color) { ForEach(CollectionRule.colors, id: \.self) { c in Label(CollectionLook.colorName(c), systemImage: "circle.fill").foregroundStyle(CollectionLook.color(c)).tag(c) } }
                }
                Section("Règle") {
                    Picker("Garder les fichiers qui remplissent", selection: $matchAll) { Text("toutes les conditions").tag(true); Text("au moins une condition").tag(false) }
                    ForEach($conditions) { $c in
                        HStack(spacing: SPDTheme.Space.sm) {
                            Picker("Champ", selection: $c.field) { ForEach(CollectionRule.fields.map(\.field).filter { $0 != "tag" }, id: \.self) { Text(CollectionLook.field($0)).tag($0) } }.labelsHidden().frame(width: 130)
                                .onChange(of: c.field) { _, f in c.op = c.ops.first ?? "is"; if f == "kind" { c.text = "pdf" } else if f == "folder" { c.text = folders.first?.id ?? "" } else if ["ext", "name", "text"].contains(f) { c.text = "" } }
                            if c.valueKind != "bool" { Picker("Opérateur", selection: $c.op) { ForEach(c.ops, id: \.self) { Text(CollectionLook.op($0, field: c.field)).tag($0) } }.labelsHidden().frame(width: 150) }
                            value($c)
                            Spacer(minLength: 0)
                            Button { conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(SPDTheme.textSecondary).disabled(conditions.count == 1).accessibilityLabel("Retirer la condition")
                        }
                    }
                    Button("Ajouter une condition", systemImage: "plus.circle") { conditions.append(ConditionDraft()) }.buttonStyle(.link).disabled(conditions.count >= 20)
                    HStack { Picker("Trier par", selection: $sortBy) { Text("Date de modification").tag("updated"); Text("Nom").tag("name"); Text("Taille").tag("size"); Text("Date de création").tag("created") }; Toggle("Décroissant", isOn: $sortDesc) }
                }
                Section("Résultat en ce moment") {
                    switch preview {
                    case .loading: Text(rule == nil ? "Complétez les conditions pour voir le résultat." : "Calcul…").foregroundStyle(SPDTheme.textSecondary)
                    case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(SPDTheme.warning)
                    case .ready(let r):
                        Text("\(r.total) fichier\(r.total > 1 ? "s" : "")").font(SPDTheme.Typo.bodyStrong)
                        ForEach(r.files.prefix(5)) { NextFileRow(model: model, file: $0) }
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SPDTheme.critical) } }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Créer" : "Enregistrer") { Task { await save() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(busy || rule == nil || name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("save-collection")
            }.padding(SPDTheme.Space.lg)
        }
        .frame(width: 680, height: 660)
        .onAppear {
            guard let e = existing else { return }
            name = e.name; icon = CollectionLook.symbol(e.icon); color = e.color ?? "violet"; matchAll = e.rule.match != "any"
            conditions = e.rule.conditions.map(ConditionDraft.init); sortBy = e.rule.sort?.by ?? "updated"; sortDesc = e.rule.sort?.dir != "asc"
        }
        .task(id: rule) {
            guard let rule, let next = model.next else { preview = .loading; return }
            try? await Task.sleep(nanoseconds: 350_000_000); if Task.isCancelled { return }
            do { preview = .ready(try await next.previewCollection(rule, limit: 5)) } catch { if !Task.isCancelled { preview = .failed(NextText.error(error)) } }
        }
    }
    @ViewBuilder private func value(_ c: Binding<ConditionDraft>) -> some View {
        switch c.wrappedValue.valueKind {
        case "kind": Picker("Valeur", selection: c.text) { ForEach(CollectionRule.kinds, id: \.self) { Text(NextText.kind($0)).tag($0) } }.labelsHidden().frame(width: 170)
        case "bool": Picker("Valeur", selection: c.flag) { Text("oui").tag(true); Text("non").tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
        case "bytes":
            TextField("Taille", value: c.number, format: .number).frame(width: 70)
            Picker("Unité", selection: c.unit) { Text("Ko").tag(1e3); Text("Mo").tag(1e6); Text("Go").tag(1e9) }.labelsHidden().frame(width: 70)
        case "date":
            if c.wrappedValue.op == "within" { TextField("Jours", value: c.number, format: .number).frame(width: 60); Text("jours") }
            else { DatePicker("Date", selection: c.date, displayedComponents: .date).labelsHidden() }
        case "folder": Picker("Dossier", selection: c.text) { ForEach(folders) { f in Text(model.path(to: f.id).map(\.name).joined(separator: " › ")).tag(f.id) } }.labelsHidden().frame(maxWidth: 240)
        default: TextField(c.wrappedValue.field == "ext" ? "pdf" : "texte", text: c.text).frame(maxWidth: 220)
        }
    }
    private func save() async {
        guard let rule, let next = model.next else { return }
        busy = true; defer { busy = false }
        let draft = CollectionDraft(name: name.trimmingCharacters(in: .whitespaces), icon: icon, color: color, rule: rule)
        do {
            let saved: SmartCollection
            if let e = existing { saved = try await next.updateCollection(e.id, draft) } else { saved = try await next.createCollection(draft) }
            await model.refreshCollections(); nav.collectionID = saved.id; nav.section = .collections; dismiss()
        } catch { self.error = NextText.error(error) }
    }
}
