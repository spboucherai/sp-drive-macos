// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Core/Security/KeychainTokenStore.swift
// Description      : The device session token in the data-protection keychain,
//                    in an access group shared by the app and its File Provider
//                    extension. Readable after first unlock so that sync
//                    resumes after a restart.
// Module           : Core
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-18
// Last Modified    : 2026-11-18
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
import Security

public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    /// Keychain access group (TEAMID.group) shared with the extensions; nil = the app's own default group.
    public let accessGroup: String?
    public init(service: String, account: String = "device-session", accessGroup: String?) { self.service = service; self.account = account; self.accessGroup = accessGroup }

    private var base: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
    public func readToken() throws -> String? {
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let d = out as? Data else { throw DriveError.local("trousseau : lecture impossible (\(s))") }
        return String(data: d, encoding: .utf8)
    }
    public func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        var s = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var q = base; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly // never synced to iCloud Keychain, never restored on another device
            s = SecItemAdd(q as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw DriveError.local("trousseau : écriture impossible (\(s))") }
    }
    public func deleteToken() throws {
        let s = SecItemDelete(base as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw DriveError.local("trousseau : suppression impossible (\(s))") }
    }
}
