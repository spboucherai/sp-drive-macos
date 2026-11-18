// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/DevTour.swift
// Description: Development variant only: walks through every screen of the app and saves a picture of its own window for each (visual checks without capturing the screen, and a smoke test that no screen crashes).
#if SPD_DEV
import AppKit
import SPDriveCore
import SwiftUI

@MainActor
enum DevTour {
    static func snapshot(_ name: String, into dir: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0.className.contains("StatusBar")) }
        // the sheet when there is one, otherwise the main window
        guard let main = windows.first(where: { $0.canBecomeMain }) else { return }
        let target = main.attachedSheet ?? main
        guard let view = target.contentView?.superview ?? target.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
    static func run(_ model: AppModel, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nav = model.nav
        func step(_ name: String, wait: Double = 1.0, _ setup: () -> Void) async {
            setup()
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            snapshot(name, into: dir)
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let root = model.rootID ?? ""
        let demo = model.children(of: root).first { $0.name == "Démo" }
        let files = demo.map { model.children(of: $0.id) } ?? []
        let file = files.first { !$0.isFolder && $0.versionCount > 1 } ?? files.first { !$0.isFolder }
        await step("01-drive-list") { nav.section = .drive; nav.folderID = nil; model.settings.gridView = false }
        await step("02-folder-list") { nav.folderID = demo?.id; if let file { nav.selection = [file.id] } }
        await step("03-inspector") { nav.showInspector = true }
        await step("04-grid") { nav.showInspector = false; model.settings.gridView = true }
        await step("05-search") { model.settings.gridView = false; nav.folderID = nil; nav.searchText = "rapport" }
        await step("06-search-filter") { nav.searchText = ""; nav.filter.category = .pdf }
        await step("07-recent") { nav.filter = LocalSearch(); nav.section = .recent }
        await step("08-favorites") { nav.section = .favorites }
        await step("09-offline") { nav.section = .offline }
        await step("10-shared", wait: 1.5) { nav.section = .shared }
        await step("11-portals", wait: 1.5) { nav.section = .portals }
        await step("12-transfers") { nav.section = .transfers }
        await step("13-downloads") { nav.section = .downloads }
        await step("14-conflicts") { nav.section = .conflicts }
        await step("15-trash") { nav.section = .trash }
        await step("16-storage", wait: 1.5) { nav.section = .storage }
        nav.section = .drive; nav.folderID = demo?.id
        if let file {
            await step("17-sheet-share", wait: 1.8) { nav.sheet = .share(file) }
            await step("18-sheet-versions", wait: 1.8) { nav.sheet = nil }; nav.sheet = .versions(file); try? await Task.sleep(nanoseconds: 1_800_000_000); snapshot("18-sheet-versions", into: dir)
            nav.sheet = nil; try? await Task.sleep(nanoseconds: 700_000_000)
            await step("19-sheet-rename") { nav.sheet = .rename(file) }
            nav.sheet = nil; try? await Task.sleep(nanoseconds: 700_000_000)
            await step("20-sheet-move") { nav.sheet = .move([file]) }
            nav.sheet = nil; try? await Task.sleep(nanoseconds: 700_000_000)
        }
        if let demo { await step("21-sheet-portal") { nav.sheet = .portal(folder: demo) }; nav.sheet = nil; try? await Task.sleep(nanoseconds: 700_000_000) }
        await step("22-sheet-newfolder") { nav.sheet = .newFolder(parent: root) }
        nav.sheet = nil
        try? "done".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
