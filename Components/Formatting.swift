// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Components/Formatting.swift
// Description: Shared formatting (sizes, dates, speeds), file icons from the system, and small reusable views: status badges, empty states, the banner.
import AppKit
import SPDriveCore
import SPDriveSync
import SwiftUI
import UniformTypeIdentifiers

enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func speed(_ bps: Double) -> String { bps < 1 ? "" : "\(ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file))/s" }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
    static func relative(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }
    /// Date without the time (grid captions, pills).
    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    /// A time left, rounded the way a person says it: "8 s", "3 min", "1 h 20".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) min" }
        if s < 86400 { return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60))" }
        return "\(s / 86400) j"
    }
    static func kind(_ item: DriveItem) -> String {
        if item.isFolder { return "Dossier" }
        if let t = UTType(filenameExtension: item.fileExtension), let d = t.localizedDescription { return d.prefix(1).uppercased() + d.dropFirst() }
        return item.fileExtension.isEmpty ? "Document" : "Fichier \(item.fileExtension.uppercased())"
    }
}

/// The icon the Finder would show for this kind of item.
struct ItemIcon: View {
    let item: DriveItem
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: ItemIcon.image(for: item))
            .resizable().interpolation(.high).frame(width: size, height: size)
            .opacity(item.id.hasPrefix(OperationJournal.localPrefix) ? 0.6 : 1)
            .accessibilityHidden(true)
    }
    static func image(for item: DriveItem) -> NSImage {
        if item.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: item.fileExtension) ?? .data)
    }
}

/// Small symbols after a name: offline, on this Mac, shared, favourite, waiting to be sent, antivirus.
struct ItemBadges: View {
    let model: AppModel   // given explicitly: table cells are hosted outside the SwiftUI environment
    let item: DriveItem
    var body: some View {
        HStack(spacing: 5) {
            if model.isPending(item.id) { badge("arrow.triangle.2.circlepath", "En attente d’envoi au serveur", SPDTheme.warning) }
            if item.starred { badge("star.fill", "Favori", SPDTheme.warning) }
            if model.sharedIDs.contains(item.id) { badge("link", "Partagé par un lien", SPDTheme.brand) }
            if model.isPinned(item.id) { badge("arrow.down.circle.fill", "Disponible hors ligne", SPDTheme.positive) }
            else if !item.isFolder, model.isLocal(item.id) { badge("checkmark.circle", "Copie sur ce Mac", SPDTheme.textSecondary) }
            if item.scan == "infected" { badge("exclamationmark.shield.fill", "Bloqué par l’antivirus", SPDTheme.critical) }
        }
        .font(.caption)
    }
    private func badge(_ symbol: String, _ label: String, _ color: Color) -> some View {
        Image(systemName: symbol).foregroundStyle(color).help(label).accessibilityLabel(label)
    }
}

struct SyncStateLabel: View {
    let model: AppModel
    let item: DriveItem
    var body: some View {
        let (symbol, text): (String, String) = {
            if model.isPending(item.id) { return ("arrow.triangle.2.circlepath", "En attente") }
            if item.isTrashed { return ("trash", "Corbeille") }
            if model.isPinned(item.id) { return ("arrow.down.circle.fill", "Hors ligne") }
            if !item.isFolder, model.isLocal(item.id) { return ("checkmark.circle", "Sur ce Mac") }
            return ("cloud", "Sur SP Drive")
        }()
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon).foregroundStyle(.secondary)
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let b = model.banner {
            HStack(spacing: 10) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "info.circle.fill").foregroundStyle(b.isError ? SPDTheme.warning : SPDTheme.brand)
                Text(b.text).font(.callout).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 8)
                Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Fermer le message")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SPDTheme.hairline))
            .spdElevation(.e2)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: b.id) { try? await Task.sleep(nanoseconds: 9_000_000_000); if model.banner?.id == b.id { withAnimation { model.banner = nil } } }
        }
    }
}

/// The SP Drive mark, drawn in SwiftUI: a calm two-tone tile (indigo to violet, the kinship with the web app) — no gloss, no heavy gradient.
struct DriveMark: View {
    var size: CGFloat = 84
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [SPDTheme.brandIndigo, SPDTheme.brand], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "folder.fill").font(.system(size: size * 0.5, weight: .regular)).foregroundStyle(.white.opacity(0.96))
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: size * 0.2, weight: .bold)).foregroundStyle(SPDTheme.Palette.brand.color).offset(y: size * 0.05).environment(\.colorScheme, .light)
        }
        .frame(width: size, height: size).spdElevation(size > 40 ? .e2 : .e1)
        .accessibilityHidden(true)
    }
}
