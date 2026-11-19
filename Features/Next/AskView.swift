// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Next/AskView.swift
// Description: SP Drive AI: ask one document, a folder, or the whole Drive. The answer is streamed; it is built by the server from passages it retrieved in your own files, which are listed with it and cited as [n] — each citation opens its file. The model is chosen in a picker that tells who made it from which service routes to it. Clear states when nothing is configured and when nothing was retrieved.
import AppKit
import SPDriveCore
import SPDriveNext
import SwiftUI

/// One exchange of the conversation.
struct AskTurn: Identifiable {
    let id = UUID()
    var question: String
    init(question: String) { self.question = question }
    var answer = ""
    var sources: [AISource] = []
    var unindexed: [AIUnindexed] = []
    var done: AIDone?
    var failure: String?
    var streaming = true
}

@MainActor @Observable final class AskSession {
    var turns: [AskTurn] = []
    var providers: Loadable<AIProviders> = .loading
    var choice: AIProviders.Choice?
    var question = ""
    private var task: Task<Void, Never>?
    var busy: Bool { turns.last?.streaming == true }

    func load(_ model: AppModel) async {
        guard let next = model.next else { providers = .failed("Non connecté."); return }
        do { let p = try await next.aiProviders(); providers = .ready(p); if choice == nil || !usable(p).contains(where: { $0 == choice }) { choice = p.default } }
        catch { providers = .failed(NextText.error(error)) }
    }
    /// Every (provider, model) pair this account may use.
    func usable(_ p: AIProviders) -> [AIProviders.Choice] { p.providers.filter { $0.usable == true }.flatMap { pr in pr.models.map { AIProviders.Choice(provider: pr.id, model: $0.id) } } }
    func ask(_ model: AppModel, scope: AIScope) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, let next = model.next else { return }
        question = ""
        let history = turns.filter { $0.failure == nil && !$0.answer.isEmpty }.suffix(5).flatMap { [AITurn(role: "user", content: $0.question), AITurn(role: "assistant", content: $0.answer)] }
        turns.append(AskTurn(question: q))
        let index = turns.count - 1
        let request = AIAskRequest(scope: scope, question: q, provider: choice?.provider, model: choice?.model, history: Array(history))
        task = Task {
            do {
                for try await event in next.aiAsk(request) {
                    switch event {
                    case .notice(let u): turns[index].unindexed = u
                    case .sources(let s): turns[index].sources = s
                    case .delta(let t): turns[index].answer += t
                    case .done(let d): turns[index].done = d
                    case .error(let code, _): turns[index].failure = NextText.error(NextError.server(status: 502, code: code, message: "", extra: [:]))
                    }
                }
            } catch { if NextError.wrap(error) != .cancelled { turns[index].failure = NextText.error(error) } }
            turns[index].streaming = false
        }
    }
    func stop() { task?.cancel(); if let i = turns.indices.last { turns[i].streaming = false } }
    func reset() { stop(); turns = [] }
}

struct AskView: View {
    let model: AppModel
    let nav: Navigator?
    /// nil = the whole Drive.
    let item: DriveItem?
    var onOpen: (() -> Void)?
    /// Shown as a sheet: a way out.
    var onClose: (() -> Void)?
    @State private var session = AskSession()
    @FocusState private var focused: Bool

