// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/AppModel.swift
// Description: State and actions of the application: session (passkey, device link, lock), the sync engine of the signed-in account, reads of the local mirror for the views, and every action a person can take — each one recorded in the offline journal or the transfer queue, never done only in memory.
import AppKit
import Foundation
import LocalAuthentication
import Observation
import SPDriveCore
import SPDriveNext
import SPDriveSync

struct Banner: Equatable, Identifiable { let id = UUID(); var text: String; var isError: Bool }

@MainActor @Observable final class AppModel {
    enum Phase: Equatable { case launching, signedOut, signedIn }
    var phase = Phase.launching
    var locked = false
    var account: Account?
    var quota: Quota?
    var status = SyncStatus()
    var transfers: [Transfer] = []
    var conflicts: [SyncConflict] = []
    /// Grows each time the local mirror changed: views that read the mirror depend on it.
    var revision = 0
    var banner: Banner?
    var link: DeviceLinkStart?
    var signingIn = false
    var loginError: String?
    var finderRegistered = false
    /// The person turned the Finder location on in System Settings (macOS keeps a new location off until then).
    var finderEnabled = false
    /// The Finder location exists and is on: local copies, offline pins and opening through the Finder work.
    var finderReady: Bool { finderRegistered && finderEnabled }
    /// Items that have an active share link.
    var sharedIDs: Set<String> = []
    var shares: [DriveShare] = []
    var online = true
    var pendingInFinder = 0
    let settings = AppSettings()
    let notifier = Notifier()
    /// The navigator of the first window; also the one test tooling and the menu bar act on. Other windows have their own.
    let nav = Navigator()
    private var primaryNavigatorClaimed = false
    /// The navigator of the key window: menu commands act on it.
    var activeNav: Navigator?
    let menuBridge = MenuBridge()
    /// Keeps the menus in step with the key window: recomputed whenever anything it reads changes.
    func trackMenus() {
        let focus = withObservationTracking { menuFocus } onChange: { [weak self] in Task { @MainActor in self?.trackMenus() } }
        if menuBridge.focus != focus { menuBridge.focus = focus }
    }
    /// What the menus need to know to enable their commands; nil when no signed-in window can receive them.
    var menuFocus: WindowFocus? {
        guard phase == .signedIn else { return nil }
        let n = activeNav ?? nav
        return WindowFocus(section: n.section, folderID: n.folderID, hasFolder: n.section == .drive && rootID != nil, selectionCount: n.selection.count,
                           selectionHasTrashed: n.selection.contains { item($0)?.isTrashed == true }, canGoBack: n.canGoBack, canGoForward: n.canGoForward,
                           locked: locked, paused: settings.syncPaused, finderReady: finderReady)
    }
    /// What the transfer queue currently allows and why (shown by the transfer centre and the menu bar).
    var policy = TransferQueue.Policy()
    var power = PowerState.unconstrained
    let thumbnails = ThumbnailStore()
    // SP Drive 2.0
    /// The 2.0 endpoints (SPDriveNext) on the same server and token; nil when signed out.
    private(set) var next: NextClient?
    /// What the connected server can do (`GET /meta`); a 1.0 server has no feature.
    var meta = ServerMeta.v1
    var collections: [SmartCollection] = []
    var grants: [SharedGrant] = []
    func has(_ f: ServerMeta.Feature) -> Bool { meta.has(f) }
    var isAdmin: Bool { account?.role == "admin" }
    /// A section is offered only when the server can serve it: no empty promise.
    func isAvailable(_ s: SidebarItem) -> Bool {
        switch s {
        case .collections: has(.collections); case .sharedWithMe: has(.collab); case .activity: has(.activity); case .admin: isAdmin && meta.api >= 2
        default: true
        }
    }
    /// Reads the server's capabilities, plugs the event stream in when it has one, and loads what the sidebar shows.
    func refreshNext() async {
        guard let next, let api, let engine else { return }
        guard let m = try? await next.meta() else { return } // unreachable: keep what we knew
        let had = meta.has(.events)
        meta = m
        if m.has(.events), !had { await engine.setEventSource(NextEventSource(api: api)) } else if !m.has(.events), had { await engine.setEventSource(nil) }
        await refreshCollections(); await refreshGrants()
    }
    func refreshCollections() async { if has(.collections), let next, let c = try? await next.collections() { collections = c } }
    func refreshGrants() async { if has(.collab), let next, let g = try? await next.sharedWithMe() { grants = g } }
    private func serverNotified(_ kind: String) async {
        if kind.hasPrefix("collab.") { await refreshGrants() }
        lastDepositCheck = .distantPast; await checkDeposits()
    }
    private let powerSource = SystemPowerSource()

    private(set) var api: APIClient?
    private(set) var store: MetadataStore?
    private(set) var engine: SyncEngine?
    private let passkeys = PasskeyPresenter()
    private let network = NetworkMonitor()
    private var tasks: [Task<Void, Never>] = []
    private var linkTask: Task<Void, Never>?
    private var pinTask: Task<Void, Never>?
    private var finishedInBatch = (uploads: 0, downloads: 0, lastName: "")
    private var lastDepositCheck = Date.distantPast
    private var lastActive = Date()

