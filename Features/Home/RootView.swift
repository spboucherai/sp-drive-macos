// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Home/RootView.swift
// Description      : Root of one window: its own navigator, then launching,
//                    sign-in, the main interface, and the lock screen above it
//                    when the biometric lock is on. Several windows can be open
//                    on the same account.
// Module           : Features
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

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var nav: Navigator?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ZStack {
            if let nav {
                switch model.phase {
                case .launching: ProgressView().controlSize(.large)
                case .signedOut: LoginView()
                case .signedIn: MainView().environment(nav).focusedSceneValue(\.spdNavigator, nav)
                }
                if model.locked, model.phase == .signedIn { LockedView().transition(.opacity) }
            }
        }
        .spdMotion(.reveal, value: model.phase)
        .spdMotion(.reveal, value: model.locked)
        .onAppear {
            if nav == nil { nav = model.claimNavigator() }; if model.activeNav == nil { model.activeNav = nav }
            AppDelegate.openAskWindow = { openWindow(id: "ask") }; AppDelegate.openSettings = { openSettings() }
        }
        .background(WindowReader { w in
            guard let w else { return }
            if w.isKeyWindow, let nav { model.activeNav = nav }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in MainActor.assumeIsolated { if let nav = self.nav { model.activeNav = nav } } }
        })
        .onDisappear { if let nav { model.releaseNavigator(nav) } }
    }
}