    private var scope: AIScope { item.map { $0.isFolder ? ($0.isRoot ? .all : .folder($0.id)) : .files([$0.id]) } ?? .all }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            switch session.providers {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m): SPDEmptyState(symbol: "wifi.slash", title: "SP Drive AI indisponible", message: m, width: 360) { Button("Réessayer") { Task { await session.load(model) } } }
            case .ready(let p):
                if !p.enabled { unconfigured(p) } else { conversation; composer(p) }
            }
        }
        .background(SPDTheme.surface)
        .task {
            await session.load(model); focused = true
            #if SPD_DEV
            if let q = UserDefaults.standard.string(forKey: "spdAsk"), session.turns.isEmpty { session.question = q; session.ask(model, scope: scope) } // visual checks
            #endif
        }
        .accessibilityIdentifier("ask-view")
    }
    private var header: some View {
        HStack(spacing: SPDTheme.Space.sm) {
            Image(systemName: "sparkles").foregroundStyle(SPDTheme.brand).font(.title3)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.map { $0.isRoot ? "Demander à mon Drive" : "Demander à « \($0.name) »" } ?? "Demander à mon Drive").font(SPDTheme.Typo.headline).lineLimit(1).truncationMode(.middle)
                Text(item.map { $0.isFolder ? "Les réponses viennent des documents de ce dossier." : "Les réponses viennent de ce document seulement." } ?? "Les réponses viennent de vos propres documents indexés.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary)
            }
            Spacer()
            if !session.turns.isEmpty { Button("Nouvelle conversation", systemImage: "square.and.pencil") { session.reset() }.labelStyle(.iconOnly).help("Nouvelle conversation") }
            if let onClose { Button("Terminé") { session.stop(); onClose() }.keyboardShortcut(.cancelAction) }
        }
        .padding(SPDTheme.Space.md)
    }
    /// No usable model: say exactly why, and what would change it.
    private func unconfigured(_ p: AIProviders) -> some View {
        let external = p.providers.filter { !$0.local && $0.configured }
        let message: String
        if !external.isEmpty, p.external?.server == true, p.external?.account == false { message = "Le serveur propose un fournisseur externe (\(external.map(\.label).joined(separator: ", "))), mais votre compte ne l’a pas autorisé. Vous pouvez l’autoriser dans Paramètres › Compte : des passages de vos documents seront alors envoyés à ce fournisseur pour chaque question." }
        else if !external.isEmpty, p.external?.server == false { message = "Un fournisseur externe est configuré mais l’administrateur du serveur ne l’a pas activé, et aucun modèle local n’est disponible." }
        else { message = "Aucun modèle n’est configuré sur ce serveur. La recherche dans le contenu fonctionne sans modèle ; les questions en langage naturel demandent qu’un administrateur en configure un." }
        return SPDEmptyState(symbol: "sparkles", title: "Aucun modèle disponible", message: message, width: 380)
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SPDTheme.Space.lg) {
                    if session.turns.isEmpty {
                        VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
                            Text("Posez une question").font(SPDTheme.Typo.title)
                            Text("SP Drive cherche d’abord les passages utiles dans vos documents indexés, puis demande au modèle de répondre à partir de ces passages seulement. Chaque affirmation renvoie à sa source par un numéro.").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary).frame(maxWidth: 460, alignment: .leading)
                            FlowRow(spacing: SPDTheme.Space.xs) {
                                ForEach(item?.isFolder == false ? ["Résume ce document", "Quelles sont les dates importantes ?", "Quels montants sont mentionnés ?"] : ["Quels documents parlent de budget ?", "Que dit le dernier compte rendu ?"], id: \.self) { s in
                                    Button(s) { session.question = s; session.ask(model, scope: scope) }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                        .padding(.top, SPDTheme.Space.md)
                    }
                    ForEach(session.turns) { t in TurnView(model: model, nav: nav, turn: t, onOpen: onOpen, providers: session.providers.value).id(t.id) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(SPDTheme.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.turns.last?.answer) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: session.turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
    private func composer(_ p: AIProviders) -> some View {
        @Bindable var session = session
        return VStack(spacing: SPDTheme.Space.xs) {
            Rectangle().fill(SPDTheme.hairline).frame(height: 1)
            HStack(alignment: .bottom, spacing: SPDTheme.Space.sm) {
                TextField("Votre question…", text: $session.question, axis: .vertical).lineLimit(1...4).textFieldStyle(.plain).font(SPDTheme.Typo.body).focused($focused)
                    .padding(SPDTheme.Space.sm).background(SPDTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous).strokeBorder(SPDTheme.hairline))
                    .onSubmit { session.ask(model, scope: scope) }.accessibilityIdentifier("ask-field")
                if session.busy { Button { session.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }.buttonStyle(.plain).foregroundStyle(SPDTheme.textSecondary).help("Arrêter la réponse") }
                else { Button { session.ask(model, scope: scope) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).foregroundStyle(SPDTheme.brand).disabled(session.question.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction).help("Envoyer") }
            }
            HStack {
                ModelPicker(providers: p, choice: $session.choice, options: session.usable(p))
                Spacer()
                Text("Une réponse de modèle peut se tromper : vérifiez dans les sources.").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary)
            }
        }
        .padding(.horizontal, SPDTheme.Space.md).padding(.bottom, SPDTheme.Space.md)
    }
}

