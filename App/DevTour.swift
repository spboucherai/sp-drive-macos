// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/DevTour.swift
// Description      : Development variant only: walks through every screen of
//                    the app and saves a picture of its own window for each
//                    (visual checks without capturing the screen, and a smoke
//                    test that no screen crashes). The menu bar Command Center
//                    is rendered in a window of its own for its picture.
// Module           : App
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-18
// Last Modified    : 2026-11-19
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : None specified (no license file in this repository)
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

#if SPD_DEV
import AppKit
import SPDriveCore
import SwiftUI

@MainActor
enum DevTour {
    static func snapshot(_ name: String, into dir: URL, window: NSWindow? = nil) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0.className.contains("StatusBar")) }
        // the sheet when there is one, otherwise the main window
        guard let main = window ?? windows.first(where: { $0.canBecomeMain }) else { return }
        let target = main.attachedSheet ?? main
        guard let view = target.contentView?.superview ?? target.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
    static func run(_ model: AppModel, into dir: URL) async {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nav = model.nav
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func step(_ name: String, wait: Double = 0.9, _ setup: () -> Void) async { setup(); await pause(wait); snapshot(name, into: dir) }
        func sheet(_ name: String, _ kind: SheetKind) async { nav.sheet = kind; await pause(1.6); snapshot(name, into: dir); nav.sheet = nil; await pause(0.7) }
        await pause(2.5)
        let root = model.rootID ?? ""
        let top = model.children(of: root)
        let atelier = top.first { $0.name == "Atelier" } ?? top.first { $0.isFolder }
        let photos = atelier.flatMap { a in model.children(of: a.id).first { $0.name.hasPrefix("Photos") } }
        let client = (atelier.flatMap { a in model.children(of: a.id).first { $0.name.hasPrefix("Dossiers") } }).flatMap { d in model.children(of: d.id).first }
        let docs = client.map { model.children(of: $0.id) } ?? []
        let file = docs.first { !$0.isFolder && $0.versionCount > 1 } ?? docs.first { !$0.isFolder }
        await step("01-drive-list") { nav.section = .drive; nav.folderID = nil; model.settings.gridView = false }
        await step("02-folder-list") { nav.go(to: client?.id); if let file { nav.selection = [file.id] } }
        await step("03-inspector", wait: 1.6) { nav.showInspector = true }
        await step("04-rename-inline") { nav.showInspector = false; nav.renamingID = file?.id }
        await step("05-grid-thumbnails", wait: 2.2) { nav.renamingID = nil; model.settings.gridView = true; nav.go(to: photos?.id); nav.selection = Set(model.children(of: photos?.id ?? "").prefix(1).map(\.id)) }
        await step("06-grid-inspector", wait: 1.6) { nav.showInspector = true }
        await step("07-grid-folders") { nav.showInspector = false; nav.go(to: client?.id) }
        await step("08-palette") { nav.showPalette = true }
        nav.showPalette = false; await pause(0.4)
        await step("09-search") { model.settings.gridView = false; nav.go(to: nil); nav.searchText = "plan" }
        await step("10-search-empty") { nav.searchText = "introuvable-xyz" }
        await step("11-search-filter") { nav.searchText = ""; nav.filter.category = .image }
        await step("12-recent") { nav.filter = LocalSearch(); nav.section = .recent }
        await step("13-favorites") { nav.section = .favorites }
        await step("14-offline") { nav.section = .offline }
        await step("15-shared", wait: 1.5) { nav.section = .shared }
        await step("16-portals", wait: 1.5) { nav.section = .portals }
        await step("17-transfers", wait: 1.2) { nav.section = .transfers }
        await step("18-conflicts") { nav.section = .conflicts }
        await step("19-trash") { nav.section = .trash }
        await step("20-storage", wait: 1.5) { nav.section = .storage }
        nav.section = .drive; nav.go(to: client?.id); await pause(0.5)
        if let file {
            await sheet("21-sheet-share", .share(file)); await sheet("22-sheet-versions", .versions(file)); await sheet("23-sheet-move", .move([file]))
        }
        if let atelier { await sheet("24-sheet-portal", .portal(folder: atelier)) }
        await sheet("25-sheet-newfolder", .newFolder(parent: root))
        // SP Drive 2.0 screens (only what the connected server offers)
        if model.has(.contentSearch) { await step("30-search-content", wait: 2.2) { nav.section = .drive; nav.go(to: nil); nav.searchText = "couleur" }; nav.searchText = "" }
        if model.has(.semantic) { await step("31-search-semantic", wait: 2.5) { nav.searchText = "choix de typographie"; nav.searchSemantic = true }; nav.searchSemantic = false; nav.searchText = "" }
        if model.isAvailable(.collections) { await step("32-collection", wait: 1.6) { nav.collectionID = model.collections.first?.id; nav.section = .collections }; await sheet("33-sheet-collection-rule", .collection(model.collections.first)) }
        if model.isAvailable(.sharedWithMe) { await step("34-shared-with-me", wait: 1.5) { nav.section = .sharedWithMe } }
        if model.isAvailable(.activity) { await step("35-activity", wait: 1.6) { nav.section = .activity } }
        if model.has(.storage) { await step("36-storage-center", wait: 2.5) { nav.section = .storage } }
        if model.isAvailable(.admin) { await step("37-admin", wait: 1.8) { nav.section = .admin } }
        nav.section = .drive; nav.go(to: client?.id); await pause(0.5)
        if let file, model.has(.ai) { nav.sheet = .ask(file); await pause(1.8); snapshot("38-sheet-ask", into: dir); nav.sheet = nil; await pause(0.7) }
        if let atelier, model.has(.collab) { await sheet("39-sheet-members", .members(atelier)) }
        if let c = model.conflicts.first(where: \.isOpen) { nav.sheet = .conflict(c); await pause(3.0); snapshot("26-sheet-conflict", into: dir); nav.sheet = nil; await pause(0.7) }
        // the Command Center, in a plain window (the status item's own popover cannot be opened from code)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 348, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: MenuBarView().environment(model).background(SPDTheme.surfaceRaised))
        host.setContentSize(host.contentView?.fittingSize ?? NSSize(width: 348, height: 480))
        if let m = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { host.setFrameOrigin(NSPoint(x: m.frame.minX + 40, y: m.frame.minY + 40)) }
        host.orderFront(nil); await pause(1.2)
        snapshot("27-menubar-command-center", into: dir, window: host)
        host.orderOut(nil)
        try? "done".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
