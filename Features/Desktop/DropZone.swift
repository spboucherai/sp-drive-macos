// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Desktop/DropZone.swift
// Description      : The optional Desktop Drop Zone: a small floating tile (off
//                    by default) that accepts files dragged from anywhere and
//                    sends them to a chosen folder of Mon Drive. It never takes
//                    the focus, stays out of the way (dimmed until a drag
//                    approaches), can be moved, and remembers its place.
// Module           : Features
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-19
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

import AppKit
import SPDriveCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class DropZoneController {
    static let shared = DropZoneController()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    var isShown: Bool { panel?.isVisible ?? false }

    /// Shows or hides the tile according to the setting and the session.
    func update(model: AppModel) {
        let wanted = model.settings.dropZone && model.phase == .signedIn && !model.locked
        if wanted, panel == nil { show(model) } else if !wanted { hide() }
    }
    private func show(_ model: AppModel) {
        let side: CGFloat = 96
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]; p.isMovableByWindowBackground = true; p.becomesKeyOnlyIfNeeded = true
        p.isExcludedFromWindowsMenu = true; p.setAccessibilityTitle("Zone de dépôt SP Drive")
        p.contentView = NSHostingView(rootView: DropZoneView(model: model))
        let d = AppEnvironment.defaults
        if d.object(forKey: "dropZoneX") != nil, NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: d.double(forKey: "dropZoneX") + side / 2, y: d.double(forKey: "dropZoneY") + side / 2)) }) {
            p.setFrameOrigin(NSPoint(x: d.double(forKey: "dropZoneX"), y: d.double(forKey: "dropZoneY")))
        } else if let v = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: v.maxX - side - 20, y: v.minY + 20)) }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak p] _ in
            MainActor.assumeIsolated {
                guard let o = p?.frame.origin else { return }
                AppEnvironment.defaults.set(Double(o.x), forKey: "dropZoneX"); AppEnvironment.defaults.set(Double(o.y), forKey: "dropZoneY")
            }
        }
        p.orderFrontRegardless() // shown without activating the app or taking the key window
        panel = p
    }
    func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }; moveObserver = nil
        panel?.orderOut(nil); panel = nil
    }
}

struct DropZoneView: View {
    let model: AppModel
    @State private var targeted = false
    @State private var hovered = false
    @State private var flash = false

    private var destination: DriveItem? { (model.settings.dropZoneFolderID.flatMap { model.item($0) }).flatMap { $0.isTrashed ? nil : $0 } ?? model.rootID.flatMap { model.item($0) } }
    var body: some View {
        let name = destination.map { $0.isRoot ? "Mon Drive" : $0.name } ?? "Mon Drive"
        VStack(spacing: 3) {
            Image(systemName: flash ? "checkmark" : "arrow.down.doc").font(.system(size: 20, weight: .medium)).foregroundStyle(targeted || flash ? SPDTheme.onBrand : SPDTheme.brand).contentTransition(.symbolEffect(.replace))
            Text(name).font(SPDTheme.Typo.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(targeted || flash ? SPDTheme.onBrand : SPDTheme.textSecondary).padding(.horizontal, 4)
        }
        .frame(width: 72, height: 72)
        .background {
            if targeted || flash { RoundedRectangle(cornerRadius: SPDTheme.Radius.xl, style: .continuous).fill(SPDTheme.brand) }
            else { RoundedRectangle(cornerRadius: SPDTheme.Radius.xl, style: .continuous).fill(.regularMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: SPDTheme.Radius.xl, style: .continuous).strokeBorder(targeted ? SPDTheme.brand : SPDTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: targeted ? [] : [4, 3])))
        .scaleEffect(targeted ? 1.12 : 1)
        .opacity(targeted || hovered || flash ? 1 : 0.55)
        .spdElevation(targeted ? .e3 : .e1)
        .frame(width: 96, height: 96)
        .onHover { hovered = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard let dest = destination else { return false }
            let ok = Drops.handle(providers, into: dest.id, model: model)
            if ok { flash = true; Task { try? await Task.sleep(nanoseconds: 1_200_000_000); flash = false } }
            return ok
        }
        .spdMotion(.drop, value: targeted).spdMotion(.hover, value: hovered).spdMotion(.reveal, value: flash)
        .contextMenu {
            Text("Dépose dans « \(name) »")
            Button("Ouvrir SP Drive") { AppDelegate.showMainWindow() }
            Button("Masquer la zone de dépôt") { model.settings.dropZone = false; DropZoneController.shared.update(model: model) }
        }
        .help("Glissez des fichiers ici pour les envoyer dans « \(name) »")
        .accessibilityElement().accessibilityLabel("Zone de dépôt SP Drive, destination \(name)")
    }
}