/// Model picker: each entry names the model and who made it; the provider (the route to it) is shown apart, with a mark for local versus external.
struct ModelPicker: View {
    let providers: AIProviders
    @Binding var choice: AIProviders.Choice?
    let options: [AIProviders.Choice]
    private func provider(_ id: String) -> AIProvider? { providers.providers.first { $0.id == id } }
    private func model(_ c: AIProviders.Choice) -> AIModel? { provider(c.provider)?.models.first { $0.id == c.model } }
    var body: some View {
        Menu {
            ForEach(providers.providers.filter { $0.usable == true }) { pr in
                Section("\(pr.label) — \(pr.local ? "sur l’infrastructure MacLustr" : "fournisseur externe")") {
                    ForEach(pr.models) { m in
                        Button { choice = .init(provider: pr.id, model: m.id) } label: {
                            Label("\(m.label)\(m.creator.map { " · conçu par \($0)" } ?? "")", systemImage: choice == .init(provider: pr.id, model: m.id) ? "checkmark" : (pr.local ? "lock.shield" : "globe"))
                        }
                    }
                }
            }
            let off = providers.providers.filter { $0.usable != true && $0.configured }
            if !off.isEmpty { Section("Non autorisés pour ce compte") { ForEach(off) { Text($0.label) } } }
        } label: {
            if let c = choice, let pr = provider(c.provider) {
                // one label: the model, who made it, and — apart — the service that routes to it
                Label("\(model(c)?.label ?? c.model)\(model(c)?.creator.map { " · conçu par \($0)" } ?? "")  —  via \(pr.label)", systemImage: pr.local ? "lock.shield" : "globe").font(SPDTheme.Typo.caption)
            } else { Text("Choisir un modèle").font(SPDTheme.Typo.caption) }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Le modèle (et qui l’a conçu) est une chose ; le fournisseur, c’est-à-dire le service qui y donne accès, en est une autre.")
        .accessibilityIdentifier("model-picker")
    }
}

private struct TurnView: View {
    let model: AppModel
    let nav: Navigator?
    let turn: AskTurn
    var onOpen: (() -> Void)?
    var providers: AIProviders?
    /// "Qwen3 30B (Alibaba) · via MacLustr (local)": labels, not identifiers.
    private func signature(_ d: AIDone) -> String {
        let pr = providers?.providers.first { $0.id == d.provider }, m = pr?.models.first { $0.id == d.model }
        return [m.map { $0.label + ($0.creator.map { " (\($0))" } ?? "") } ?? d.model, (pr?.label ?? d.provider).map { "via \($0)" }, d.usage?.outputTokens.map { "\($0) jetons" }].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: SPDTheme.Space.sm) {
            Text(turn.question).font(SPDTheme.Typo.bodyStrong).padding(.horizontal, SPDTheme.Space.md).padding(.vertical, SPDTheme.Space.sm)
                .background(SPDTheme.brandWash, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous)).frame(maxWidth: .infinity, alignment: .trailing)
            if !turn.unindexed.isEmpty {
                Label("Non pris en compte, faute de texte indexé : \(turn.unindexed.map(\.name).joined(separator: ", ")).", systemImage: "doc.questionmark").font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.warning)
            }
            if let failure = turn.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.critical)
            } else if turn.done?.empty == true {
                Label("Rien, dans ces documents, ne correspond à la question : le modèle n’a pas été interrogé.", systemImage: "magnifyingglass").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary)
            } else {
                if turn.answer.isEmpty && turn.streaming { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(turn.sources.isEmpty ? "Recherche des passages…" : "Le modèle répond…").font(SPDTheme.Typo.callout).foregroundStyle(SPDTheme.textSecondary) } }
                else { CitedText(text: turn.answer, sources: turn.sources) { open($0) }.textSelection(.enabled) }
                if !turn.sources.isEmpty {
                    VStack(alignment: .leading, spacing: SPDTheme.Space.xs) {
                        Text("Sources").spdEyebrow()
                        ForEach(turn.sources) { s in
                            Button { open(s) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: SPDTheme.Space.sm) {
                                    Text("\(s.n)").font(SPDTheme.Typo.caption.weight(.semibold)).foregroundStyle(SPDTheme.onBrand).frame(width: 17, height: 17).background(SPDTheme.brand, in: Circle())
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.name + (s.page.map { " — p. \($0)" } ?? "")).font(SPDTheme.Typo.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                        Text(s.text).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textSecondary).lineLimit(2)
                                    }
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Afficher « \(s.name) » dans SP Drive").accessibilityLabel("Source \(s.n) : \(s.name)")
                        }
                    }
                    .padding(SPDTheme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
                    .background(SPDTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous)).overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.md, style: .continuous).strokeBorder(SPDTheme.hairline))
                }
                if let d = turn.done, !turn.streaming { Text(signature(d)).font(SPDTheme.Typo.caption).foregroundStyle(SPDTheme.textTertiary) }
            }
        }
    }
    private func open(_ s: AISource) {
        guard let nav = nav ?? model.activeNav ?? Optional(model.nav) else { return }
        if let item = model.item(s.fileId) { nav.sheet = nil; nav.searchText = ""; nav.go(to: item.parentID == model.rootID ? nil : item.parentID); nav.selection = [item.id]; AppDelegate.showMainWindow(); onOpen?() }
        else { model.banner = Banner(text: "« \(s.name) » n’est pas encore dans la copie locale de votre Drive.", isError: false) }
    }
}