    // MARK: Windows
    /// The first window takes the shared navigator; each further window gets its own.
    func claimNavigator() -> Navigator {
        if !primaryNavigatorClaimed { primaryNavigatorClaimed = true; return nav }
        let n = Navigator(); n.folderID = nav.folderID
        return n
    }
    func releaseNavigator(_ n: Navigator) { if n === nav { primaryNavigatorClaimed = false }; if activeNav === n { activeNav = nil } }

    // MARK: Session
    private var bootstrapped = false
    func bootstrap() async {
        guard !bootstrapped else { return } // every window calls this; only the first does the work
        bootstrapped = true
        trackMenus()
        do { api = try AppEnvironment.makeAPI() } catch { loginError = error.localizedDescription; phase = .signedOut; return }
        guard let api, (try? AppEnvironment.tokens.readToken()) != nil else { phase = .signedOut; autoLinkIfAsked(); return }
        do {
            let s = try await api.authState()
            if s.authenticated, let user = s.user { await enter(user, quota: s.quota) }
            else { try? AppEnvironment.tokens.deleteToken(); loginError = "La session de cet appareil a été fermée. Reconnectez-vous."; phase = .signedOut; autoLinkIfAsked() }
        } catch {
            // no server right now: the person keeps working on what this Mac already has
            if let data = AppEnvironment.defaults.data(forKey: "account"), let cached = try? JSONDecoder().decode(Account.self, from: data), AppEnvironment.currentAccount == cached.id { await enter(cached, quota: nil) }
            else { loginError = DriveError.wrap(error).errorDescription; phase = .signedOut }
        }
    }
    private func autoLinkIfAsked() {
        #if SPD_DEV
        // development variant only: start linking at launch so that test scripts can approve the code
        if ProcessInfo.processInfo.arguments.contains("-spdAutoLink") { startDeviceLink() }
        #endif
    }
    func signInWithPasskey() async {
        guard let api, !signingIn else { return }
        signingIn = true; loginError = nil
        defer { signingIn = false }
        do {
            let challenge = try await api.loginChallenge()
            let assertion = try await passkeys.assert(challenge)
            try await api.completeLogin(challenge, assertion: assertion, deviceName: AppEnvironment.deviceName)
            await finishSignIn()
        } catch { let e = DriveError.wrap(error); if e != .cancelled { loginError = e.errorDescription } }
    }
    /// Fallback without a passkey on this Mac: show a code, wait for a signed-in browser to approve it.
    func startDeviceLink() {
        guard let api, link == nil else { return }
        loginError = nil
        linkTask = Task {
            do {
                let l = try await api.startDeviceLink(deviceName: AppEnvironment.deviceName)
                link = l
                #if SPD_DEV
                try? l.userCode.write(to: AppEnvironment.containerURL.appendingPathComponent("devlink.txt"), atomically: true, encoding: .utf8)
                #endif
                let deadline = Date().addingTimeInterval(Double(l.expiresInS))
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(max(l.intervalS, 1)) * 1_000_000_000)
                    switch try await api.pollDeviceLink(l.deviceCode) {
                    case .approved: link = nil; await finishSignIn(); return
                    case .denied: link = nil; loginError = "La demande a été refusée dans le navigateur."; return
                    case .expired: link = nil; loginError = "Le code a expiré. Recommencez."; return
                    case .pending: continue
                    }
                }
                link = nil
            } catch { link = nil; let e = DriveError.wrap(error); if e != .cancelled { loginError = e.errorDescription } }
        }
    }
    func cancelDeviceLink() { linkTask?.cancel(); linkTask = nil; link = nil }
    private func finishSignIn() async {
        guard let api else { return }
        do {
            let s = try await api.authState()
            guard s.authenticated, let user = s.user else { throw DriveError.unauthenticated }
            await enter(user, quota: s.quota)
        } catch { loginError = DriveError.wrap(error).errorDescription }
    }
    private func enter(_ user: Account, quota q: Quota?) async {
        guard let api else { return }
        await leave()
        do {
            AppEnvironment.currentAccount = user.id
            AppEnvironment.defaults.set(try? JSONEncoder().encode(user), forKey: "account")
            let store = try MetadataStore(url: AppEnvironment.databaseURL(account: user.id))
            let engine = SyncEngine(api: api, store: store, network: network, workDirectory: AppEnvironment.workDirectory, deviceName: AppEnvironment.deviceName, power: powerSource)
            self.store = store; self.engine = engine; account = user; quota = q
            next = NextClient(APIClientTransport(api: api))
            await engine.setNotifyHandler { [weak self] kind in await self?.serverNotified(kind) }
            thumbnails.configure(api: api, directory: cacheDirectory.appendingPathComponent("thumbnails", isDirectory: true))
            await engine.setRemoteChangeHandler { [weak self] changes in await self?.remoteChanged(changes) }
            await applyTransferSettings()
            if settings.syncPaused { await engine.pause() }
            await engine.start()
            tasks.append(Task { [weak self] in for await s in await engine.statusStream() { self?.statusChanged(s) } })
            tasks.append(Task { [weak self] in for await e in await engine.transfers.events() { await self?.transferEvent(e) } })
            tasks.append(Task { [weak self, network] in for await s in network.changes() { self?.online = s.online; if s.online { DriveDomain.shared.signalResolved(.serverUnreachable) } } })
            tasks.append(Task { [weak self] in while !Task.isCancelled { await self?.refreshPolicy(); try? await Task.sleep(nanoseconds: 5_000_000_000) } }) // power changes without any transfer event
            observeSharedDatabase()
            phase = .signedIn; loginError = nil
            if settings.biometricLock { locked = true }
            // the Finder location holds a replica of ONE account's tree. Entering as another account without having
            // signed out (session closed, then another person signs in) must not reuse it: the system would reconcile
            // one account's files against the other's. Remove it (unsent edits are preserved by the system), then add a fresh one.
            let replicaOwner = AppEnvironment.defaults.string(forKey: "finderDomainAccount")
            if let replicaOwner, replicaOwner != user.id, let kept = try? await DriveDomain.shared.remove() {
                banner = Banner(text: "L’emplacement Finder appartenait à un autre compte : il a été recréé. Les modifications non envoyées sont conservées dans \(kept.path).", isError: false)
            }
            AppEnvironment.defaults.set(user.id, forKey: "finderDomainAccount")
            await applyFinderIntegration()
            DriveDomain.shared.signalResolved(.notAuthenticated)
            notifier.requestAuthorization()
            await reloadLists()
            Task { await self.refreshShares() }
            consumeFinderRequest() // the app may have been opened by the Finder action itself
            await refreshNext()
            applyDevArguments()
            DropZoneController.shared.update(model: self)
            Task { await SpotlightIndexer.shared.sync(model: self) }
            #if SPD_DEV
            if UserDefaults.standard.bool(forKey: "spdSelfTest") { Task { await DevSelfTest.run(self) } }
            if UserDefaults.standard.bool(forKey: "spdMenuProbe") { Task { await DevSelfTest.menuProbe(self) } }
            if UserDefaults.standard.bool(forKey: "spdPerf") { Task { await DevSelfTest.perfProbe(self) } }
            if UserDefaults.standard.bool(forKey: "spdOnScreen") { Task { await DevSelfTest.onScreenOnly(self) } }
            if UserDefaults.standard.bool(forKey: "spdTour") { Task { await DevTour.run(self, into: AppEnvironment.containerURL.appendingPathComponent("tour")) } } // inside the sandbox
            #endif
        } catch { loginError = "Impossible d’ouvrir la base locale : \(error.localizedDescription)"; phase = .signedOut }
    }
    /// Development variant only: launch arguments that put the window in a given state for visual checks.
    private func applyDevArguments() {
        #if SPD_DEV
        let d = UserDefaults.standard
        if let s = d.string(forKey: "spdSection"), let section = SidebarItem(rawValue: s), isAvailable(section) { nav.section = section }
        if d.object(forKey: "spdGrid") != nil { settings.gridView = d.bool(forKey: "spdGrid") }
        if let name = d.string(forKey: "spdFolder"), let root = rootID, let f = children(of: root).first(where: { $0.name == name }) { nav.folderID = f.id }
        if let path = d.string(forKey: "spdPath"), var at = rootID { // "Atelier/Photos de chantier"
            for name in path.split(separator: "/") { if let f = children(of: at).first(where: { $0.name == name && $0.isFolder }) { at = f.id } }
            if at != rootID { nav.folderID = at }
        }
        if let q = d.string(forKey: "spdSearch") { nav.searchText = q }
        if d.bool(forKey: "spdSemantic") { nav.searchSemantic = true }
        let items = nav.section == .trash ? trash() : children(of: nav.folderID ?? rootID ?? "")
        let target = d.string(forKey: "spdSelect").flatMap { n in items.first { $0.name == n } } ?? (d.bool(forKey: "spdSelectFirst") ? items.first : nil)
        if let target { nav.selection = [target.id] }
        if d.bool(forKey: "spdSignOut") { Task { await signOut(); try? "done".write(to: AppEnvironment.containerURL.appendingPathComponent("signedout.txt"), atomically: true, encoding: .utf8) }; return } // leaves the Mac clean after a test campaign
        if d.bool(forKey: "spdInspector") { nav.showInspector = true }
        if let t = target, d.object(forKey: "spdPin") != nil { let on = d.bool(forKey: "spdPin"); Task { await refreshFinderState(); await setPinned([t], on) } }
        if let t = target, d.bool(forKey: "spdEvict") { Task { await refreshFinderState(); let r = await freeUpSpace([t.id]); AppEnvironment.log.info("evict: freed \(r.freed) kept \(r.kept)") } }
        switch d.string(forKey: "spdSheet") {
        case "share": if let t = target { nav.sheet = .share(t) }
        case "versions": if let t = target { nav.sheet = .versions(t) }
        case "portal": if let t = target ?? rootID.flatMap({ item($0) }) { nav.sheet = .portal(folder: t) }
        case "rename": if let t = target { nav.sheet = .rename(t) }
        case "move": if let t = target { nav.sheet = .move([t]) }
        case "newFolder": if let r = nav.folderID ?? rootID { nav.sheet = .newFolder(parent: r) }
        case "conflict": if let c = conflicts.first(where: \.isOpen) { nav.sheet = .conflict(c) }
        case "ask": nav.sheet = .ask(target)
        case "members": if let t = target ?? nav.folderID.flatMap({ item($0) }) { nav.sheet = .members(t) }
        case "collection": nav.sheet = .collection(collections.first)
        case "suggest": nav.sheet = .suggest(items.filter { !$0.isFolder }.prefix(3).map { $0 })
        default: break
        }
        if d.bool(forKey: "spdPalette") { nav.showPalette = true }
        // the app's own appearance for visual checks (the system setting is not touched): -spdAppearance dark|light
        if let a = d.string(forKey: "spdAppearance") { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        #endif
    }
    private func leave() async {
        for t in tasks { t.cancel() }; tasks.removeAll()
        await engine?.stop()
        engine = nil; store = nil; next = nil; meta = .v1; collections = []; grants = []
        thumbnails.reset()
        DropZoneController.shared.hide()
    }
    /// Signs out: the device session is revoked, the Finder location removed (unsent edits are preserved by the system), the local mirror erased.
    func signOut() async {
        let id = account?.id
        await leave()
        await api?.signOut()
        if let kept = try? await DriveDomain.shared.remove() { banner = Banner(text: "Des modifications non envoyées ont été conservées dans \(kept.path).", isError: false) }
        finderRegistered = false; finderEnabled = false
        await SpotlightIndexer.shared.removeAll() // nothing about the account stays searchable on this Mac
        if let id { try? FileManager.default.removeItem(at: AppEnvironment.databaseURL(account: id).deletingLastPathComponent()) }
        try? FileManager.default.removeItem(at: AppEnvironment.workDirectory)
        try? FileManager.default.removeItem(at: cacheDirectory)
        AppEnvironment.currentAccount = nil; AppEnvironment.defaults.removeObject(forKey: "account"); AppEnvironment.defaults.removeObject(forKey: "finderDomainAccount")
        account = nil; quota = nil; transfers = []; conflicts = []; shares = []; sharedIDs = []; status = SyncStatus(); phase = .signedOut
    }
    /// Number of local decisions and transfers the server has not confirmed yet (shown before signing out).
    var unsyncedCount: Int { status.pendingOperations + status.transfers.running + status.transfers.queued + status.transfers.paused + pendingInFinder }

    /// Shows an item in the window: its folder, with the item selected (Spotlight result, Finder action, notification).
    func reveal(itemID: String, sheet: ((DriveItem) -> SheetKind)? = nil) {
        guard phase == .signedIn, let item = item(itemID), !item.isTrashed else { return }
        if item.isFolder && sheet == nil { nav.go(to: item.isRoot ? nil : item.id) }
        else { nav.go(to: item.parentID == rootID ? nil : item.parentID); nav.selection = [item.id] }
        if let sheet { nav.sheet = sheet(item) }
        AppDelegate.showMainWindow()
    }

    // MARK: Lock
    func unlock() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return } // a Mac without any way to authenticate cannot be locked out of its own data
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "déverrouiller SP Drive")) == true { locked = false; lastActive = Date() }
    }
    func appBecameActive() { Task { await refreshFinderState() }; if settings.biometricLock, phase == .signedIn, Date().timeIntervalSince(lastActive) > 120 { locked = true }; Task { await engine?.poke() } }
    func appResignedActive() { lastActive = Date() }

    // MARK: Engine events
    private func statusChanged(_ s: SyncStatus) {
        let was = status
        status = s
        // the server answers again: the system retries what it was holding for the Finder location
        if was.phase == .offline, s.phase == .idle || s.phase == .syncing { DriveDomain.shared.signalResolved(.serverUnreachable); DriveDomain.shared.signalChanges() }
        if s.phase == .needsLogin, was.phase != .needsLogin {
            // the session was revoked elsewhere: local work stays in the journal for the next sign-in
            loginError = "La session de cet appareil a été fermée. Reconnectez-vous : vos modifications en attente sont conservées."
            phase = .signedOut
        }
        if case .error(let m) = s.phase, was.phase != s.phase { banner = Banner(text: m, isError: true) }
    }
    private func remoteChanged(_ changes: [DetectedChange]) async {
        revision += 1
        DriveDomain.shared.signalChanges()
        await reloadLists()
        await refreshAccount()
        await checkDeposits()
        await SpotlightIndexer.shared.sync(model: self)
    }
    func refreshPolicy() async {
        guard let engine else { return }
        let p = await engine.transfers.policy()
        if p != policy { policy = p }
        let s = powerSource.state
        if s != power { power = s }
    }
    private func transferEvent(_ e: TransferEvent) async {
        if let engine { transfers = await engine.transfers.list() }
        await refreshPolicy()
        switch e {
        case .finished(let t, _):
            if t.direction == .upload { finishedInBatch.uploads += 1; revision += 1; DriveDomain.shared.signalChanges() } else { finishedInBatch.downloads += 1 }
            finishedInBatch.lastName = t.name
            if let s = await engine?.transfers.summary(), s.running + s.queued == 0 { announceBatch() }
        case .conflict(let c):
            await reloadLists()
            if settings.notifyConflicts { notifier.post(id: "conflict-\(c.id)", title: "Conflit de versions", body: "« \(c.itemName) » a été modifié sur deux appareils. Les deux versions sont conservées ; choisissez laquelle garder.") }
        case .failed(let t, let persistent):
            if t.error?.contains("insuffisant") == true { notifier.post(id: "quota", title: "Espace de stockage insuffisant", body: "« \(t.name) » n’a pas pu être envoyé : SP Drive est plein.") }
            else if persistent { notifier.post(id: "sync-error", title: "Erreur de synchronisation persistante", body: "« \(t.name) » : \(t.error ?? "échec répété"). SP Drive continue d’essayer.") }
            else { banner = Banner(text: "« \(t.name) » : \(t.error ?? "échec")", isError: true) }
        case .changed, .removed: break
        }
    }
    private func announceBatch() {
        let b = finishedInBatch; finishedInBatch = (0, 0, "")
        guard settings.notifyTransfers else { return }
        if b.uploads == 1, b.downloads == 0 { notifier.post(id: "batch", title: "Téléversement terminé", body: "« \(b.lastName) » est sur SP Drive.") }
        else if b.uploads > 1, b.downloads == 0 { notifier.post(id: "batch", title: "Téléversements terminés", body: "\(b.uploads) fichiers sont sur SP Drive.") }
        else if b.downloads == 1, b.uploads == 0 { notifier.post(id: "batch", title: "Téléchargement terminé", body: "« \(b.lastName) » est dans Téléchargements.") }
        else if b.downloads + b.uploads > 0 { notifier.post(id: "batch", title: "Transferts terminés", body: "\(b.uploads) envoyé(s), \(b.downloads) téléchargé(s).") }
    }
    private func observeSharedDatabase() {
        // the File Provider extension writes the same database from the Finder: it tells us with a Darwin notification
        let name = AppEnvironment.changedNotification
        tasks.append(Task { [weak self] in
            for await _ in DarwinNotifications.stream(name) {
                guard let self else { return }
                let before = self.conflicts.filter(\.isOpen).count
                self.revision += 1
                self.consumeFinderRequest()
                await self.reloadLists()
                let open = self.conflicts.filter(\.isOpen)
                if open.count > before, self.settings.notifyConflicts, let c = open.first {
                    self.notifier.post(id: "conflict-\(c.id)", title: "Conflit de versions", body: "« \(c.itemName) » a été modifié sur deux appareils. Les deux versions sont conservées ; choisissez laquelle garder.")
                }
                await self.engine?.poke()
            }
        })
    }
    /// Something asked for in the Finder's context menu that only the app can show (version history).
    private func consumeFinderRequest() {
        guard let store, let raw = (try? store.meta("ui_request")) ?? nil else { return }
        try? store.setMeta("ui_request", nil)
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 3, let at = Double(parts[2]), Date().timeIntervalSince1970 - at < 120 else { return }
        if parts[0] == "versions" { reveal(itemID: parts[1]) { .versions($0) } }
        Task { await refreshShares() }
    }
    func reloadLists() async {
        guard let engine, let store else { return }
        transfers = await engine.transfers.list()
        conflicts = (try? engine.conflicts.conflicts()) ?? []
        pendingInFinder = Int((try? store.meta("fp_pending")).flatMap { $0 } ?? "0") ?? 0
    }
    func refreshAccount() async {
        guard let api, let s = try? await api.authState(), s.authenticated else { return }
        quota = s.quota; if let u = s.user { account = u }
    }
    func refreshShares() async {
        guard let api, let all = try? await api.shares() else { return }
        shares = all; sharedIDs = Set(all.filter(\.isActive).compactMap(\.targetId))
        // the Finder shows "shared" on these items: the extension reads the list from the mirror
        let joined = sharedIDs.sorted().joined(separator: ",")
        if let store, ((try? store.meta("shared_ids")) ?? nil ?? "") != joined {
            let before = Set(((try? store.meta("shared_ids")) ?? nil ?? "").split(separator: ",").map(String.init))
            try? store.setMeta("shared_ids", joined); try? store.touch(Array(before.symmetricDifference(sharedIDs)))
            DriveDomain.shared.signalChanges()
        }
    }
    private func checkDeposits() async {
        guard settings.notifyDeposits, let api, Date().timeIntervalSince(lastDepositCheck) > 60 else { return }
        lastDepositCheck = Date()
        guard let notes = try? await api.notifications() else { return }
        var seen = Set(AppEnvironment.defaults.stringArray(forKey: "seenNotifications") ?? [])
        let firstRun = AppEnvironment.defaults.object(forKey: "seenNotifications") == nil
        for n in notes where n.kind == "request.submission" && !seen.contains(n.id) {
            seen.insert(n.id)
            if !firstRun, !n.read { notifier.post(id: "deposit-\(n.id)", title: "Nouveau dépôt reçu", body: "\(n.data["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Quelqu’un") a déposé \(n.data["placed"]?.int ?? 0) fichier(s) dans « \(n.data["title"]?.string ?? "un portail") ».") }
        }
        AppEnvironment.defaults.set(Array(seen.suffix(500)), forKey: "seenNotifications")
    }

    // MARK: Settings that act
    func applyTransferSettings() async {
        guard let engine else { return }
        await engine.transfers.setLimits(uploadBytesPerSecond: Int64(settings.uploadLimitKB) * 1024, downloadBytesPerSecond: Int64(settings.downloadLimitKB) * 1024)
        await engine.transfers.setManualConcurrency(settings.parallelTransfers > 0 ? settings.parallelTransfers : nil)
        await engine.transfers.setPowerAware(settings.respectPower)
        await refreshPolicy()
    }
    func applyFinderIntegration() async {
        do {
            if settings.finderIntegration { try await DriveDomain.shared.register() } else { _ = try await DriveDomain.shared.remove() }
        } catch { banner = Banner(text: "Intégration au Finder : \(error.localizedDescription)", isError: true) }
        await refreshFinderState()
    }
    /// Reads the state of the Finder location; when it has just been turned on, the system is told to start syncing.
    func refreshFinderState() async {
        let was = finderReady
        let s = await DriveDomain.shared.state()
        finderRegistered = s.registered; finderEnabled = s.enabled
        if finderReady, !was { DriveDomain.shared.signalResolved(.notAuthenticated); DriveDomain.shared.signalResolved(.serverUnreachable); DriveDomain.shared.signalChanges(); revision += 1 }
    }
    /// While the location waits to be turned on, look again every few seconds (stops as soon as it is on).
    func watchFinderState() async {
        while !Task.isCancelled, phase == .signedIn, finderRegistered, !finderEnabled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshFinderState()
        }
    }
    func setPaused(_ paused: Bool) async {
        settings.syncPaused = paused
        if paused { await engine?.pause() } else { await engine?.resume() }
    }
    func syncNow() async { await engine?.poke() }

    // MARK: Reading the mirror
    var rootID: String? { store?.rootID }
    func children(of folder: String) -> [DriveItem] { (try? store?.children(of: folder)) ?? [] }
    func item(_ id: String) -> DriveItem? { (try? store?.item(id)) ?? nil }
    func path(to id: String) -> [DriveItem] { (try? store?.path(to: id)) ?? [] }
    func recent() -> [DriveItem] { (try? store?.recent()) ?? [] }
    func starred() -> [DriveItem] { (try? store?.starred()) ?? [] }
    func pinned() -> [DriveItem] { (try? store?.pinnedItems()) ?? [] }
    func trash() -> [DriveItem] { (try? store?.trashRoots()) ?? [] }
    func search(_ q: LocalSearch) -> [DriveItem] { (try? store?.search(q)) ?? [] }
    func isPinned(_ id: String) -> Bool { (try? store?.isPinned(id)) ?? false }
    func isPinnedItself(_ id: String) -> Bool { (try? store?.isPinnedItself(id)) ?? false }
    func isLocal(_ id: String) -> Bool { (try? store?.isMaterialized(id)) ?? false }
    func isPending(_ id: String) -> Bool { OperationJournal.isLocal(id) }

    // MARK: Actions on the tree (journaled: they work offline and survive a restart)
    private func act(_ what: String, _ body: (OperationJournal) throws -> Void) {
        guard let engine else { return }
        do { try body(engine.journal); changed() }
        catch { banner = Banner(text: "\(what) : \(DriveError.wrap(error).errorDescription ?? "échec")", isError: true) }
    }
    private func changed() {
        revision += 1
        DriveDomain.shared.signalChanges()
        Task { await engine?.poke(); await reloadLists() }
    }
    @discardableResult func createFolder(in parent: String, name: String) -> DriveItem? {
        var made: DriveItem?
        act("Nouveau dossier") { made = try $0.createFolder(parent: parent, name: name) }
        return made
    }
    func rename(_ item: DriveItem, to name: String) { act("Renommer") { try $0.rename(item, to: name) } }
    func move(_ items: [DriveItem], to destination: String) { act("Déplacer") { try $0.move(items, to: destination) } }
    func trash(_ items: [DriveItem]) { act("Supprimer") { try $0.trash(items) } }
    func restore(_ items: [DriveItem]) { act("Restaurer") { try $0.restore(items) } }
    func setStarred(_ items: [DriveItem], _ on: Bool) { act("Favoris") { for i in items { try $0.setStarred(i, on) } } }
    func duplicate(_ items: [DriveItem]) {
        act("Dupliquer") { j in
            for (parent, group) in Dictionary(grouping: items, by: { $0.parentID ?? "" }) where !parent.isEmpty { try j.copy(group, to: parent) }
        }
    }
    /// Deletes for good, from the trash only, after the person confirmed. Needs the server: a destruction is never queued blindly.
    func purge(_ items: [DriveItem]) async {
        guard let api else { return }
        do { try await api.purge(Selection(items)); try store?.remove(items.flatMap { (try? store?.subtreeIDs(of: $0.id, includeTrashed: true)) ?? [$0.id] }); changed() }
        catch { banner = Banner(text: "Suppression définitive : \(DriveError.wrap(error).errorDescription ?? "échec")", isError: true) }
    }
    func emptyTrash() async {
        guard let api else { return }
        do { try await api.emptyTrash(); await engine?.poke(); changed() }
        catch { banner = Banner(text: "Vider la corbeille : \(DriveError.wrap(error).errorDescription ?? "échec")", isError: true) }
    }

    // MARK: Transfers
    /// Queues files and folders for upload into `parent`. Folders are re-created (journaled), their files queued inside.
    func upload(_ urls: [URL], to parent: String) async {
        guard let engine else { return }
        var failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await uploadOne(url, to: parent, engine: engine, failed: &failed)
        }
        if failed > 0 { banner = Banner(text: "\(failed) élément(s) n’ont pas pu être ajoutés à la file d’envoi.", isError: true) }
        changed()
    }
    private func uploadOne(_ url: URL, to parent: String, engine: SyncEngine, failed: inout Int) async {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        if values?.isSymbolicLink == true || url.lastPathComponent.hasPrefix(".") { return } // links and hidden files stay on this Mac
        if values?.isDirectory == true {
            guard let folder = try? engine.journal.createFolder(parent: parent, name: url.lastPathComponent) else { failed += 1; return }
            let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { await uploadOne(k, to: folder.id, engine: engine, failed: &failed) }
        } else {
            do { _ = try await engine.transfers.enqueueUpload(file: url, parent: parent, priority: TransferPriority.userInitiated) } catch { failed += 1 }
        }
    }
    /// Sends a local file as a new version of an existing file (the version history keeps the previous one). The upload
    /// names the version this Mac knows: if another device replaced it meanwhile, a conflict is raised instead of a silent overwrite.
    func uploadNewVersion(of item: DriveItem, from url: URL) async {
        guard let engine else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { _ = try await engine.transfers.enqueueUpload(file: url, parent: item.parentID ?? "root", replacing: item, baseVersionID: item.versionID, priority: TransferPriority.userInitiated); changed() }
        catch { banner = Banner(text: "Nouvelle version : \(error.localizedDescription)", isError: true) }
    }
    var downloadsFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    private func uniqueURL(in dir: URL, name: String) -> URL {
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { NameRules.key($0) })
        return dir.appendingPathComponent(NameRules.nextFree(NameRules.sanitize(name)) { taken.contains($0) })
    }
    /// Queues downloads into the Downloads folder (folders are re-created with their content).
    func download(_ items: [DriveItem], version: FileVersion? = nil) async {
        guard let engine, let store else { return }
        for item in items {
            do {
                if item.isFolder {
                    let base = uniqueURL(in: downloadsFolder, name: item.name)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    let depth = try store.path(to: item.id).count
                    for f in try store.subtreeFiles(of: item.id) {
                        var dir = base
                        for comp in try store.path(to: f.id).dropFirst(depth).dropLast() { dir = try PathSafety.child(of: dir, named: NameRules.sanitize(comp.name)) }
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        _ = try await engine.transfers.enqueueDownload(f, to: try PathSafety.child(of: dir, named: NameRules.sanitize(f.name)), priority: TransferPriority.userInitiated)
                    }
                } else {
                    let name = version.map { v in let (s, e) = NameRules.splitExtension(item.name); return "\(s) (version \(v.seq))\(e)" } ?? item.name
                    _ = try await engine.transfers.enqueueDownload(item, version: version, to: uniqueURL(in: downloadsFolder, name: name), priority: TransferPriority.userInitiated)
                }
            } catch { banner = Banner(text: "Téléchargement de « \(item.name) » : \(DriveError.wrap(error).errorDescription ?? "échec")", isError: true) }
        }
        await reloadLists()
    }
    func pauseTransfer(_ id: String) async { await engine?.transfers.pause(id); await reloadLists() }
    func resumeTransfer(_ id: String) async { await engine?.transfers.resume(id); await reloadLists() }
    func cancelTransfer(_ id: String) async { await engine?.transfers.cancel(id); await reloadLists() }
    func removeTransfer(_ id: String) async { await engine?.transfers.remove(id); await reloadLists() }
    func clearFinishedTransfers() async { await engine?.transfers.clearFinished(); await reloadLists() }
    /// "Send this one first".
    func prioritizeTransfer(_ id: String) async { await engine?.transfers.setPriority(id, TransferPriority.urgent); await reloadLists() }
    func retryAllFailed() async { for t in transfers where t.state == .failed { await engine?.transfers.resume(t.id) }; await reloadLists() }
    /// Seconds left for everything in flight at the current speed; nil when it cannot be known honestly.
    var secondsRemaining: Double? {
        let s = status.transfers
        guard s.speed > 1024, s.bytesLeft > 0, s.running > 0 else { return nil }
        return Double(s.bytesLeft) / s.speed
    }

    // MARK: Opening and previewing
    var cacheDirectory: URL { AppEnvironment.containerURL.appendingPathComponent("cache", isDirectory: true) }
    /// A local, verified copy of a file for preview: the Finder copy when it is on this Mac, a cached download otherwise.
    /// - Parameter inContainer: always answer with a copy inside the app's own container (what Quick Look and a drag to
    ///   another app are given: they cannot be handed a file of the Finder location from this sandbox). The copy of a
    ///   file already on this Mac is an APFS clone: no bytes are duplicated, nothing is downloaded.
    func localCopy(of item: DriveItem, inContainer: Bool = false) async throws -> URL {
        guard !item.isFolder, let api else { throw DriveError.local("pas de contenu à afficher") }
        let dir = cacheDirectory.appendingPathComponent("\(item.id)-\(item.versionID ?? item.sha256)", isDirectory: true)
        let dest = try PathSafety.child(of: dir, named: NameRules.sanitize(item.name))
        if inContainer, FileManager.default.fileExists(atPath: dest.path) { return dest }
        if finderReady, isLocal(item.id), let u = await DriveDomain.shared.url(for: item, rootID: rootID) {
            guard inContainer else { return u }
            if (try? await DriveDomain.shared.copyOut(u, to: dest, sha256: item.sha256)) != nil { return dest } // otherwise fall through to a verified download
        }
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try await DownloadEngine(api: api).download(fileID: item.id, versionID: item.versionID, sha256: item.sha256, size: item.size, to: dest, partial: dir.appendingPathComponent(".part"))
        return dest
    }
    /// The verified copy already made for a preview, when there is one (never downloads).
    func existingLocalCopy(of item: DriveItem) -> URL? {
        guard !item.isFolder, let dest = try? PathSafety.child(of: cacheDirectory.appendingPathComponent("\(item.id)-\(item.versionID ?? item.sha256)", isDirectory: true), named: NameRules.sanitize(item.name)) else { return nil }
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }
    /// Opens a file in its application. Through the Finder location when it exists, so that edits are synced back.
    func open(_ item: DriveItem) async {
        if finderReady, let u = await DriveDomain.shared.url(for: item, rootID: rootID) { NSWorkspace.shared.open(u); return }
        do { NSWorkspace.shared.open(try await localCopy(of: item)) }
        catch { banner = Banner(text: "Ouverture de « \(item.name) » : \(DriveError.wrap(error).errorDescription ?? "échec")", isError: true) }
    }
    func revealInFinder(_ item: DriveItem) async {
        if await !(finderReady ? DriveDomain.shared.reveal(item, rootID: rootID) : false) { banner = Banner(text: "Activez l’intégration au Finder dans les réglages pour afficher cet élément dans le Finder.", isError: false) }
    }

    // MARK: Offline
    /// Keeps items available offline (pinned): downloaded now, kept up to date, never evicted. Requires the Finder location, which holds the local copies.
    func setPinned(_ items: [DriveItem], _ on: Bool) async {
        guard let store else { return }
        guard finderReady || !on else { banner = Banner(text: "La disponibilité hors ligne utilise l’emplacement SP Drive du Finder : activez-le dans les réglages.", isError: false); return }
        for i in items { try? store.setPinned(i.id, on) }
        revision += 1
        DriveDomain.shared.signalChanges()
        if on {
            // the policy makes the system keep these files; reading them now makes it fetch them now (in the background, two at a time)
            let files = items.flatMap { i in i.isFolder ? ((try? store.subtreeFiles(of: i.id)) ?? []) : [i] }.filter { !isLocal($0.id) }
            pinTask = Task.detached(priority: .utility) { [weak self] in
                var failed = 0
                await withTaskGroup(of: Bool.self) { group in
                    var running = 0
                    for f in files {
                        if running >= 2 { if await group.next() == false { failed += 1 }; running -= 1 }
                        group.addTask { do { try await DriveDomain.shared.materialize(f.id); return true } catch { AppEnvironment.log.notice("pinned item not fetched yet: \(String(describing: error), privacy: .public)"); return false } }
                        running += 1
                    }
                    for await ok in group where !ok { failed += 1 }
                }
                let n = failed
                await MainActor.run { [weak self] in
                    self?.revision += 1
                    if n > 0 { self?.banner = Banner(text: "\(n) élément(s) épinglé(s) n’ont pas encore pu être téléchargés ; macOS réessaiera.", isError: false) }
                }
            }
        }
    }
    /// Removes the local copies and keeps the items on SP Drive. Pinned items and unsent edits are refused by the system.
    @discardableResult func freeUpSpace(_ ids: [String]) async -> (freed: Int, kept: Int) {
        var freed = 0, kept = 0
        for id in ids { do { try await DriveDomain.shared.evict(id); freed += 1 } catch { kept += 1 } }
        revision += 1
        return (freed, kept)
    }
    func freeUpAllUnpinned() async -> (freed: Int, kept: Int) { await freeUpSpace((try? store?.evictableIDs()) ?? []) }
    func cacheBytes() -> Int64 {
        var total: Int64 = 0
        for dir in [cacheDirectory, AppEnvironment.workDirectory] {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }
    /// Empties the preview cache. Staged uploads still waiting in the queue are not touched.
    func clearCache() { try? FileManager.default.removeItem(at: cacheDirectory); revision += 1 }

    // MARK: Conflicts
    /// The person's decision on a conflict. `.mineAsVersion` makes this Mac's content the new current version of the file
    /// (the server's version stays in the history); nothing is ever replaced without having been named.
    enum ConflictDecision { case keepBoth, mineAsVersion, server }
    @discardableResult func resolve(_ c: SyncConflict, _ decision: ConflictDecision) async -> Bool {
        guard let engine else { return false }
        do {
            switch decision {
            case .keepBoth: try await engine.conflicts.resolve(c, .keepBoth)
            case .server: try await engine.conflicts.resolve(c, .keepServer)
            case .mineAsVersion: try await engine.conflicts.resolveKeepingMineAsNewVersion(c, workDirectory: AppEnvironment.workDirectory, deviceName: AppEnvironment.deviceName)
            }
            await engine.poke(); await reloadLists(); revision += 1; DriveDomain.shared.signalChanges()
            return true
        } catch {
            let e = DriveError.wrap(error)
            banner = Banner(text: e.code == "version_conflict" ? "Le fichier a encore changé sur le serveur : rien n’a été remplacé. Regardez de nouveau les deux versions." : "Conflit : \(e.errorDescription ?? "échec")", isError: true)
            await engine.poke(); await reloadLists()
            return false
        }
    }
    func resolve(_ c: SyncConflict, _ choice: ConflictChoice) async { await resolve(c, choice == .keepBoth ? .keepBoth : choice == .keepServer ? .server : .mineAsVersion) }
}

/// Darwin notifications (cross-process, no payload) as an async stream.
enum DarwinNotifications {
    static func stream(_ name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = Unmanaged.passRetained(Box(continuation))
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), box.toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
            }, name as CFString, nil, .deliverImmediately)
            continuation.onTermination = { _ in
                CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), box.toOpaque()); box.release()
            }
        }
    }
    private final class Box: @unchecked Sendable { let continuation: AsyncStream<Void>.Continuation; init(_ c: AsyncStream<Void>.Continuation) { continuation = c } }
}
