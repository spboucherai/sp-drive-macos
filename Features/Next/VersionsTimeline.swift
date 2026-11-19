// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/VersionsTimeline.swift
// Description: The versions of a file as a timeline: who added each one and when, download, restore (which adds a version — history only grows), delete an old one, and compare any version with the current one: a line diff for text, Markdown, JSON and CSV; side by side for images and PDF; a plain statement of what differs for other formats.
import PDFKit
import SPDriveCore
import SPDriveNext
import SwiftUI

/// A line-based difference (longest common subsequence), for files of reasonable size.
enum LineDiff {
    enum Kind { case same, removed, added }
    struct Line: Identifiable { let id: Int; let kind: Kind; let text: String }
    static let maxLines = 4000
    static func lines(_ a: String, _ b: String) -> [Line]? {
        let x = a.components(separatedBy: .newlines), y = b.components(separatedBy: .newlines)
        guard x.count <= maxLines, y.count <= maxLines else { return nil }
        var t = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        if !x.isEmpty, !y.isEmpty { for i in stride(from: x.count - 1, through: 0, by: -1) { for j in stride(from: y.count - 1, through: 0, by: -1) { t[i][j] = x[i] == y[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1]) } } }
        var out: [Line] = [], i = 0, j = 0, n = 0
        func add(_ k: Kind, _ s: String) { out.append(Line(id: n, kind: k, text: s)); n += 1 }
        while i < x.count, j < y.count {
            if x[i] == y[j] { add(.same, x[i]); i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { add(.removed, x[i]); i += 1 }
            else { add(.added, y[j]); j += 1 }
        }
        while i < x.count { add(.removed, x[i]); i += 1 }
        while j < y.count { add(.added, y[j]); j += 1 }
        return out
    }
}

struct VersionsTimeline: View {
    let model: AppModel
    let nav: Navigator
    let item: DriveItem
    @Environment(\.dismiss) private var dismiss
    @State private var list: Loadable<VersionList> = .loading
    @State private var compare: VersionInfo?
    @State private var busy = false
    @State private var note: String?
    @State private var confirmDelete: VersionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SPDTheme.Space.md) {
                ItemThumbnail(model: model, item: item, side: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Versions de « \(item.name) »").font(SPDTheme.Typo.title).lineLimit(1).truncationMode(.middle)
                    Text("Restaurer une version en crée une nouvelle : l’historique ne fait que grandir.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
                }
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(SPDTheme.Space.lg)
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            HSplitView {
                timeline.frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
                Group {
                    if let v = compare, let current = list.value?.versions.first(where: \.current) { VersionCompare(model: model, item: item, old: v, current: current).id(v.id) }
                    else { SPDEmptyState(symbol: "arrow.left.arrow.right", title: "Comparer", message: "Choisissez « Comparer » sur une version ancienne pour la voir à côté de la version actuelle.", width: 300) }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let note { Label(note, systemImage: "exclamationmark.triangle").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.critical).padding(SPDTheme.Space.md) }
        }
        .frame(width: 940, height: 620).background(SPDTheme.surface)
        .task {
            await reload()
            #if SPD_DEV
            if UserDefaults.standard.bool(forKey: "spdCompare") { compare = list.value?.versions.first { !$0.current } } // visual checks
            #endif
        }
        .confirmationDialog("Supprimer la version \(confirmDelete?.seq ?? 0) ?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Supprimer cette version", role: .destructive) { if let v = confirmDelete { Task { await delete(v) } } }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Cette version sera effacée définitivement. Les autres versions et le fichier ne changent pas.") }
        .accessibilityIdentifier("versions-timeline")
    }
    @ViewBuilder private var timeline: some View {
        switch list {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m): SPDEmptyState(symbol: "wifi.slash", title: "Historique indisponible", message: m, width: 260) { Button("Réessayer") { Task { await reload() } } }
        case .ready(let l):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(l.versions.enumerated()), id: \.element.id) { i, v in
                        HStack(alignment: .top, spacing: SPDTheme.Space.md) {
                            VStack(spacing: 0) {
                                Circle().fill(v.current ? SPDTheme.brand : SPDTheme.surfaceRaised).overlay(Circle().strokeBorder(v.current ? SPDTheme.brand : SPDTheme.textTertiary, lineWidth: 1.5)).frame(width: 11, height: 11).padding(.top, 4)
                                if i < l.versions.count - 1 { Rectangle().fill(SPDTheme.hairline).frame(width: 1.5).frame(maxHeight: .infinity) }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) { Text("Version \(v.seq)").font(SPDTheme.Typo.bodyStrong); if v.current { SPDPill(text: "Actuelle", tint: SPDTheme.brand) }; if compare?.id == v.id { SPDPill(text: "Comparée", symbol: "arrow.left.arrow.right") } }
                                Text("\(Fmt.date(v.createdAt)) · \(Fmt.bytes(v.size))\(delta(v, l.versions))").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                                Text(author(v) + ((v.note ?? "").isEmpty ? "" : " · \(note(v))")).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
                                HStack(spacing: SPDTheme.Space.sm) {
                                    if !v.current { Button("Comparer") { compare = v }.accessibilityIdentifier("compare-\(v.seq)") ; Button("Restaurer") { Task { await restore(v) } }.disabled(busy) }
                                    Button { Task { if let d = try? await model.api?.fileDetails(item.id), let fv = d.versions.first(where: { $0.id == v.id }) { await model.download([item], version: fv) } } } label: { Image(systemName: "arrow.down.circle") }.help("Télécharger cette version").accessibilityLabel("Télécharger la version \(v.seq)")
                                    if !v.current { Button(role: .destructive) { confirmDelete = v } label: { Image(systemName: "trash") }.help("Supprimer cette version").accessibilityLabel("Supprimer la version \(v.seq)") }
                                }.controlSize(.small).padding(.top, 2)
                            }.padding(.bottom, SPDTheme.Space.lg)
                        }
                    }
                }.padding(SPDTheme.Space.lg)
            }
        }
    }
    private func author(_ v: VersionInfo) -> String { v.createdBy.map { $0.me == true ? "Par vous" : "Par \($0.displayName ?? "un membre")" } ?? "Reçue par un lien de dépôt" }
    private func note(_ v: VersionInfo) -> String {
        let n = v.note ?? ""
        if n.hasPrefix("restored from version "), let seq = Int(n.dropFirst("restored from version ".count)) { return "restauration de la version \(seq)" }
        return n
    }
    private func delta(_ v: VersionInfo, _ all: [VersionInfo]) -> String {
        guard let prev = all.first(where: { $0.seq == v.seq - 1 }) else { return "" }
        let d = v.size - prev.size
        return d == 0 ? (v.sha256 == prev.sha256 ? " · identique à la précédente" : " · même taille") : " · \(d > 0 ? "+" : "−")\(Fmt.bytes(abs(d)))"
    }
    private func reload() async {
        guard let next = model.next else { return }
        do { list = .ready(try await next.versions(of: item.id)); note = nil } catch { if list.value == nil { list = .failed(NextText.error(error)) } else { note = NextText.error(error) } }
    }
    private func restore(_ v: VersionInfo) async {
        guard let next = model.next else { return }
        busy = true; defer { busy = false }
        do { _ = try await next.restoreVersion(fileID: item.id, versionID: v.id); compare = nil; await model.syncNow(); await reload() } catch { note = NextText.error(error) }
    }
    private func delete(_ v: VersionInfo) async {
        do { try await model.api?.deleteVersion(fileID: item.id, versionID: v.id); if compare?.id == v.id { compare = nil }; await reload() } catch { note = DriveError.wrap(error).errorDescription }
    }
}