/// The answer with its [n] citations turned into links to the sources.
struct CitedText: View {
    let text: String
    let sources: [AISource]
    let open: (AISource) -> Void
    var body: some View {
        Text(attributed).font(SPDTheme.Typo.body).foregroundStyle(SPDTheme.textPrimary).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "spd-source", let n = Int(url.host ?? ""), let s = sources.first(where: { $0.n == n }) { open(s); return .handled }
                return .systemAction
            })
    }
    private var attributed: AttributedString {
        var out = AttributedString(), rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            out.append(AttributedString(String(rest[..<open])))
            guard let close = rest[open...].firstIndex(of: "]") else { rest = rest[open...]; break }
            if let n = Int(rest[rest.index(after: open)..<close]), sources.contains(where: { $0.n == n }) {
                var cite = AttributedString(" \(n) "); cite.link = URL(string: "spd-source://\(n)"); cite.font = SPDTheme.Typo.caption.weight(.semibold); cite.foregroundColor = SPDTheme.brand; cite.backgroundColor = SPDTheme.brandWash
                out.append(cite)
            } else { out.append(AttributedString(String(rest[open...close]))) }
            rest = rest[rest.index(after: close)...]
        }
        out.append(AttributedString(String(rest)))
        return out
    }
}

/// Opens the "Demander à mon Drive" window from anywhere.
@MainActor enum AskWindow {
    static func open() { NSApp.activate(ignoringOtherApps: true); AppDelegate.openAskWindow?() }
}
