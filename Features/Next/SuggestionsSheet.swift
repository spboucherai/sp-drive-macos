// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/SuggestionsSheet.swift
// Description: AI organisation suggestions: for the selected files, the model proposes a clearer name, a folder, tags and a category, with its reason. This is a review list — every proposal is applied one at a time, by the person, with the ordinary actions of the app (rename, move: journaled, undoable by hand). Nothing is applied without that confirmation, and the server itself applies nothing.
import SPDriveCore
import SPDriveNext
import SwiftUI

struct SuggestionsSheet: View {
    let model: AppModel
    let nav: Navigator
    let items: [DriveItem]
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<AISuggestions> = .loading
    /// What was applied in this sheet: "<fileId>|name", "<fileId>|folder".
    @State private var applied: Set<String> = []
    @State private var dismissed: Set<String> = []

    private var files: [DriveItem] { items.filter { !$0.isFolder && !$0.isTrashed }.prefix(20).map { $0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SPDTheme.Space.md) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(SPDTheme.brand)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Suggestions de rangement").font(SPDTheme.Typo.title)
                    Text("Des propositions, pas des changements : rien n’est modifié tant que vous n’appliquez pas une ligne.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                }
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(SPDTheme.Space.lg)
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            switch state {
            case .loading:
                VStack(spacing: SPDTheme.Space.md) { ProgressView(); Text("Le modèle lit le début de \(files.count) document\(files.count > 1 ? "s" : "")…").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m):
                SPDEmptyState(symbol: "sparkles", title: "Pas de suggestion", message: m, width: 420) { Button("Réessayer") { Task { await load() } } }
            case .ready(let r):
                let shown = r.suggestions.filter { !dismissed.contains($0.fileId) }
                if shown.isEmpty {
                    SPDEmptyState(symbol: "checkmark.circle", title: r.suggestions.isEmpty ? "Rien à proposer" : "Tout est traité", message: r.suggestions.isEmpty ? "Le modèle n’a rien proposé pour ces fichiers (texte non indexé, ou rien de mieux à suggérer)." : "Vous avez appliqué ou écarté chaque proposition.", width: 420)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SPDTheme.Space.md) {
                            ForEach(shown) { s in card(s) }
                            Text("Proposé par \(signature(r)). Une proposition de modèle peut se tromper : lisez-la avant de l’appliquer.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
                        }.padding(SPDTheme.Space.lg)
                    }
                }
            }
        }
        .frame(width: 680, height: 600).background(SPDTheme.surface)
        .task { await load() }
        .accessibilityIdentifier("suggestions-sheet")
    }
    private func signature(_ r: AISuggestions) -> String { [r.model, r.provider.map { "via \($0)" }].compactMap { $0 }.joined(separator: " ") }
    @ViewBuilder private func card(_ s: AISuggestion) -> some View {
        if let item = model.item(s.fileId) {
            VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
                HStack(spacing: SPDTheme.Space.sm) {
                    ItemThumbnail(model: model, item: item, side: 24)
                    Text(item.name).font(SPDTheme.Typo.bodyStrong).lineLimit(1).truncationMode(.middle)
                    if let c = s.category { SPDPill(text: c, symbol: "tag") }
                    Spacer()
                    Button("Écarter") { dismissed.insert(s.fileId) }.buttonStyle(.link).help("Ne rien faire pour ce fichier")
                }
                if let reason = s.reason, !reason.isEmpty { Text(reason).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) }
                if let name = s.name, name != item.name {
                    proposal("pencil", "Renommer en", "« \(name) »", done: applied.contains("\(s.fileId)|name"), id: "apply-name") { model.rename(item, to: name); applied.insert("\(s.fileId)|name") }
                }
                if let f = s.folder, f.id != item.parentID {
                    let known = model.item(f.id) != nil
                    proposal("folder", "Déplacer dans", f.path, done: applied.contains("\(s.fileId)|folder"), enabled: known, id: "apply-folder") { model.move([model.item(s.fileId) ?? item], to: f.id); applied.insert("\(s.fileId)|folder") }
                    if !known { Text("Ce dossier n’est pas encore dans la copie locale de votre Drive.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary) }
                }
                if let tags = s.tags, !tags.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: SPDTheme.Space.sm) {
                        Image(systemName: "tag").foregroundStyle(SPDTheme.textSecondary).frame(width: 18)
                        Text("Étiquettes proposées : \(tags.joined(separator: ", "))").font(SPDTheme.Typo.callout)
                        Spacer()
                        Text("à poser depuis le site (l’app macOS ne gère pas les étiquettes)").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).spdCard(padding: SPDTheme.Space.md, radius: SPDTheme.Radius.md)
        }
    }
    private func proposal(_ symbol: String, _ verb: String, _ value: String, done: Bool, enabled: Bool = true, id: String, _ apply: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SPDTheme.Space.sm) {
            Image(systemName: symbol).foregroundStyle(SPDTheme.brand).frame(width: 18)
            Text(verb).font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
            Text(value).font(SPDTheme.Typo.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
            Spacer()
            if done { Label("Appliqué", systemImage: "checkmark.circle.fill").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.positive) }
            else { Button("Appliquer", action: apply).controlSize(.small).disabled(!enabled).accessibilityIdentifier(id) }
        }
    }
    private func load() async {
        guard let next = model.next else { return }
        guard !files.isEmpty else { state = .failed("Sélectionnez des fichiers (pas des dossiers) pour obtenir des suggestions."); return }
        state = .loading
        do { state = .ready(try await next.aiSuggest(fileIDs: files.map(\.id))) } catch { state = .failed(NextText.error(error)) }
    }
}
