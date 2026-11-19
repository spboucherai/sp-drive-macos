// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/ActivityViews.swift
// Description: Activity: what really happened to a file (inspector), in a shared folder, and across the account — read from the server's audit trail, newest first, paged. Nothing is inferred: an event that was not recorded is not shown.
import SPDriveCore
import SPDriveNext
import SwiftUI

struct ActivityRow: View {
    let event: ActivityEvent
    var compact = false
    /// Name what the event is about (lists that mix several items; a file's own feed does not need it).
    var showsTarget = false
    var body: some View {
        let (symbol, text) = NextText.activity(event)
        HStack(alignment: .firstTextBaseline, spacing: SPDTheme.Space.sm) {
            Image(systemName: symbol).foregroundStyle(SPDTheme.brand).frame(width: 18).font(compact ? SPDTheme.Typo.caption : SPDTheme.Typo.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(showsTarget ? [event.target?.name.map { "« \($0) »" }, text].compactMap { $0 }.joined(separator: " — ") : text).font(compact ? SPDTheme.Typo.callout : SPDTheme.Typo.body).lineLimit(2)
                HStack(spacing: 4) {
                    Text(NextText.actor(event))
                    if event.viaGrant { Text("· par le partage") }
                    Text("· \(compact ? Fmt.relative(event.at) : Fmt.date(event.at))")
                }.font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The last events of one file, in the inspector.
struct FileActivitySection: View {
    let model: AppModel
    let item: DriveItem
    @State private var page: Loadable<ActivityPage> = .loading
    var body: some View {
        VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
            switch page {
            case .loading: ProgressView().controlSize(.small)
            case .failed(let m): Text(m).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
            case .ready(let p):
                if p.events.isEmpty { Text("Aucun événement enregistré.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) }
                ForEach(p.events.prefix(6)) { ActivityRow(event: $0, compact: true) }
                if p.more || p.events.count > 6 { Text("Les événements plus anciens sont dans Activité.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary) }
            }
        }
        .task(id: "\(item.id)|\(item.rev)|\(model.online)") {
            guard let next = model.next, !model.isPending(item.id) else { return }
            do { page = .ready(try await (item.isFolder ? next.folderActivity(item.id, limit: 7) : next.fileActivity(item.id, limit: 7))) }
            catch { page = .failed(NextError.wrap(error).code == "offline" ? "Disponible une fois en ligne." : NextText.error(error)) }
        }
    }
}

/// The account's timeline.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var events: [ActivityEvent] = []
    @State private var more = false
    @State private var state: Loadable<Bool> = .loading
    @State private var loadingMore = false
    var body: some View {
        Group {
            switch state {
            case .loading: ProgressView()
            case .failed(let m): SPDEmptyState(symbol: "wifi.slash", title: "Activité indisponible", message: m) { Button("Réessayer") { Task { await reload() } } }
            case .ready:
                if events.isEmpty { SPDEmptyState(symbol: "clock.arrow.circlepath", title: "Aucune activité", message: "Les ajouts, modifications, partages et suppressions de votre Drive apparaîtront ici, d’où qu’ils viennent.") }
                else {
                    List {
                        ForEach(grouped, id: \.day) { g in
                            Section(g.day) {
                                ForEach(g.events) { e in
                                    HStack {
                                        ActivityRow(event: e, showsTarget: true)
                                        Spacer()
                                        if let id = target(e), model.item(id) != nil { Button("Afficher") { model.reveal(itemID: id) }.buttonStyle(.link) }
                                    }.padding(.vertical, 2)
                                }
                            }
                        }
                        if more { Button(loadingMore ? "Chargement…" : "Afficher les événements plus anciens") { Task { await loadMore() } }.disabled(loadingMore).frame(maxWidth: .infinity) }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle("Activité").navigationSubtitle("Journal du compte")
        .toolbar { ToolbarItem { Button { Task { await reload() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") } } }
        .task(id: model.revision) { await reload() }
        .accessibilityIdentifier("activity-view")
    }
    private var grouped: [(day: String, events: [ActivityEvent])] {
        var out: [(String, [ActivityEvent])] = []
        for e in events {
            let d = Calendar.current.isDateInToday(e.at) ? "Aujourd’hui" : Calendar.current.isDateInYesterday(e.at) ? "Hier" : e.at.formatted(date: .complete, time: .omitted)
            if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
        }
        return out.map { (day: $0.0, events: $0.1) }
    }
    private func target(_ e: ActivityEvent) -> String? {
        if let t = e.target, ["file", "folder"].contains(t.type) { return t.id }
        return e.meta?["fileIds"]?.array?.first?.string ?? e.meta?["folderIds"]?.array?.first?.string
    }
    private func reload() async {
        guard let next = model.next else { return }
        do { let p = try await next.accountActivity(limit: 80); events = p.events; more = p.more; state = .ready(true) }
        catch { if events.isEmpty { state = .failed(NextText.error(error)) } }
    }
    private func loadMore() async {
        guard let next = model.next, let last = events.last else { return }
        loadingMore = true; defer { loadingMore = false }
        if let p = try? await next.accountActivity(before: last.id, limit: 80) { events += p.events; more = p.more }
    }
}
