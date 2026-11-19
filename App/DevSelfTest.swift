// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/DevSelfTest.swift
// Description: Development variant only: the signed, sandboxed application exercises its own actions against the test backend — journal, transfer queue, downloads into the Downloads folder, versions, trash, share links, keychain — and writes a report. Nothing is simulated: every check reads the server or the disk.
#if SPD_DEV
import AppKit
import QuartzCore
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import CoreImage
import SPDriveCore
import SPDriveNext
import SPDriveSync

@MainActor
enum DevSelfTest {
    struct Check: Codable { var name: String; var ok: Bool; var detail: String }
    static func run(_ model: AppModel) async {
        var checks: [Check] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks.append(Check(name: name, ok: ok, detail: detail)) }
        func wait(_ seconds: Double = 20, _ cond: @MainActor () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 150_000_000) }
            return false
        }
        let out = AppEnvironment.containerURL.appendingPathComponent("selftest.json")
        try? FileManager.default.removeItem(at: out)
        defer { try? JSONEncoder().encode(checks).write(to: out) }
        guard let api = model.api, let store = model.store, await wait(20, { model.rootID != nil && model.status.lastSync != nil }), let root = model.rootID else { check("first sync", false, "no root"); return }
        check("first sync", true, "root known, \((try? store.counts().files) ?? 0) files mirrored")
        // the token really is in the shared keychain group (what the File Provider extension will read)
        check("keychain: device token readable", ((try? AppEnvironment.tokens.readToken()) ?? nil)?.isEmpty == false)
        let state = try? await api.authState()
        check("session is a device session", state?.kind == "device", state?.user?.email ?? "")

        // --- folder, rename, star through the journal ---
        let name = "Autotest \(Int(Date().timeIntervalSince1970))"
        let local = model.createFolder(in: root, name: name)
        check("create folder: appears at once in the mirror", local != nil && model.children(of: root).contains { $0.name == name })
        let created = await wait(20) { (try? await api.listFolder(root).folders.contains { $0.name == name }) ?? false }
        check("create folder: confirmed by the server", created)
        guard await wait(20, { model.children(of: root).contains { $0.name == name && !model.isPending($0.id) } }), let folder = model.children(of: root).first(where: { $0.name == name }) else { check("folder id resolved", false); return }
        model.rename(folder, to: name + " renommé"); model.setStarred([folder], true)
        let renamed = await wait(20) { let i = (try? await api.item(folder.id, kind: .folder)) ?? nil; return i?.name == name + " renommé" && i?.starred == true }
        check("rename + favourite: confirmed by the server", renamed)

        // --- upload through the queue (file created inside the sandbox), verified by hash ---
        let work = AppEnvironment.containerURL.appendingPathComponent("selftest-src", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let src = work.appendingPathComponent("données.bin")
        var bytes = Data(count: 3 * 1024 * 1024 + 17); bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try? bytes.write(to: src)
        let sha = Hashing.sha256Hex(bytes)
        await model.upload([src], to: folder.id)
        let uploaded = await wait(40) { (try? await api.listFolder(folder.id).files.first { $0.name == "données.bin" }?.sha256) == sha }
        check("upload: on the server with the same SHA-256", uploaded)
        guard let file = try? await api.listFolder(folder.id).files.first(where: { $0.name == "données.bin" }) else { check("uploaded file listed", false); return }
        _ = await wait(20) { model.item(file.id) != nil }
        check("upload: the mirror learnt the file", model.item(file.id)?.sha256 == sha)

        // --- download into ~/Downloads (sandbox entitlement), verified ---
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: model.downloadsFolder.path)) ?? [])
        await model.download([file])
        let done = await wait(40) { model.transfers.contains { $0.direction == .download && $0.itemID == file.id && $0.state == .done } }
        let dest = model.transfers.first { $0.direction == .download && $0.itemID == file.id }.map { URL(fileURLWithPath: $0.localPath) }
        let same = dest.flatMap { try? Hashing.sha256Hex(of: $0).sha256 } == sha
        check("download: file in Downloads with the same SHA-256", done && same, dest?.lastPathComponent ?? "")
        if let dest, !before.contains(dest.lastPathComponent) { try? FileManager.default.removeItem(at: dest) }

        // --- preview cache copy ---
        let copy = try? await model.localCopy(of: file)
        check("preview copy: verified local copy", copy.flatMap { try? Hashing.sha256Hex(of: $0).sha256 } == sha)

        // --- new version, history, restore ---
        try? Data("version deux".utf8).write(to: src)
        await model.uploadNewVersion(of: file, from: src)
        let v2 = await wait(30) { ((try? await api.item(file.id, kind: .file)) ?? nil)?.versionSeq == 2 }
        check("new version: version 2 on the server", v2)
        if let d = try? await api.fileDetails(file.id), let first = d.versions.last {
            _ = try? await api.restoreVersion(fileID: file.id, versionID: first.id)
            let restored = (try? await api.item(file.id, kind: .file)) ?? nil
            check("restore version: creates version 3 with the first content", restored?.versionSeq == 3 && restored?.sha256 == sha)
        } else { check("version history readable", false) }

        // --- share link, public access, revocation ---
        if let made = try? await api.createShare(for: file, settings: ShareSettings(label: "autotest", password: .some("autotest-1"))) {
            await model.refreshShares()
            check("share: listed and badge set", model.sharedIDs.contains(file.id))
            try? await api.revokeShare(made.share.id); await model.refreshShares()
            check("share: revoked", !model.sharedIDs.contains(file.id))
        } else { check("share: created", false) }

        // --- duplicate, move, trash, restore ---
        model.duplicate([file])
        let dup = await wait(20) { ((try? await api.listFolder(folder.id).files.count) ?? 0) == 2 }
        check("duplicate: a second file on the server", dup)
        if let current = model.item(file.id) { model.trash([current]) }
        let trashed = await wait(20) { ((try? await api.item(file.id, kind: .file)) ?? nil)?.trashedAt != nil }
        check("delete: in the trash on the server (not destroyed)", trashed && model.trash().contains { $0.id == file.id })
        if let t = model.trash().first(where: { $0.id == file.id }) { model.restore([t]) }
        let back = await wait(20) { let i = (try? await api.item(file.id, kind: .file)) ?? nil; return i != nil && i?.trashedAt == nil }
        check("restore from trash: live again on the server", back)

        // --- offline pin needs the Finder location; without it the app says so instead of pretending ---
        if !model.finderReady {
            await model.setPinned([file], true)
            check("offline pin without Finder location: refused with an explanation", !model.isPinned(file.id) && model.banner != nil)
        } else {
            await model.setPinned([file], true)
            let local = await wait(40) { model.isLocal(file.id) }
            check("offline pin: file materialised by the Finder location", local && model.isPinned(file.id))
        }
        await next(model, api: api, store: store, folder: folder, file: file, sha: sha, record: { check($0, $1, $2) }, wait: { s, c in await wait(s, c) })
        // --- clean up: everything this run created goes to the trash ---
        if let f = model.item(folder.id) { model.trash([f]) }
        _ = await wait(20) { ((try? await api.item(folder.id, kind: .folder)) ?? nil)?.trashedAt != nil }
        try? FileManager.default.removeItem(at: work)
        check("journal empty at the end", (try? model.engine?.journal.pendingCount()) == 0, "\(model.status.pendingOperations) pending")
    }

    // MARK: SP Drive 2.0
    /// Checks of the 2.0 interface and engine, inside the signed, sandboxed app. Keys are posted to this app's own event queue (no global event, no other app involved).
    static func next(_ model: AppModel, api: APIClient, store: MetadataStore, folder: DriveItem, file: DriveItem, sha: String, record: (String, Bool, String) -> Void,
                     wait: (Double, @MainActor () async -> Bool) async -> Bool) async {
        func check(_ n: String, _ ok: Bool, _ detail: String = "") { record(n, ok, detail) }
        let nav = model.nav
        // a launch that goes through device linking may still be putting its window up: give it a moment, and say what is there if it never comes
        _ = await wait(10) { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            let seen = NSApp.windows.map { "\($0.title.isEmpty ? "(untitled)" : $0.title):visible=\($0.isVisible),mini=\($0.isMiniaturized),main=\($0.canBecomeMain),\(type(of: $0))" }.joined(separator: "; ")
            check("a main window exists", false, "hidden=\(NSApp.isHidden) active=\(NSApp.isActive) windows=[\(seen)]"); return
        }
        func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) async {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        window.makeFirstResponder(nil)

        // --- engine policy as the app sees it ---
        await model.refreshPolicy()
        check("policy: adaptive concurrency within 1…6", (1...6).contains(model.policy.concurrency) && model.policy.manual == nil, "\(model.policy.concurrency) now, measured limit \(model.policy.measuredLimit)")
        let wantStream = model.has(.events)
        let channel = await wait(15) { model.status.events == (wantStream ? .stream : .polling) }
        check(wantStream ? "events: the server's event stream is live" : "events: polling fallback is listening", channel, model.status.events.rawValue)
        check("power: state read from the system", model.power.lowPowerMode == ProcessInfo.processInfo.isLowPowerModeEnabled, "battery \(model.power.onBattery) level \(model.power.level.map { String($0) } ?? "none")")

        // --- three more files, one of them a real image, to navigate among ---
        let work = AppEnvironment.containerURL.appendingPathComponent("selftest-next", isDirectory: true)
        try? FileManager.default.removeItem(at: work); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 320, height: 200)); img.lockFocus(); NSColor.systemIndigo.setFill(); NSRect(x: 0, y: 0, width: 320, height: 200).fill(); NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 110, y: 50, width: 100, height: 100)).fill(); img.unlockFocus()
        let png = img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        try? png.write(to: work.appendingPathComponent("image.png"))
        try? Data("alpha".utf8).write(to: work.appendingPathComponent("alpha.txt")); try? Data("zoulou".utf8).write(to: work.appendingPathComponent("zoulou.txt"))
        // dropped on the folder exactly as a drag from the Finder would arrive (file URL providers)
        let providers = ["image.png", "alpha.txt", "zoulou.txt"].map { NSItemProvider(object: work.appendingPathComponent($0) as NSURL) }
        let accepted = Drops.handle(providers, into: folder.id, model: model)
        let arrived = await wait(40) { ((try? await api.listFolder(folder.id).files.map(\.name)) ?? []).filter { ["image.png", "alpha.txt", "zoulou.txt"].contains($0) }.count == 3 }
        check("drop in: file URLs dropped on a folder are uploaded there", accepted && arrived)
        _ = await wait(20) { model.children(of: folder.id).count >= 4 }
        let serverImage = await wait(30) { ((try? await api.listFolder(folder.id).files.first { $0.name == "image.png" }?.hasThumbnail) ?? false) }
        // the mirror learnt of the file before the server drew its thumbnail, and the change feed does not announce a thumbnail: the app must find it anyway
        let mirrorKnows = model.children(of: folder.id).first { $0.name == "image.png" }?.hasThumbnail == true

        // --- grid with a real thumbnail ---
        nav.go(to: folder.id); model.settings.gridView = true; model.settings.gridSize = 1
        try? await Task.sleep(nanoseconds: 900_000_000)
        let rows = model.children(of: folder.id).sorted { NameRules.searchKey($0.name) < NameRules.searchKey($1.name) }
        if let pic = rows.first(where: { $0.name == "image.png" }) {
            let got = await wait(45) { model.thumbnails.cached(pic) != nil }
            check("thumbnails: the grid shows the server's real thumbnail", serverImage && got, "mirror flag \(mirrorKnows), \(model.thumbnails.fetched) fetched, \(model.thumbnails.cached(pic).map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none")")
        } else { check("thumbnails: image listed", false) }

        // --- keyboard: arrows in the grid, type-select, Return renames in place, Space opens Quick Look ---
        guard rows.count >= 4 else { check("keyboard: four items to navigate", false, "\(rows.count)"); return }
        nav.selection = [rows[0].id]; nav.anchorID = rows[0].id
        await key(Key.right)
        check("keyboard: → moves the selection to the next item of the grid", nav.selection == [rows[1].id], nav.selection.compactMap { model.item($0)?.name }.joined())
        await key(Key.left); await key(Key.right, flags: .shift)
        check("keyboard: ⇧→ extends the selection", nav.selection == [rows[0].id, rows[1].id])
        nav.selection = []
        await key(6, "z"); await key(31, "o")
        check("keyboard: typing “zo” selects the item whose name starts with it", nav.selection.compactMap { model.item($0)?.name } == ["zoulou.txt"])
        await key(Key.return, "\r")
        let renaming = nav.renamingID != nil && window.firstResponder is NSText
        check("keyboard: Return starts renaming in place, the name field has the focus", renaming, "renaming \(nav.renamingID != nil), responder \(type(of: window.firstResponder as Any))")
        if let editor = window.firstResponder as? NSText { editor.string = "zèbre.txt" }
        await key(Key.return, "\r")
        let renamed = await wait(15) { ((try? await api.listFolder(folder.id).files.contains { $0.name == "zèbre.txt" }) ?? false) }
        check("rename in place: confirmed by the server", renamed && nav.renamingID == nil)
        model.settings.gridView = false; try? await Task.sleep(nanoseconds: 700_000_000)
        if let a = model.children(of: folder.id).first(where: { $0.name == "alpha.txt" }) {
            window.makeFirstResponder(nil); nav.selection = [a.id]
            let before = QuickLookCoordinator.shared.presentations
            await key(Key.space, " ")
            let shown = await wait(10) { QuickLookCoordinator.shared.isVisible && QuickLookCoordinator.shared.itemID == a.id }
            let frame = AnchorRegistry.shared.screenFrame(a.id)
            check("Quick Look: Space opens the system panel on the selected file", shown && QuickLookCoordinator.shared.presentations == before + 1)
            check("Quick Look: the zoom starts from the item's picture on screen", frame.map { window.frame.intersects($0) && $0.width > 4 } ?? false, frame.map { "\(Int($0.width))×\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" } ?? "no frame")
            await key(Key.space, " ")
            let closed = await wait(5) { !QuickLookCoordinator.shared.isVisible }
            check("Quick Look: Space again closes it", closed)
            QuickLookCoordinator.shared.close()
        }
        if let k = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
            _ = k
            // the real menu item: its key equivalent is ⌘K and performing it opens the palette of the focused window
            func find(_ menu: NSMenu?) -> (NSMenu, Int)? {
                guard let menu else { return nil }
                menu.delegate?.menuNeedsUpdate?(menu); menu.update() // what happens when the person opens the menu
                for (i, item) in menu.items.enumerated() { if item.title.hasPrefix("Palette de commandes") { return (menu, i) }; if let hit = find(item.submenu) { return hit } }
                return nil
            }
            // menu commands are only valid for the active app's focused window: activate for a moment (under a second), then step back
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            defer { NSApp.deactivate() }
            NSApp.mainMenu?.update()
            let hit = find(NSApp.mainMenu)
            let equivalent = hit.map { $0.0.items[$0.1].keyEquivalent == "k" && $0.0.items[$0.1].keyEquivalentModifierMask == .command } ?? false
            if let hit { hit.0.performActionForItem(at: hit.1) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            // menus validate from the focused window: with nothing selected "Dupliquer" is off, with one file selected it is on
            func enabled(_ title: String) -> Bool? { func f(_ m: NSMenu?) -> NSMenuItem? { guard let m else { return nil }; m.delegate?.menuNeedsUpdate?(m); m.update(); for it in m.items { if it.title == title { return it }; if let h = f(it.submenu) { return h } }; return nil }; return f(NSApp.mainMenu)?.isEnabled }
            nav.selection = []; try? await Task.sleep(nanoseconds: 400_000_000)
            let offWhenEmpty = enabled("Dupliquer") == false
            if let a = model.children(of: folder.id).first(where: { !$0.isFolder }) { nav.selection = [a.id] }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let onWhenSelected = enabled("Dupliquer") == true
            nav.selection = []
            check("menus: commands enable and disable with the focused window's selection", offWhenEmpty && onWhenSelected, "empty→off \(offWhenEmpty), selected→on \(onWhenSelected)")
            check("⌘K: the menu command exists with that key equivalent and opens the command palette", equivalent && nav.showPalette, "item \(hit != nil), equivalent \(equivalent), enabled \(hit.map { $0.0.items[$0.1].isEnabled } ?? false), key window is main \(NSApp.keyWindow === window), active \(NSApp.isActive)")
        }
        await key(Key.escape)
        check("Escape closes it", !nav.showPalette)
        nav.showPalette = false

        // --- command palette: real commands ---
        nav.selection = []
        var openedWindow = false
        let commands = CommandCatalog.commands(model: model, nav: nav, openWindow: { openedWindow = true }, openSettings: {})
        CommandCatalog.results(for: "récents", commands: commands, model: model, nav: nav).first?.run()
        let went = nav.section == .recent
        nav.go(to: folder.id)
        CommandCatalog.results(for: "nouveau dossier", commands: commands, model: model, nav: nav).first?.run()
        let asked = nav.sheet == .newFolder(parent: folder.id); nav.sheet = nil
        CommandCatalog.results(for: "grille", commands: commands, model: model, nav: nav).first?.run()
        let grid = model.settings.gridView; model.settings.gridView = false
        CommandCatalog.results(for: "nouvelle fenêtre", commands: commands, model: model, nav: nav).first?.run()
        nav.go(to: nil)
        let hits = CommandCatalog.results(for: "alpha", commands: commands, model: model, nav: nav).filter { $0.group == .item }
        hits.first?.run()
        check("palette: \(commands.count) commands; go to section, new folder, grid, new window run for real", commands.count >= 20 && went && asked && grid && openedWindow)
        check("palette: finds a file of the mirror and takes you to it", nav.folderID == folder.id && nav.selection.compactMap { model.item($0)?.name } == ["alpha.txt"], "\(hits.count) hit(s)")

        // --- drag out: what a drop in the Finder would receive ---
        if let current = model.item(file.id) {
            let provider = Drops.provider(for: current, model: model)
            let type = (UTType(filenameExtension: current.fileExtension) ?? .data).identifier
            let got: String = await withCheckedContinuation { c in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard let url else { c.resume(returning: "error: \(error?.localizedDescription ?? "no file")"); return }
                    do { c.resume(returning: try Hashing.sha256Hex(of: url).sha256) } catch { c.resume(returning: "unreadable: \(error.localizedDescription)") }
                }
            }
            check("drag out: the dragged item delivers a verified file (same SHA-256 as the server)", got == current.sha256 && provider.hasItemConformingToTypeIdentifier(UTType.spdriveItem.identifier), "\(provider.suggestedName ?? "") \(type) \(got == current.sha256 ? "" : got)")
        }

        // --- a second window has its own navigator ---
        let mainsBefore = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count
        AppDelegate.openMainWindow?()
        let two = await wait(6) { NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count == mainsBefore + 1 }
        check("multiple windows: a second main window opens on the same account", two)
        if let extra = NSApp.windows.filter({ $0.isVisible && $0.canBecomeMain }).first(where: { $0 !== window }) { extra.close() }

        // --- a real conflict, settled as "keep mine as a new version" ---
        try? Data("version de départ".utf8).write(to: work.appendingPathComponent("accord.txt"))
        await model.upload([work.appendingPathComponent("accord.txt")], to: folder.id)
        _ = await wait(30) { model.children(of: folder.id).contains { $0.name == "accord.txt" && $0.versionID != nil } }
        if let base = model.children(of: folder.id).first(where: { $0.name == "accord.txt" }), let engine = model.engine {
            try? Data("version de l’autre appareil".utf8).write(to: work.appendingPathComponent("autre.txt"))
            _ = try? await UploadEngine(api: api, store: nil, deviceName: "Autre appareil").upload(file: work.appendingPathComponent("autre.txt"), to: .newVersion(fileID: base.id, folderID: folder.id, name: base.name, baseVersionID: base.versionID))
            // this Mac sends an edit derived from the version it knew: the queue names that version
            try? Data("version de ce Mac".utf8).write(to: work.appendingPathComponent("mien.txt"))
            _ = engine
            await model.uploadNewVersion(of: base, from: work.appendingPathComponent("mien.txt")) // `base` is what this Mac's mirror knew: now stale
            let raised = await wait(30) { model.conflicts.contains { $0.isOpen && $0.itemID == base.id } }
            let untouched = (try? await api.data(for: api.contentRequest(fileID: base.id)).0).map { String(decoding: $0, as: UTF8.self) }
            check("conflict: a stale edit raises a conflict and overwrites nothing", raised && untouched == "version de l’autre appareil", untouched ?? "")
            if let c = model.conflicts.first(where: { $0.isOpen && $0.itemID == base.id }) {
                nav.sheet = .conflict(c)
                let presented = await wait(6) { window.attachedSheet != nil }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                DevTour.snapshot("conflict-sheet", into: AppEnvironment.containerURL)
                check("conflict: the comparison sheet is presented", presented)
                nav.sheet = nil; try? await Task.sleep(nanoseconds: 700_000_000)
                let ok = await model.resolve(c, .mineAsVersion)
                let now = (try? await api.data(for: api.contentRequest(fileID: base.id)).0).map { String(decoding: $0, as: UTF8.self) }
                let d = try? await api.fileDetails(base.id)
                let copyGone = (c.copyID != nil) ? (((try? await api.item(c.copyID!, kind: .file)) ?? nil)?.trashedAt != nil) : false
                check("conflict: “keep mine” makes it version 3; the server's version stays in the history; the copy goes to the trash", ok && now == "version de ce Mac" && d?.versions.count == 3 && copyGone && !model.conflicts.contains { $0.isOpen && $0.id == c.id }, "\(d?.versions.count ?? 0) versions")
            }
        } else { check("conflict: base file uploaded", false) }

        // --- desktop drop zone: off by default, on and off again ---
        let wasOff = !model.settings.dropZone && !DropZoneController.shared.isShown
        model.settings.dropZone = true; DropZoneController.shared.update(model: model)
        let on = DropZoneController.shared.isShown, stillKey = NSApp.keyWindow !== NSApp.windows.first { $0 is NSPanel && $0.level == .floating }
        try? await Task.sleep(nanoseconds: 400_000_000)
        model.settings.dropZone = false; DropZoneController.shared.update(model: model)
        check("drop zone: off by default, shows without taking the key window, hides", wasOff && on && stillKey && !DropZoneController.shared.isShown)

        // --- Spotlight: metadata only, removable ---
        let attrs = SpotlightIndexer.attributes(for: file, path: "Autotest")
        check("Spotlight: the attribute set carries metadata only (no text content)", attrs.textContent == nil && attrs.contentDescription == nil && attrs.title == file.name)
        model.settings.spotlightIndex = true
        await SpotlightIndexer.shared.sync(model: model)
        let indexed = SpotlightIndexer.shared.lastIndexed
        let found = await wait(20) { await SpotlightIndexer.shared.count(named: "alpha.txt") >= 1 }
        model.settings.spotlightIndex = false
        await SpotlightIndexer.shared.removeAll()
        let removed = await wait(20) { await SpotlightIndexer.shared.count(named: "alpha.txt") == 0 }
        check("Spotlight: items indexed, found by name, then removed", indexed > 0 && found && removed, "\(indexed) indexed, found \(found), removed \(removed)")
        if model.meta.api >= 2 { await next2(model, api: api, store: store, folder: folder, work: work, record: record, wait: wait) }
        try? FileManager.default.removeItem(at: work)
        nav.go(to: nil); model.settings.gridView = false
    }

    /// SP Drive 2.0 against a 2.0 server. The AI provider of the test backend is a FAKE (Scripts/fake-ai.mjs): these checks prove the app's side of the protocol, not a model.
    static func next2(_ model: AppModel, api: APIClient, store: MetadataStore, folder: DriveItem, work: URL, record: (String, Bool, String) -> Void,
                      wait: (Double, @MainActor () async -> Bool) async -> Bool) async {
        func check(_ n: String, _ ok: Bool, _ detail: String = "") { record(n, ok, detail) }
        guard let next = model.next else { check("2.0: client available", false); return }
        let nav = model.nav
        check("2.0: capabilities read from GET /meta", model.meta.api == 2 && model.has(.collab) && model.has(.collections), model.meta.features.joined(separator: " "))
        let sessions = (try? await next.sessions()) ?? []
        let me = sessions.first(where: \.current)
        check("X-SPD-Client: this session is known to the server as macos/2.0.0", me?.client?.platform == "macos" && me?.client?.version == "2.0.0", "\(me?.client?.platform ?? "?")/\(me?.client?.version ?? "?") (\(me?.client?.os ?? "?"))")

        // --- a change made by another client arrives through the stream, without a poll ---
        let t0 = Date()
        let remote = try? await api.createFolder(parent: folder.id, name: "créé par un autre client")
        let pushed = await wait(4) { remote.map { model.item($0.id) != nil } ?? false }
        check("events: a change made elsewhere reaches the mirror in under 4 s (stream, not the 30 s poll)", pushed && model.status.events == .stream, String(format: "%.2f s", Date().timeIntervalSince(t0)))

        // --- search 2.0 ---
        let word = "zq\(Int(Date().timeIntervalSince1970) % 100000)x"
        try? Data("Procès-verbal\nLe \(word) de la coopérative est adopté.\nDépôt de garantie : 500 dollars avant le 1er juin.".utf8).write(to: work.appendingPathComponent("Procès-verbal.txt"))
        await model.upload([work.appendingPathComponent("Procès-verbal.txt")], to: folder.id)
        _ = await wait(30) { model.children(of: folder.id).contains { $0.name == "Procès-verbal.txt" && $0.versionID != nil } }
        guard let pv = model.children(of: folder.id).first(where: { $0.name == "Procès-verbal.txt" }) else { check("search: test document uploaded", false); return }
        let indexed = await wait(45) { ((try? await next.fileText(pv.id).status) ?? "") == "ready" }
        let hits = try? await next.search(word)
        let hit = hits?.files.first { $0.id == pv.id }
        check("search 2.0: a word found only inside a document is returned with a highlighted passage", indexed && hit?.match?.where == "content" && (hit?.match?.snippetRuns.contains { $0.matched && $0.text.lowercased() == word } ?? false), hit?.match?.snippet ?? "no hit")
        nav.go(to: nil); nav.searchText = word
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        DevTour.snapshot("search-content", into: AppEnvironment.containerURL)
        nav.searchText = ""

        // --- AI (fake provider) ---
        let providers = try? await next.aiProviders()
        let session = AskSession(); await session.load(model)
        session.question = "Quel est le montant du dépôt de garantie ?"; session.ask(model, scope: .files([pv.id]))
        _ = await wait(30) { session.turns.last?.streaming == false }
        let turn = session.turns.last
        check("AI: providers listed; creator and provider are told apart", providers?.enabled == true && providers?.providers.first { $0.id == "maclustr" }?.models.first?.creator != nil, "default \(providers?.default?.model ?? "none")")
        check("AI: a streamed answer with numbered sources (FAKE provider — no real model)", turn?.failure == nil && (turn?.answer.contains("[1]") ?? false) && turn?.sources.first?.fileId == pv.id && turn?.done != nil, turn?.failure ?? String((turn?.answer ?? "").prefix(80)))
        session.question = "xyzzyqq wobblefrotz"; session.ask(model, scope: .folder(folder.id))
        _ = await wait(30) { session.turns.last?.streaming == false }
        check("AI: nothing retrieved is said as such, without calling the model", session.turns.last?.done?.empty == true && session.turns.last?.answer.isEmpty == true)

        // --- collections ---
        let rule = CollectionRule(conditions: [RuleCondition(field: "name", op: "contains", value: .string("Procès")), RuleCondition(field: "folder", op: "is", value: .string(folder.id))])
        let made = try? await next.createCollection(CollectionDraft(name: "Autotest \(word)", icon: "doc.text", color: "teal", rule: rule))
        await model.refreshCollections()
        let listed = model.collections.first { $0.id == made?.id }
        check("collections: created, listed in the sidebar with its live count", listed?.count == 1, "count \(listed?.count ?? -1)")
        if let made { nav.collectionID = made.id; nav.section = .collections; try? await Task.sleep(nanoseconds: 1_200_000_000); DevTour.snapshot("collection", into: AppEnvironment.containerURL); try? await next.deleteCollection(made.id); await model.refreshCollections() }
        check("collections: deleted (files untouched)", !model.collections.contains { $0.id == made?.id } && model.item(pv.id) != nil)
        nav.section = .drive

        // --- versions and comparison ---
        try? Data("Procès-verbal\nLe \(word) de la coopérative est adopté à l'unanimité.\nDépôt de garantie : 750 dollars avant le 1er juin.\nProchaine assemblée en janvier.".utf8).write(to: work.appendingPathComponent("pv2.txt"))
        await model.uploadNewVersion(of: pv, from: work.appendingPathComponent("pv2.txt"))
        let two = await wait(30) { ((try? await next.versions(of: pv.id).versions.count) ?? 0) == 2 }
        let versions = (try? await next.versions(of: pv.id).versions) ?? []
        var diff: [LineDiff.Line] = []
        if versions.count == 2 {
            let a = work.appendingPathComponent("a.txt"), b = work.appendingPathComponent("b.txt")
            let s1 = try? await next.downloadVersion(fileID: pv.id, versionID: versions[1].id, to: a), s2 = try? await next.downloadVersion(fileID: pv.id, versionID: versions[0].id, to: b)
            if s1 == versions[1].sha256, s2 == versions[0].sha256, let x = try? String(contentsOf: a, encoding: .utf8), let y = try? String(contentsOf: b, encoding: .utf8) { diff = LineDiff.lines(x, y) ?? [] }
        }
        check("versions: timeline with author; text comparison shows what changed", two && versions.first?.createdBy?.me == true && diff.filter { $0.kind == .added }.count == 3 && diff.filter { $0.kind == .removed }.count == 2 && diff.filter { $0.kind == .same }.count == 1,
              "+\(diff.filter { $0.kind == .added }.count) −\(diff.filter { $0.kind == .removed }.count)")
        if let current = model.item(pv.id) { nav.go(to: folder.id); nav.sheet = .versions(current); try? await Task.sleep(nanoseconds: 2_000_000_000); DevTour.snapshot("versions-timeline", into: AppEnvironment.containerURL); nav.sheet = nil; try? await Task.sleep(nanoseconds: 700_000_000) }

        // --- activity, storage, duplicates ---
        let feed = (try? await next.fileActivity(pv.id).events) ?? []
        check("activity: the file's real audit trail (upload, then new version)", feed.map(\.action) == ["file.version_added", "file.uploaded"] && feed.allSatisfy { $0.actor.me == true }, feed.map(\.action).joined(separator: ", "))
        let overview = try? await next.storageOverview()
        let drill = try? await next.storageFolder(folder.id)
        check("storage: overview by kind and by folder, drill-down into a folder", (overview?.byKind.isEmpty == false) && (overview?.byFolder.isEmpty == false) && drill?.breadcrumbs.last?.id == folder.id, "\(overview?.byKind.count ?? 0) kinds, \(drill?.direct.files ?? 0) files here")
        let before = model.children(of: folder.id).count
        let dup = try? await next.duplicates()
        check("duplicates: listed, and looking deletes nothing", dup != nil && model.children(of: folder.id).count == before, "\(dup?.groups.count ?? -1) group(s)")

        // --- private sharing: owner side, then a folder shared WITH this account by the second test account ---
        let team = model.createFolder(in: folder.id, name: "Équipe")
        _ = await wait(20) { model.children(of: folder.id).contains { $0.name == "Équipe" && !model.isPending($0.id) } }
        if let teamFolder = model.children(of: folder.id).first(where: { $0.name == "Équipe" }), team != nil {
            let who = try? await next.resolveUser(email: "member@example.test")
            let added = try? await next.addMember(to: teamFolder.id, email: "member@example.test", as: .viewer, workspaceName: "Équipe test")
            let members = try? await next.members(of: teamFolder.id)
            check("sharing: a member is added by exact e-mail with a role; the folder becomes a named workspace", added?.role == .viewer && members?.members.count == 1 && members?.folder.workspaceName == "Équipe test", who?.displayName ?? "second account not found")
            nav.go(to: folder.id); nav.sheet = .members(teamFolder); try? await Task.sleep(nanoseconds: 1_800_000_000); DevTour.snapshot("members-sheet", into: AppEnvironment.containerURL); nav.sheet = nil; try? await Task.sleep(nanoseconds: 600_000_000)
            if let who { try? await next.removeMember(of: teamFolder.id, userID: who.userId) }
            let gone = try? await next.members(of: teamFolder.id); check("sharing: access removed", gone?.members.isEmpty == true)
        } else { check("sharing: folder created", false) }
        await model.refreshGrants()
        if let g = model.grants.first(where: { $0.role == .editor }) {
            let listing = try? await next.sharedChildren(grant: g.grantId)
            try? Data("apport de l’autotest".utf8).write(to: work.appendingPathComponent("apport.txt"))
            let sent = try? await next.uploadShared(grant: g.grantId, file: work.appendingPathComponent("apport.txt"), name: "apport \(word).txt")
            let after = try? await next.sharedChildren(grant: g.grantId)
            check("shared with me: an editor browses the folder and uploads into it", listing?.folder.isGrantRoot == true && (listing?.files.isEmpty == false) && sent != nil && (after?.files.contains { $0.id == sent?.file.id } ?? false), "\(g.displayName), \(after?.files.count ?? 0) files")
            if let sent { try? await next.sharedTrash(grant: g.grantId, fileIDs: [sent.file.id]) }
        } else { check("shared with me: a folder shared by the second account is listed (run Scripts/seed-next.sh --collab)", false, "\(model.grants.count) grant(s)") }
        if let u = model.grants.first(where: { $0.role == .uploader }) {
            var forbidden = false
            do { _ = try await next.sharedChildren(grant: u.grantId) } catch { forbidden = NextError.wrap(error).isForbidden }
            let dropped = try? await next.uploadShared(grant: u.grantId, file: work.appendingPathComponent("apport.txt"), name: "dépôt \(word).txt")
            check("shared with me: a depositor cannot list (403) but can send a file in", forbidden && dropped?.file.name == "dépôt \(word).txt")
        }

        // --- QR code, devices, administration ---
        let link = "https://drive.spboucher.ai/s/EXEMPLE-\(word)"
        var decoded: String?
        if let img = QRCode.image(link), let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff) {
            decoded = (CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])?.features(in: ci).first as? CIQRCodeFeature)?.messageString
        }
        check("QR code: generated on this Mac and reads back as the link", decoded == link)
        check("devices: sessions listed with platform and app version", sessions.contains { $0.client != nil } && sessions.contains(where: \.current), "\(sessions.count) session(s)")
        if model.isAdmin { let sys = try? await next.adminSystem(); check("administration: infrastructure view readable by an administrator", sys?.version == "2.0.0" && sys?.worker != nil, "worker alive \(String(describing: sys?.worker?.alive))") }
        await onScreen(model, api: api, next: next, folder: folder, pv: pv, record: record, wait: wait)
        nav.section = .drive; nav.go(to: nil)
    }

    /// The same things done ON SCREEN: sheets and windows are really presented, and their own controls are pressed
    /// through the accessibility tree of this app (what a click does), then the server or the model is read.
    static func onScreen(_ model: AppModel, api: APIClient, next: NextClient, folder: DriveItem, pv: DriveItem, record: (String, Bool, String) -> Void,
                         wait: (Double, @MainActor () async -> Bool) async -> Bool) async {
        func check(_ n: String, _ ok: Bool, _ detail: String = "") { record("on screen — " + n, ok, detail) }
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func appear(_ id: String, _ seconds: Double = 12) async -> Bool { await wait(seconds) { AX.element(id: id) != nil } }
        func shot(_ name: String, window: NSWindow? = nil) { DevTour.snapshot(name, into: AppEnvironment.containerURL, window: window) }
        let nav = model.nav
        nav.section = .drive; nav.go(to: folder.id); nav.selection = [pv.id]; await pause(0.6)
        record("on screen — the accessibility API answers for this process (the checks below press real controls through it)", AX.available, "")

        // --- ask a document, then click the citation ---
        UserDefaults.standard.set("Quel est le montant du dépôt de garantie ?", forKey: "spdAsk")
        nav.sheet = .ask(pv)
        let cited = await wait(30) { AX.element(labelPrefix: "Source 1") != nil }
        shot("ask-sheet")
        UserDefaults.standard.removeObject(forKey: "spdAsk")
        nav.go(to: nil); nav.selection = []
        AX.press(AX.element(labelPrefix: "Source 1"))
        let revealed = await wait(6) { nav.sheet == nil && nav.selection == [pv.id] && nav.folderID == folder.id }
        check("a citation of the answer, pressed, closes the sheet and shows its file selected in its folder", cited && revealed, "source shown \(cited)")
        nav.sheet = nil; await pause(0.6)

        // --- the "Demander à mon Drive" window ---
        AskWindow.open()
        let askWindow = await wait(8) { NSApp.windows.contains { $0.isVisible && $0.title == "Demander à mon Drive" } }
        let field = await appear("ask-field", 10)
        if let w = NSApp.windows.first(where: { $0.title == "Demander à mon Drive" }) { shot("ask-window", window: w); w.close() }
        NSApp.deactivate()
        check("the “Demander à mon Drive” window opens with its question field", askWindow && field, "window \(askWindow), field \(field), opener \(AppDelegate.openAskWindow != nil), titles \(NSApp.windows.filter(\.isVisible).map(\.title))")

        // --- Settings › Compte: devices list, and the external-AI consent switch ---
        UserDefaults.standard.set("account", forKey: "settingsTab")
        NSApp.activate(ignoringOtherApps: true); AppDelegate.openSettings?()
        let toggle = await appear("ai-external-toggle", 12)
        let devices = AX.count(id: "device-row")
        let settings = NSApp.windows.first { w in w.isVisible && !w.canBecomeMain || w.title == "Compte" || w.identifier?.rawValue.contains("Settings") == true }
        shot("settings-account", window: settings)
        check("Settings › Compte lists the connected devices", toggle && devices >= 1, "\(devices) device row(s)")
        let before = (try? await next.aiProviders().external?.account) ?? false
        AX.press(AX.element(id: "ai-external-toggle"))
        let flipped = await wait(8) { ((try? await next.aiProviders().external?.account) ?? before) != before }
        AX.press(AX.element(id: "ai-external-toggle"))
        let restored = await wait(8) { ((try? await next.aiProviders().external?.account) ?? !before) == before }
        check("the external-AI consent switch changes the account's flag on the server, and back", flipped && restored, "was \(before)")
        settings?.close(); UserDefaults.standard.set("general", forKey: "settingsTab"); NSApp.deactivate()

        // --- saving a collection from the rule editor ---
        let rule = CollectionRule(conditions: [RuleCondition(field: "folder", op: "is", value: .string(folder.id)), RuleCondition(field: "ext", op: "is", value: .string("txt"))])
        if let made = try? await next.createCollection(CollectionDraft(name: "Écran \(Int(Date().timeIntervalSince1970) % 100000)", icon: "doc.text", color: "green", rule: rule)) {
            await model.refreshCollections(); try? await Task.sleep(nanoseconds: 1_100_000_000)
            nav.sheet = .collection(model.collections.first { $0.id == made.id })
            let button = await appear("save-collection")
            _ = await wait(6) { AX.element(labelPrefix: "Enregistrer") != nil }
            await pause(1.2) // the live preview settles
            shot("collection-editor")
            AX.press(AX.element(id: "save-collection"))
            let saved = await wait(8) { nav.sheet == nil && nav.section == .collections && nav.collectionID == made.id }
            let after = try? await next.collections().first { $0.id == made.id }
            check("the rule editor's Save button saves the collection and shows it", button && saved && (after?.updatedAt ?? .distantPast) > (made.updatedAt ?? .distantFuture), "updated \(after?.updatedAt.map { Fmt.date($0) } ?? "?")")
            nav.sheet = nil; try? await next.deleteCollection(made.id); await model.refreshCollections()
        } else { check("collection created for the editor", false) }

        // --- storage: drill down into a folder by pressing its bar ---
        nav.section = .storage
        let bars = await appear("storage-folder", 15)
        let rootOnly = AX.element(id: "storage-crumb-1") == nil
        AX.press(AX.element(id: "storage-folder"))
        let inside = await wait(8) { AX.element(id: "storage-crumb-1") != nil }
        shot("storage-drilldown")
        check("Storage: pressing a folder's bar drills down into it (breadcrumb grows)", bars && rootOnly && inside, "bars \(bars) (\(AX.count(id: "storage-folder"))), root crumb \(AX.element(id: "storage-crumb-0") != nil)")

        // --- share sheet: create a link with the sheet's button, see its QR code ---
        nav.section = .drive; nav.go(to: folder.id); nav.selection = [pv.id]; await pause(0.5)
        let linksBefore = ((try? await api.shares(of: pv)) ?? []).count
        nav.sheet = .share(pv)
        let createShare = await appear("create-share")
        AX.press(AX.element(id: "create-share"))
        let qr = await wait(10) { AX.element(labelPrefix: "Code QR de l’adresse du lien") != nil }
        shot("share-sheet-qr")
        let links = (try? await api.shares(of: pv)) ?? []
        check("Share sheet: its button creates the link on the server and the QR code of the address is shown", createShare && qr && links.count == linksBefore + 1, "\(links.count) link(s)")
        for l in links { try? await api.revokeShare(l.id) }
        nav.sheet = nil; await pause(0.7)

        // --- deposit portal created from the extended sheet ---
        let portalsBefore = Set(((try? await api.portals()) ?? []).map(\.id))
        if let f = model.item(folder.id) {
            nav.sheet = .portal(folder: f)
            let createPortal = await appear("create-portal")
            await pause(0.5); shot("portal-sheet")
            AX.press(AX.element(id: "create-portal"))
            let made = await wait(10) { ((try? await api.portals()) ?? []).contains { !portalsBefore.contains($0.id) && $0.folderId == folder.id } }
            let portal = ((try? await api.portals()) ?? []).first { !portalsBefore.contains($0.id) }
            check("Portal sheet: its button creates the deposit link on the server", createPortal && made && portal?.state == "open", portal?.title ?? "none")
            if let portal { try? await api.revokePortal(portal.id, delete: true) }
            nav.sheet = nil; await pause(0.7)
        }

        // --- AI organisation suggestions: nothing changes until "Appliquer" is pressed on a line ---
        if model.has(.ai), let target = model.children(of: folder.id).first(where: { $0.name == "alpha.txt" }) {
            nav.sheet = .suggest([target])
            let offered = await appear("apply-name", 30)
            shot("suggestions-sheet")
            let untouched = ((try? await api.item(target.id, kind: .file)) ?? nil)?.name == "alpha.txt"
            AX.press(AX.element(id: "apply-name"))
            let applied = await wait(15) { (((try? await api.item(target.id, kind: .file)) ?? nil)?.name ?? "").hasPrefix("Classé") }
            check("Suggestions (FAKE provider): the proposal changes nothing by itself; pressing “Appliquer” renames the file on the server", offered && untouched && applied, ((try? await api.item(target.id, kind: .file)) ?? nil)?.name ?? "?")
            nav.sheet = nil; await pause(0.6)
        }
    }

    /// Dumps the state of the menu commands as AppKit sees them (diagnostic).
    static func menuProbe(_ model: AppModel) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let any = model.children(of: model.rootID ?? "").first { model.nav.selection = [any.id] }
        try? await Task.sleep(nanoseconds: 500_000_000)
        var lines: [String] = ["bridge \(String(describing: model.menuBridge.focus))", "active \(NSApp.isActive) key \(NSApp.keyWindow === window) phase \(model.phase) activeNav \(model.activeNav != nil)"]
        func walk(_ m: NSMenu?, _ depth: Int) { guard let m else { return }; m.delegate?.menuNeedsUpdate?(m); m.update(); for it in m.items where !it.isSeparatorItem { lines.append(String(repeating: "  ", count: depth) + "\(it.isEnabled ? "on " : "off") \(it.title) [\(it.keyEquivalent)] action=\(it.action.map { NSStringFromSelector($0) } ?? "nil") target=\(it.target.map { String(describing: type(of: $0)) } ?? "nil")"); walk(it.submenu, depth + 1) } }
        walk(NSApp.mainMenu, 0)
        NSApp.deactivate()
        try? lines.joined(separator: "\n").write(to: AppEnvironment.containerURL.appendingPathComponent("menuprobe.txt"), atomically: true, encoding: .utf8)
    }

    /// Times how long the window takes to show a large folder (from the navigation to the frame being committed), in list and in grid.
    static func perfProbe(_ model: AppModel) async {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let root = model.rootID, let big = model.children(of: root).first(where: { $0.name == "Mille fichiers" }) else { return }
        let nav = model.nav
        var lines: [String] = ["items \(model.children(of: big.id).count)"]
        func frame() async { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { CATransaction.setCompletionBlock { c.resume() }; CATransaction.flush() } } }
        for grid in [false, true] {
            model.settings.gridView = grid
            var samples: [Double] = []
            for _ in 0..<5 {
                nav.go(to: nil); await frame(); try? await Task.sleep(nanoseconds: 500_000_000)
                let t = CFAbsoluteTimeGetCurrent()
                nav.go(to: big.id); await frame()
                samples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            lines.append("\(grid ? "grid" : "list") ms: " + samples.map { String(format: "%.0f", $0) }.joined(separator: " ") + String(format: " (median %.0f)", samples.sorted()[2]))
        }
        model.settings.gridView = false; nav.go(to: nil)
        try? lines.joined(separator: "\n").write(to: AppEnvironment.containerURL.appendingPathComponent("perf.txt"), atomically: true, encoding: .utf8)
    }

    /// Only the on-screen checks (`-spdOnScreen YES`), with their own small set-up: quicker to iterate on than the whole self-test.
    static func onScreenOnly(_ model: AppModel) async {
        var checks: [Check] = []
        func wait(_ seconds: Double, _ cond: @MainActor () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 150_000_000) }
            return false
        }
        let out = AppEnvironment.containerURL.appendingPathComponent("onscreen.json")
        try? FileManager.default.removeItem(at: out)
        defer { try? JSONEncoder().encode(checks).write(to: out) }
        guard let api = model.api, let next = model.next, await wait(20, { model.rootID != nil && model.status.lastSync != nil }), let root = model.rootID else { return }
        let work = AppEnvironment.containerURL.appendingPathComponent("onscreen-src", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: work) }
        let name = "Écran \(Int(Date().timeIntervalSince1970))"
        _ = model.createFolder(in: root, name: name)
        guard await wait(20, { model.children(of: root).contains { $0.name == name && !model.isPending($0.id) } }), let folder = model.children(of: root).first(where: { $0.name == name }) else { return }
        try? Data("Procès-verbal\nDépôt de garantie : 500 dollars avant le 1er juin.".utf8).write(to: work.appendingPathComponent("Procès-verbal.txt"))
        try? Data("alpha".utf8).write(to: work.appendingPathComponent("alpha.txt"))
        await model.upload([work.appendingPathComponent("Procès-verbal.txt"), work.appendingPathComponent("alpha.txt")], to: folder.id)
        guard await wait(30, { model.children(of: folder.id).filter { $0.versionID != nil }.count == 2 }), let pv = model.children(of: folder.id).first(where: { $0.name == "Procès-verbal.txt" }) else { return }
        _ = await wait(45) { ((try? await next.fileText(pv.id).status) ?? "") == "ready" }
        await onScreen(model, api: api, next: next, folder: folder, pv: pv, record: { n, ok, d in checks.append(Check(name: n, ok: ok, detail: d)) }, wait: wait)
        if let f = model.item(folder.id) { model.trash([f]) }
    }
}
#endif