/// An old version next to the current one.
struct VersionCompare: View {
    enum Mode { case text([LineDiff.Line]), images(NSImage, NSImage), pdf(PDFDocument, PDFDocument), statement(String) }
    let model: AppModel
    let item: DriveItem
    let old: VersionInfo
    let current: VersionInfo
    @State private var mode: Loadable<Mode> = .loading
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml", "html", "css", "js", "ts", "swift", "py", "sh", "log", "ini", "toml", "tex", "srt"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]
    static let maxBytes: Int64 = 40 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Version \(old.seq)").font(SPDTheme.Typo.bodyStrong); Text(Fmt.date(old.createdAt)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
                Spacer(); Image(systemName: "arrow.right").foregroundStyle(SPDTheme.textTertiary); Spacer()
                Text("Version \(current.seq) (actuelle)").font(SPDTheme.Typo.bodyStrong); Text(Fmt.date(current.createdAt)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
            }.padding(SPDTheme.Space.md)
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            switch mode {
            case .loading: ProgressView("Récupération des deux versions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m): SPDEmptyState(symbol: "exclamationmark.triangle", title: "Comparaison impossible", message: m, width: 320)
            case .ready(.statement(let s)): SPDEmptyState(symbol: "equal.circle", title: "Pas d’aperçu comparé", message: s, width: 340)
            case .ready(.text(let lines)):
                let added = lines.filter { $0.kind == .added }.count, removed = lines.filter { $0.kind == .removed }.count
                Text(added + removed == 0 ? "Aucune ligne ne diffère." : "\(added) ligne\(added > 1 ? "s" : "") ajoutée\(added > 1 ? "s" : ""), \(removed) retirée\(removed > 1 ? "s" : "")").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).padding(.horizontal, SPDTheme.Space.md).padding(.top, SPDTheme.Space.sm)
                    .accessibilityIdentifier("diff-summary")
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { l in
                            HStack(spacing: 6) {
                                Text(l.kind == .added ? "+" : l.kind == .removed ? "−" : " ").frame(width: 12)
                                Text(l.text.isEmpty ? " " : l.text).fixedSize(horizontal: true, vertical: false) // a line of a file is a line here: scroll sideways rather than wrap
                            }
                            .font(SPDTheme.Typo.mono).foregroundStyle(l.kind == .same ? SPDTheme.textSecondary : SPDTheme.textPrimary)
                            .padding(.horizontal, SPDTheme.Space.sm).padding(.vertical, 1).frame(maxWidth: .infinity, alignment: .leading)
                            .background(l.kind == .added ? SPDTheme.positive.opacity(0.14) : l.kind == .removed ? SPDTheme.critical.opacity(0.12) : .clear)
                            .accessibilityLabel((l.kind == .added ? "Ajouté : " : l.kind == .removed ? "Retiré : " : "") + l.text)
                        }
                    }.padding(.vertical, SPDTheme.Space.sm).frame(minWidth: 480, maxWidth: .infinity, alignment: .leading)
                }.textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .ready(.images(let a, let b)):
                HStack(spacing: SPDTheme.Space.md) { picture(a); picture(b) }.padding(SPDTheme.Space.md)
            case .ready(.pdf(let a, let b)):
                HStack(spacing: 1) { PDFPane(document: a); PDFPane(document: b) }
            }
        }
        .task { await load() }
    }
    private func picture(_ img: NSImage) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity).background(SPDTheme.sunken, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md))
            Text("\(Int(img.representations.first?.pixelsWide ?? Int(img.size.width))) × \(Int(img.representations.first?.pixelsHigh ?? Int(img.size.height))) px").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
        }
    }
    private func load() async {
        guard let next = model.next else { return }
        let ext = item.fileExtension.lowercased()
        let facts = "Version \(old.seq) : \(Fmt.bytes(old.size)), empreinte \(old.sha256.prefix(12))…\nVersion \(current.seq) : \(Fmt.bytes(current.size)), empreinte \(current.sha256.prefix(12))…"
        if old.sha256 == current.sha256 { mode = .ready(.statement("Les deux versions ont exactement le même contenu (même empreinte SHA-256).")); return }
        let kind = VersionCompare.textExtensions.contains(ext) ? "text" : VersionCompare.imageExtensions.contains(ext) ? "image" : ext == "pdf" ? "pdf" : "other"
        guard kind != "other" else { mode = .ready(.statement("Ce format ne se compare pas visuellement. Les contenus diffèrent :\n\(facts)\nTéléchargez les deux versions pour les ouvrir dans leur application.")); return }
        guard max(old.size, current.size) <= VersionCompare.maxBytes else { mode = .ready(.statement("Versions trop volumineuses pour être comparées ici (plus de 40 Mo).\n\(facts)")); return }
        do {
            let dir = model.cacheDirectory.appendingPathComponent("versions/\(item.id)", isDirectory: true)
            func fetch(_ v: VersionInfo) async throws -> URL {
                let url = dir.appendingPathComponent("\(v.id).\(ext.isEmpty ? "bin" : ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
                let sha = try await next.downloadVersion(fileID: item.id, versionID: v.id, to: url)
                guard sha == v.sha256 else { try? FileManager.default.removeItem(at: url); throw NextError.invalidResponse("empreinte différente") } // never show bytes that are not that version
                return url
            }
            let a = try await fetch(old), b = try await fetch(current)
            switch kind {
            case "text":
                guard let x = try? String(contentsOf: a, encoding: .utf8), let y = try? String(contentsOf: b, encoding: .utf8) else { mode = .ready(.statement("Ces versions ne sont pas du texte UTF-8 lisible.\n\(facts)")); return }
                if let lines = LineDiff.lines(x, y) { mode = .ready(.text(lines)) } else { mode = .ready(.statement("Fichier trop long pour une comparaison ligne à ligne (plus de \(LineDiff.maxLines) lignes).\n\(facts)")) }
            case "image":
                guard let x = NSImage(contentsOf: a), let y = NSImage(contentsOf: b) else { mode = .ready(.statement("Image illisible.\n\(facts)")); return }
                mode = .ready(.images(x, y))
            default:
                guard let x = PDFDocument(url: a), let y = PDFDocument(url: b) else { mode = .ready(.statement("PDF illisible ou protégé.\n\(facts)")); return }
                mode = .ready(.pdf(x, y))
            }
        } catch { mode = .failed(NextText.error(error)) }
    }
}
private struct PDFPane: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.document = document; v.backgroundColor = .clear; return v }
    func updateNSView(_ v: PDFView, context: Context) { if v.document !== document { v.document = document } }
}
