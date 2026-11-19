// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/AppEnvironment.swift
// Description: What the application and its File Provider extension must agree on: identifiers, the shared container, the keychain group, the server, and how the engine objects are built. Compiled into both targets.
import FileProvider
import Foundation
import OSLog
import SPDriveCore
import SPDriveSync

enum AppEnvironment {
    static let teamID = "3YM54G49SN"
    #if SPD_DEV
    /// Development variant: its own identifiers, container, keychain item and Finder location, so it never touches the installed app.
    static let variant = ".dev"
    static let productName = "SP Drive Dev"
    #else
    static let variant = ""
    static let productName = "SP Drive"
    #endif
    static let appBundleID = "ai.spboucher.spdrive\(variant)"
    /// App group shared by the app and the extension (team-prefixed form of macOS).
    static let groupID = "\(teamID).ai.spboucher.spdrive\(variant)"
    static let keychainGroup = "\(teamID).ai.spboucher.spdrive\(variant).shared"
    static let productionServer = URL(string: "https://drive.spboucher.ai")!
    static let domainIdentifier = NSFileProviderDomainIdentifier("spdrive")
    /// Darwin notification posted by either process after it changed the shared database.
    static let changedNotification = "ai.spboucher.spdrive\(variant).changed"
    static let log = Logger(subsystem: appBundleID, category: "app")

    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: groupID) ?? .standard // UserDefaults is thread-safe
    /// The server. Fixed in the released application; the development variant may point at a local test backend.
    static var serverURL: URL {
        #if SPD_DEV
        if let s = defaults.string(forKey: "serverURL"), let u = URL(string: s) { return u }
        return URL(string: "http://127.0.0.1:8665")!
        #else
        return productionServer
        #endif
    }
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appBundleID)
    }
    /// One database per server and account, so signing in elsewhere never mixes two trees.
    static func databaseURL(account: String) -> URL {
        let safe = account.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return containerURL.appendingPathComponent("accounts/\(serverURL.host ?? "server")-\(safe)/metadata.sqlite")
    }
    static var workDirectory: URL { containerURL.appendingPathComponent("work", isDirectory: true) }
    static var currentAccount: String? {
        get { defaults.string(forKey: "accountID") }
        set { defaults.set(newValue, forKey: "accountID") }
    }
    static var deviceName: String {
        let name = Host.current().localizedName ?? "Mac"
        return name.isEmpty ? "Mac" : name
    }
    static var userAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "SPDrive-macOS/\(v) (macOS \(os.majorVersion).\(os.minorVersion))"
    }
    /// `X-SPD-Client` of SP Drive 2.0, sent on every request by the app and by the File Provider extension: `macos/2.0.0 (27.0)`.
    static var clientHeader: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macos/\(v) (\(os.majorVersion).\(os.minorVersion))"
    }
    static let tokens: TokenStore = KeychainTokenStore(service: "ai.spboucher.spdrive\(variant)", accessGroup: keychainGroup)
    static func makeAPI() throws -> APIClient { try APIClient(baseURL: serverURL, tokens: tokens, userAgent: userAgent, clientHeader: clientHeader) }
    /// The mirror of the signed-in account, or nil when nobody is signed in on this Mac.
    static func openStore() throws -> MetadataStore? { try currentAccount.map { try MetadataStore(url: databaseURL(account: $0)) } }

    static func postChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(changedNotification as CFString), nil, nil, true)
    }
}

/// SP Drive's share link (SwiftUI has a type of the same name).
typealias DriveShare = SPDriveCore.ShareLink
