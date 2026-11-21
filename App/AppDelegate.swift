// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/AppDelegate.swift
// Description      : Application lifecycle: SP Drive keeps syncing from the
//                    menu bar when its window is closed, resumes after sleep,
//                    and re-locks after a period away when the biometric lock
//                    is on.
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

import AppKit
import Quartz

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// Opens the main window (set by the views, which own SwiftUI's window actions).
    static var openMainWindow: (() -> Void)?
    /// Opens the "Demander à mon Drive" window.
    static var openAskWindow: (() -> Void)?
    /// Opens the Settings window (SwiftUI's own action, captured by a view).
    static var openSettings: (() -> Void)?
    private var hasMainWindow: Bool { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }
    /// Brings a main window forward, opening one when none is left.
    static func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }

    // The Quick Look panel looks for its controller along the responder chain, which ends here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { QuickLookCoordinator.shared.adopt(panel) } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { QuickLookCoordinator.shared.release(panel) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model?.engine?.transfers.kick(); await self?.model?.syncNow() } // back from sleep: look at the server now
        }
        // a launch by the person shows the window even when the system restored none; a launch at login stays in the menu bar
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in if self?.hasMainWindow == false { AppDelegate.openMainWindow?() } } }
    }
    /// Closing the window does not stop syncing: the menu bar item stays (unless the person hid it, then the app quits with its last window).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(model?.settings.showMenuBarIcon ?? true) }
    func applicationDidBecomeActive(_ notification: Notification) { model?.appBecameActive() }
    func applicationDidResignActive(_ notification: Notification) { model?.appResignedActive() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !hasMainWindow, let open = AppDelegate.openMainWindow { open(); return false }
        return true
    }
}
