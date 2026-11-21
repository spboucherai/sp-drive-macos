// swift-tools-version: 6.0
// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Package.swift
// Description      : Swift packages of SP Drive's engine room — SPDriveCore
//                    (models, API, auth, persistence, security) and SPDriveSync
//                    (transfers, change feed, journal, conflicts) — and their
//                    tests.
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

import PackageDescription

// No user interface and no AppKit/UIKit here: both targets are linked by the macOS app, by its File Provider
// extension and by the iOS app and its extensions. Only extension-safe API is used; there is no dependency.
let package = Package(
    name: "SPDriveCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SPDriveCore", targets: ["SPDriveCore"]),
        .library(name: "SPDriveSync", targets: ["SPDriveSync"]),
        // SP Drive 2.0 endpoints. Depends on Foundation only (not on SPDriveCore): the iOS app, which has its own engine, links it too.
        .library(name: "SPDriveNext", targets: ["SPDriveNext"]),
        .executable(name: "spdrive-cli", targets: ["spdrive-cli"]),
    ],
    targets: [
        .target(name: "SPDriveCore", path: "Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "SPDriveSync", dependencies: ["SPDriveCore", "SPDriveNext"], path: "Sync"),
        .target(name: "SPDriveNext", path: "Next"),
        .executableTarget(name: "spdrive-cli", dependencies: ["SPDriveCore", "SPDriveSync"], path: "Tools/spdrive-cli"),
        .testTarget(name: "CoreTests", dependencies: ["SPDriveCore", "SPDriveSync"], path: "Tests/CoreTests"),
        .testTarget(name: "NextTests", dependencies: ["SPDriveNext"], path: "Tests/NextTests"),
    ],
    swiftLanguageModes: [.v6]
)
