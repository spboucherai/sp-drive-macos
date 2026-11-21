// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/SPDriveApp.swift
// Description      : Entry point of SP Drive: main windows (several can be open
//                    on the same account), the settings window and the menu bar
//                    Command Center, all on one model.
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

import CoreSpotlight
import SwiftUI

@main
struct SPDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(AppEnvironment.productName, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 540)
                .task { delegate.model = model; await model.bootstrap() }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.reveal(itemID: id) } // a Spotlight result of SP Drive
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model, bridge: model.menuBridge) }

        Window("Demander à mon Drive", id: "ask") {
            if model.phase == .signedIn, !model.locked { AskView(model: model, nav: nil, item: nil).frame(minWidth: 520, minHeight: 560) }
            else { SPDEmptyState(symbol: "sparkles", title: "SP Drive AI", message: "Connectez-vous à SP Drive pour poser des questions à vos documents.").frame(minWidth: 520, minHeight: 400) }
        }
        .defaultSize(width: 640, height: 720)

        Settings { SettingsView().environment(model) }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarIcon }, set: { model.settings.showMenuBarIcon = $0 })) {
            MenuBarView().environment(model)
        } label: { MenuBarLabel().environment(model) }
        .menuBarExtraStyle(.window)
    }
}
