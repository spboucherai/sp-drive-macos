// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/SearchResultsView.swift
// Description: Search 2.0: the toolbar field asks the server, which looks in names and in the text of documents (PDF, Office, images through OCR) and answers with highlighted passages; a "by meaning" mode when the server has its on-device model. Scores are never shown. Offline, or on a 1.0 server, the browser's local name search takes over.
import SPDriveCore
import SPDriveNext
import SwiftUI

struct SearchResultsView: View {
    let model: AppModel
    let nav: Navigator
    @State private var results: Loadable<SearchResults> = .loading
    @State private var semantic: Loadable<SemanticResults> = .loading
    @State private var asked = ""

    var body: some View {
        @Bindable var nav = nav
        VStack(spacing: 0) {
            HStack(spacing: SPDTheme.Space.md) {
                Picker("Chercher dans", selection: $nav.searchScope) { Text("Noms et contenu").tag(SearchScope.all); Text("Noms").tag(SearchScope.name); Text("Contenu").tag(SearchScope.content) }
                    .pickerStyle(.segmented).fixedSize().disabled(nav.searchSemantic).labelsHidden()
                if model.has(.semantic) {
                    Toggle(isOn: $nav.searchSemantic) { Label("Par le sens", systemImage: "sparkle.magnifyingglass") }.toggleStyle(.button)
                        .help("Rapproche votre phrase des passages qui veulent dire la même chose, même sans les mêmes mots. Calculé sur le serveur, sans service externe.")
                }
                Spacer()
                Text(summary).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
            }
            .padding(.horizontal, SPDTheme.Space.md).frame(height: 36).background(.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(SPDTheme.hairline).frame(height: 1) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity).background(SPDTheme.canvas)
        }
        .task(id: "\(nav.searchText)|\(nav.searchScope.rawValue)|\(nav.searchSemantic)") { await run() }
        .accessibilityIdentifier("search-results")
    }
    private var summary: String {
        if nav.searchSemantic { return semantic.value.map { "\($0.hits.count) passage\($0.hits.count > 1 ? "s" : "") proche\($0.hits.count > 1 ? "s" : ""), du plus au moins proche" } ?? "" }
        guard let r = results.value else { return "" }
        let n = r.files.count + r.folders.count, inContent = r.files.filter { $0.match?.where != "name" }.count
        return "\(n) résultat\(n > 1 ? "s" : "")" + (inContent > 0 ? " · \(inContent) dans le contenu" : "")
    }
    @ViewBuilder private var content: some View {
        if nav.searchSemantic {
            switch semantic {
            case .loading: ProgressView()
            case .failed(let m): SPDEmptyState(symbol: "wifi.slash", title: "Recherche indisponible", message: m) { Button("Réessayer") { Task { await run() } } }
            case .ready(let r):
                if !r.available { SPDEmptyState(symbol: "sparkle.magnifyingglass", title: "Recherche par le sens indisponible", message: "Le modèle du serveur ne répond pas en ce moment. La recherche par mots fonctionne.") { Button("Chercher par mots") { nav.searchSemantic = false } } }
                else if r.hits.isEmpty { SPDEmptyState(symbol: "sparkle.magnifyingglass", title: "Aucun passage proche", message: "Aucun document indexé ne contient de passage proche de cette phrase.") }
                else {
                    List(selection: selection) {
                        ForEach(r.hits) { h in
                            VStack(alignment: .leading, spacing: 3) {
                                NextFileRow(model: model, file: h.file) { if let p = h.passage.page { SPDPill(text: "p. \(p)") } }
                                Text(h.passage.text).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).lineLimit(3).padding(.leading, 32)
                            }
                            .padding(.vertical, 3).tag(h.file.id).contextMenu { menu(h.file) }
                        }
                    }
                    .listStyle(.inset).contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in open(ids) }
                }
            }
        } else {
            switch results {
            case .loading: ProgressView()
            case .failed(let m): SPDEmptyState(symbol: "wifi.slash", title: "Recherche indisponible", message: m) { Button("Réessayer") { Task { await run() } } }
            case .ready(let r):
                if r.files.isEmpty && r.folders.isEmpty {
                    SPDEmptyState(symbol: "magnifyingglass", title: "Aucun résultat", message: "Ni un nom ni le contenu d’un document ne correspond à « \(asked) ». Essayez d’autres mots" + (model.has(.semantic) ? ", ou la recherche par le sens." : ".")) {
                        if model.has(.semantic) { Button("Chercher par le sens") { nav.searchSemantic = true }.buttonStyle(.borderedProminent) }
                        Button("Effacer la recherche") { nav.searchText = "" }
                    }
                } else {
                    List(selection: selection) {
                        if !r.folders.isEmpty {
                            Section("Dossiers") {
                                ForEach(r.folders) { f in
                                    Label(f.name, systemImage: "folder").tag(f.id)
                                        .contextMenu { Button("Ouvrir", systemImage: "folder") { nav.searchText = ""; nav.go(to: f.id) } }
                                }
                            }
                        }
                        Section("Fichiers") {
                            ForEach(r.files) { f in
                                VStack(alignment: .leading, spacing: 3) {
                                    NextFileRow(model: model, file: f) {
                                        HStack(spacing: 4) {
                                            if let p = f.match?.page { SPDPill(text: "p. \(p)") }
                                            if f.match?.where == "content" { SPDPill(text: "Dans le contenu", symbol: "text.magnifyingglass", tint: SPDTheme.brand) }
                                            else if f.match?.where == "both" { SPDPill(text: "Nom et contenu", symbol: "text.magnifyingglass", tint: SPDTheme.brand) }
                                        }
                                    }
                                    if let m = f.match, m.snippet != nil { SnippetText(match: m).padding(.leading, 32) }
                                }
                                .padding(.vertical, 3).tag(f.id).contextMenu { menu(f) }
                            }
                        }
                    }
                    .listStyle(.inset).contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in open(ids) }
                }
            }
        }
    }
    private var selection: Binding<Set<String>> { Binding(get: { nav.selection }, set: { nav.selection = $0 }) }
    @ViewBuilder private func menu(_ f: NextFile) -> some View {
        Button("Afficher dans son dossier", systemImage: "folder") { model.show(f, in: nav) }
        Button("Ouvrir", systemImage: "arrow.up.forward.app") { Task { await model.open(f.item(model)) } }
        if model.has(.ai) { Button("Demander à ce document…", systemImage: "sparkles") { nav.sheet = .ask(f.item(model)) } }
        Button("Télécharger", systemImage: "arrow.down.circle") { Task { await model.download([f.item(model)]) } }
    }
    private func open(_ ids: Set<String>) {
        guard let id = ids.first else { return }
        if let f = results.value?.files.first(where: { $0.id == id }) ?? semantic.value?.hits.first(where: { $0.file.id == id })?.file { model.show(f, in: nav) }
        else if results.value?.folders.contains(where: { $0.id == id }) == true { nav.searchText = ""; nav.go(to: id) }
    }
    private func run() async {
        let q = nav.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let next = model.next else { return }
        try? await Task.sleep(nanoseconds: 280_000_000) // let the person finish the word
        if Task.isCancelled { return }
        asked = q
        if nav.searchSemantic {
            do { semantic = .ready(try await next.semanticSearch(q, limit: 20)) } catch { if !Task.isCancelled { semantic = .failed(NextText.error(error)) } }
        } else {
            do { results = .ready(try await next.search(q, in: nav.searchScope)) } catch { if !Task.isCancelled { results = .failed(NextText.error(error)) } }
        }
    }
}
