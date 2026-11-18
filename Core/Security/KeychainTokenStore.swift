// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/Security/KeychainTokenStore.swift
// Description: The device session token in the data-protection keychain, in an access group shared by the app and its File Provider extension. Readable after first unlock so that sync resumes after a restart.
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
