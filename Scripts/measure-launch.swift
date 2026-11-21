// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Scripts/measure-launch.swift
// Description      : Measures the cold launch of the development variant: time
//                    from process start to its first window on screen (polled
//                    every 5 ms through the window server; nothing is
//                    captured). The app is stopped after each run. Usage: swift
//                    Scripts/measure-launch.swift [runs] (only ever starts and
//                    stops "SP Drive Dev")
// Module           : Scripts
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

import CoreGraphics
import Foundation

let bin = NSString(string: "~/Library/Developer/SPDrive/DerivedData/Build/Products/Debug/SP Drive Dev.app/Contents/MacOS/SP Drive Dev").expandingTildeInPath
let runs = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3
var results: [Double] = []
for _ in 0..<runs {
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    let start = DispatchTime.now()
    try p.run()
    var shown: Double?
    while shown == nil, DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 15_000_000_000 {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if list.contains(where: { ($0["kCGWindowOwnerPID"] as? Int32) == p.processIdentifier && ($0["kCGWindowLayer"] as? Int) == 0 && (($0["kCGWindowBounds"] as? [String: Any])?["Width"] as? Double ?? 0) > 300 }) {
            shown = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        } else { usleep(5000) }
    }
    p.terminate(); p.waitUntilExit()
    if let shown { results.append(shown); print(String(format: "first window after %.0f ms", shown)) } else { print("no window within 15 s") }
    sleep(1)
}
if !results.isEmpty { print(String(format: "median %.0f ms over %d runs", results.sorted()[results.count / 2], results.count)) }
