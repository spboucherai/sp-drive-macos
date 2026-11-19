// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/StorageCenter.swift
// Description: Storage Command Center (server 2.0): what the account really stores, by kind and by folder with drill-down, the largest files, growth over 90 days, and duplicates (identical content, look-alike images). Everything is a view of facts: nothing is ever deleted automatically — removing a file is always an explicit action on that file.
import Charts
import SPDriveCore
import SPDriveNext
import SwiftUI

struct StorageCenter: View {
    let model: AppModel
    let nav: Navigator
    @State private var overview: Loadable<StorageOverview> = .loading
    @State private var kind: String?
    @State private var folder: Loadable<StorageFolder>?
    @State private var duplicates: Loadable<Duplicates>?
    @State private var similar = false

    var body: some View {
        Group {
            switch overview {
            case .loading: ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let m): Label(m, systemImage: "wifi.slash").foregroundStyle(SPDTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).spdCard()
            case .ready(let o): content(o)
            }
        }
        .task(id: model.revision) { await load() }
    }
    @ViewBuilder private func content(_ o: StorageOverview) -> some View {
        card("Espace", "internaldrive") {
            QuotaBar(used: o.quota.used, limit: o.quota.limit)
            HStack { stat(Fmt.bytes(o.quota.used), "Réellement stocké"); stat(Fmt.bytes(max(0, o.quota.limit - o.quota.used)), "Disponible"); stat(Fmt.bytes(o.trashBytes), "Retenu par la corbeille"); stat(Fmt.bytes(o.oldVersionBytes), "Retenu par d’anciennes versions") }
            Text("\(o.counts.files) fichiers, \(o.counts.folders) dossiers, \(o.counts.versions) versions. « Réellement stocké » compte chaque contenu une seule fois : deux fichiers identiques n’occupent qu’une place.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
        }
        card("Par type", "square.grid.2x2") {
            let total = max(1, o.byKind.reduce(0) { $0 + $1.bytes })
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(o.byKind) { k in
                        RoundedRectangle(cornerRadius: 3).fill(NextText.kindColor(k.kind)).opacity(kind == nil || kind == k.kind ? 1 : 0.25)
                            .frame(width: max(3, (g.size.width - CGFloat(o.byKind.count) * 2) * CGFloat(k.bytes) / CGFloat(total)))
                            .onTapGesture { kind = kind == k.kind ? nil : k.kind }.help("\(NextText.kind(k.kind)) : \(Fmt.bytes(k.bytes))")
                            .accessibilityLabel("\(NextText.kind(k.kind)), \(Fmt.bytes(k.bytes))").accessibilityAddTraits(.isButton)
                    }
                }
            }.frame(height: 18).spdMotion(.select, value: kind)
            FlowRow(spacing: SPDTheme.Space.sm) {
                ForEach(o.byKind) { k in
                    Button { kind = kind == k.kind ? nil : k.kind } label: {
                        HStack(spacing: 5) { Circle().fill(NextText.kindColor(k.kind)).frame(width: 8, height: 8); Text(NextText.kind(k.kind)).font(SPDTheme.Typo.callout); Text("\(Fmt.bytes(k.bytes)) · \(k.files)").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary) }
                            .padding(.horizontal, 8).padding(.vertical, 3).background(kind == k.kind ? SPDTheme.selection : SPDTheme.surface, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            if let kind {
                let files = o.largest.filter { NextText.kindOf($0) == kind }
                Text(files.isEmpty ? "Aucun des 20 plus gros fichiers n’est de ce type." : "Les plus gros fichiers de ce type").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                ForEach(files.prefix(6)) { f in fileRow(f) }
            }
        }
        card("Par dossier", "folder") {
            switch folder {
            case .none, .loading: ProgressView().controlSize(.small)
            case .failed(let m): Text(m).foregroundStyle(SPDTheme.textSecondary)
            case .ready(let f):
                HStack(spacing: 3) {
                    ForEach(Array(f.breadcrumbs.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Image(systemName: "chevron.compact.right").font(.caption).foregroundStyle(SPDTheme.textTertiary) }
                        Button(i == 0 ? "Mon Drive" : c.name) { Task { await drill(i == 0 ? "root" : c.id) } }.buttonStyle(.link).font(i == f.breadcrumbs.count - 1 ? SPDTheme.Typo.bodyStrong : SPDTheme.Typo.callout)
                            .accessibilityIdentifier("storage-crumb-\(i)")
                    }
                    Spacer()
                    Text("\(Fmt.bytes(f.total.bytes)) · \(f.total.files) fichiers").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit()
                }
                let top = max(1, max(f.children.map(\.bytes).max() ?? 0, f.direct.bytes))
                ForEach(f.children.sorted { $0.bytes > $1.bytes }.prefix(14)) { c in
                    Button { Task { await drill(c.folder.id) } } label: { bar(c.folder.name, "folder.fill", c.bytes, c.files, top, chevron: true) }.buttonStyle(.plain).help("Voir l’intérieur de « \(c.folder.name) »").accessibilityIdentifier("storage-folder")
                }
                if f.direct.files > 0 { bar("Fichiers directement ici", "doc", f.direct.bytes, f.direct.files, top, chevron: false) }
                if f.children.isEmpty, !f.files.isEmpty { ForEach(f.files.prefix(6)) { fileRow($0) } }
                if f.children.isEmpty, f.files.isEmpty { Text("Dossier vide.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) }
            }
        }
        card("Croissance sur 90 jours", "chart.bar") {
            if o.growth.isEmpty { Text("Aucun ajout dans les 90 derniers jours.").foregroundStyle(SPDTheme.textSecondary) }
            else {
                Chart(o.growth) { d in
                    BarMark(x: .value("Jour", NextClient.parseDate(d.date) ?? Date(), unit: .day), y: .value("Octets ajoutés", d.bytes)).foregroundStyle(SPDTheme.brand).cornerRadius(2)
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let b = v.as(Int64.self) { Text(Fmt.bytes(b)) } } } }
                .chartXScale(domain: (Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date())...Date())
                .frame(height: 130)
                .accessibilityLabel("Octets ajoutés par jour")
                let sum = o.growth.reduce(0) { $0 + $1.bytes }
                Text("\(Fmt.bytes(sum)) ajoutés en \(o.growth.count) jour\(o.growth.count > 1 ? "s" : "") d’activité (\(o.growth.reduce(0) { $0 + $1.versions }) versions). Seuls les jours avec des ajouts ont une barre.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
            }
        }
        card("Fichiers les plus volumineux", "arrow.up.right.square") {
            if o.largest.isEmpty { Text("Aucun fichier.").foregroundStyle(SPDTheme.textSecondary) }
            ForEach(o.largest.prefix(10)) { fileRow($0) }
        }
        card("Doublons", "doc.on.doc") {
            HStack {
                Picker("Mode", selection: $similar) { Text("Contenu identique").tag(false); if model.has(.similarImages) { Text("Images qui se ressemblent").tag(true) } }.pickerStyle(.segmented).fixedSize().labelsHidden()
                Spacer()
                Text(similar ? "Images redimensionnées, réencodées ou converties." : "\(o.duplicates.groups) groupe\(o.duplicates.groups > 1 ? "s" : "") · \(Fmt.bytes(o.duplicates.duplicateBytes ?? 0)) en copies").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
            }
            Text(similar ? "Ces images ne sont pas identiques : regardez-les avant de décider. Rien n’est supprimé automatiquement." : "Un contenu identique n’est stocké qu’une fois : retirer un doublon range votre Drive mais ne libère pas d’espace. Rien n’est supprimé automatiquement.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
            switch duplicates {
            case .none, .loading: ProgressView().controlSize(.small)
            case .failed(let m): Text(m).foregroundStyle(SPDTheme.textSecondary)
            case .ready(let d):
                if d.groups.isEmpty { Label(similar ? "Aucune image ressemblante trouvée." : "Aucun doublon.", systemImage: "checkmark.circle").foregroundStyle(SPDTheme.positive).font(SPDTheme.Typo.callout) }
                ForEach(d.groups.prefix(8)) { g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(similar ? "\(g.files.count) images proches" : "\(g.files.count) copies de \(Fmt.bytes(g.size ?? g.files.first?.size ?? 0))\(g.distinctNames == true ? " sous des noms différents" : "")").font(SPDTheme.Typo.caption.weight(.semibold)).foregroundStyle(SPDTheme.textSecondary)
                        ForEach(g.files) { f in fileRow(f, trash: true) }
                    }
                    .padding(SPDTheme.Space.sm).background(SPDTheme.surface, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.sm))
                }
                if d.groups.count > 8 { Text("\(d.groups.count - 8) autres groupes.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary) }
            }
        }
        .task(id: similar) { await loadDuplicates() }
    }
    private func fileRow(_ f: NextFile, trash: Bool = false) -> some View {
        NextFileRow(model: model, file: f) {
            HStack(spacing: SPDTheme.Space.sm) {
                Text(Fmt.bytes(f.size)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit()
                Button("Afficher") { model.show(f, in: nav) }.controlSize(.small)
                if trash { Button("Corbeille…", role: .destructive) { if let i = model.item(f.id) { model.trash([i]); model.banner = Banner(text: "« \(f.name) » est dans la corbeille : vous pouvez l’en ressortir.", isError: false) } }.controlSize(.small).disabled(model.item(f.id) == nil).help("Met ce fichier-ci à la corbeille (récupérable)") }
            }
        }
    }
    private func bar(_ name: String, _ symbol: String, _ bytes: Int64, _ files: Int, _ top: Int64, chevron: Bool) -> some View {
        HStack(spacing: SPDTheme.Space.sm) {
            Image(systemName: symbol).foregroundStyle(SPDTheme.brand).frame(width: 18)
            Text(name).font(SPDTheme.Typo.callout).lineLimit(1).frame(width: 190, alignment: .leading)
            GeometryReader { g in Capsule().fill(SPDTheme.brand.opacity(0.75)).frame(width: max(3, g.size.width * CGFloat(bytes) / CGFloat(top))) }.frame(height: 8)
            Text("\(Fmt.bytes(bytes)) · \(files)").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).monospacedDigit().frame(width: 120, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(SPDTheme.textTertiary).opacity(chevron ? 1 : 0)
        }.contentShape(Rectangle())
    }
    private func card<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: symbol).font(SPDTheme.Typo.headline); content() }.frame(maxWidth: .infinity, alignment: .leading).spdCard()
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(value).font(SPDTheme.Typo.figure); Text(label).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary) }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func load() async {
        guard let next = model.next else { return }
        do { overview = .ready(try await next.storageOverview()) } catch { if overview.value == nil { overview = .failed(NextText.error(error)) } }
        if folder?.value == nil { await drill("root") }
        await loadDuplicates()
    }
    private func drill(_ id: String) async {
        guard let next = model.next else { return }
        do { folder = .ready(try await next.storageFolder(id)) } catch { folder = .failed(NextText.error(error)) }
    }
    private func loadDuplicates() async {
        guard let next = model.next else { return }
        do { duplicates = .ready(try await next.duplicates(similar ? .similarImages : .exact)) } catch { duplicates = .failed(NextText.error(error)) }
    }
}
extension NextText {
    /// The storage kind of a file, from its extension (the same eight kinds as the server's breakdown).
    static func kindOf(_ f: NextFile) -> String {
        let e = f.fileExtension
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg"].contains(e) { return "image" }
        if e == "pdf" { return "pdf" }
        if ["doc", "docx", "odt", "rtf", "pages", "ppt", "pptx", "odp", "key"].contains(e) { return "document" }
        if ["xls", "xlsx", "ods", "csv", "numbers", "tsv"].contains(e) { return "sheet" }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(e) { return "video" }
        if ["mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff"].contains(e) { return "audio" }
        if ["zip", "tar", "gz", "7z", "rar", "bz2", "xz", "dmg"].contains(e) { return "archive" }
        if ["txt", "md", "json", "xml", "yaml", "yml", "html", "log", "tex"].contains(e) { return "text" }
        return "other"
    }
}
