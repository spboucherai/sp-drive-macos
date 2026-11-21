// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/Settings.swift
// Description      : The person's preferences (Finder integration,
//                    notifications, bandwidth limits, parallel transfers,
//                    biometric lock), kept in the shared defaults.
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

import Foundation
import Observation

@MainActor @Observable final class AppSettings {
    private let d = AppEnvironment.defaults
    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    /// SP Drive appears as a location in the Finder.
    var finderIntegration: Bool { didSet { d.set(finderIntegration, forKey: "finderIntegration") } }
    var notifyTransfers: Bool { didSet { d.set(notifyTransfers, forKey: "notifyTransfers") } }
    var notifyConflicts: Bool { didSet { d.set(notifyConflicts, forKey: "notifyConflicts") } }
    var notifyDeposits: Bool { didSet { d.set(notifyDeposits, forKey: "notifyDeposits") } }
    /// Kilobytes per second; 0 = no limit.
    var uploadLimitKB: Int { didSet { d.set(uploadLimitKB, forKey: "uploadLimitKB") } }
    var downloadLimitKB: Int { didSet { d.set(downloadLimitKB, forKey: "downloadLimitKB") } }
    /// 0 = adapt to the measured link.
    var parallelTransfers: Int { didSet { d.set(parallelTransfers, forKey: "parallelTransfers") } }
    /// Ask for Touch ID (or the Mac's password) to show the window.
    var biometricLock: Bool { didSet { d.set(biometricLock, forKey: "biometricLock") } }
    var syncPaused: Bool { didSet { d.set(syncPaused, forKey: "syncPaused") } }
    var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var gridView: Bool { didSet { d.set(gridView, forKey: "gridView") } }
    /// Low Power Mode and a low battery slow transfers down and hold background ones.
    var respectPower: Bool { didSet { d.set(respectPower, forKey: "respectPower") } }
    /// Floating drop zone on the desktop (off by default) and where its files go (nil = root of Mon Drive).
    var dropZone: Bool { didSet { d.set(dropZone, forKey: "dropZone") } }
    var dropZoneFolderID: String? { didSet { d.set(dropZoneFolderID, forKey: "dropZoneFolderID") } }
    /// Names, kinds and dates of items indexed in Spotlight (never content). Off by default.
    var spotlightIndex: Bool { didSet { d.set(spotlightIndex, forKey: "spotlightIndex") } }
    /// Grid cell size step (0 small, 1 medium, 2 large).
    var gridSize: Int { didSet { d.set(gridSize, forKey: "gridSize") } }

    init() {
        let d = AppEnvironment.defaults
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        finderIntegration = b("finderIntegration", true); notifyTransfers = b("notifyTransfers", true); notifyConflicts = b("notifyConflicts", true); notifyDeposits = b("notifyDeposits", true)
        uploadLimitKB = d.integer(forKey: "uploadLimitKB"); downloadLimitKB = d.integer(forKey: "downloadLimitKB"); parallelTransfers = d.integer(forKey: "parallelTransfers")
        biometricLock = b("biometricLock", false); syncPaused = b("syncPaused", false); showMenuBarIcon = b("showMenuBarIcon", true); gridView = b("gridView", false)
        respectPower = b("respectPower", true); dropZone = b("dropZone", false); dropZoneFolderID = d.string(forKey: "dropZoneFolderID"); spotlightIndex = b("spotlightIndex", false)
        gridSize = d.object(forKey: "gridSize") == nil ? 1 : d.integer(forKey: "gridSize")
    }
}
