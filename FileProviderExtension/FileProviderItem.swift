// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : FileProviderExtension/FileProviderItem.swift
// Description      : A file or folder of SP Drive as the system sees it: stable
//                    identifiers, versions (content = server version, metadata
//                    = server revision), capabilities, offline policy.
// Module           : FileProviderExtension
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

import FileProvider
import Foundation
import SPDriveCore
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    let item: DriveItem
    let rootID: String
    let pinned: Bool
    /// The item has an active share link (told by the application, which lists the links).
    let hasLink: Bool
    init(_ item: DriveItem, rootID: String, pinned: Bool, shared: Bool = false) { self.item = item; self.rootID = rootID; self.pinned = pinned; hasLink = shared }
    /// The system's own notion of "shared" (Finder column and badge): true while a share link is active.
    var isShared: Bool { hasLink }
    var isSharedByCurrentUser: Bool { hasLink }

    /// Decorations declared in the extension's Info.plist (`NSFileProviderDecorations`): what the Finder shows on the icon and in its "Shared" column.
    static let decorationPrefix = "\(AppEnvironment.appBundleID).fileprovider"
    static let favoriteDecoration = NSFileProviderItemDecorationIdentifier(rawValue: "\(decorationPrefix).favorite")
    static let sharedDecoration = NSFileProviderItemDecorationIdentifier(rawValue: "\(decorationPrefix).shared")
    static let blockedDecoration = NSFileProviderItemDecorationIdentifier(rawValue: "\(decorationPrefix).blocked")
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        guard !item.isRoot, !item.isTrashed else { return nil }
        var d: [NSFileProviderItemDecorationIdentifier] = []
        if item.scan == "infected" { d.append(FileProviderItem.blockedDecoration) } else if item.starred { d.append(FileProviderItem.favoriteDecoration) }
        if hasLink { d.append(FileProviderItem.sharedDecoration) }
        return d.isEmpty ? nil : d
    }

    /// System identifier of a server identifier (the root folder has a reserved one).
    static func identifier(_ id: String, rootID: String) -> NSFileProviderItemIdentifier { id == rootID ? .rootContainer : NSFileProviderItemIdentifier(id) }
    /// Server identifier of a system identifier.
    static func serverID(_ id: NSFileProviderItemIdentifier, rootID: String) -> String { id == .rootContainer ? rootID : id.rawValue }

    var itemIdentifier: NSFileProviderItemIdentifier { FileProviderItem.identifier(item.id, rootID: rootID) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if item.isRoot { return .rootContainer }
        if item.trashRoot { return .trashContainer } // what was put in the trash itself sits in the trash; its descendants keep their parent
        return FileProviderItem.identifier(item.parentID ?? rootID, rootID: rootID)
    }
    var filename: String { item.isRoot ? "SP Drive" : item.name }
    var contentType: UTType {
        if item.isFolder { return .folder }
        return UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
    }
    var capabilities: NSFileProviderItemCapabilities {
        if item.isRoot { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        if item.isTrashed { return [.allowsReading, .allowsDeleting, .allowsReparenting, .allowsContentEnumerating] }
        var c: NSFileProviderItemCapabilities = [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting, .allowsEvicting]
        if item.isFolder { c.formUnion([.allowsContentEnumerating, .allowsAddingSubItems]) } else { c.insert(.allowsWriting) }
        return c
    }
    var documentSize: NSNumber? { item.isFolder ? nil : NSNumber(value: item.size) }
    var creationDate: Date? { item.createdAt }
    var contentModificationDate: Date? { item.isFolder ? item.updatedAt : item.contentAt }
    var itemVersion: NSFileProviderItemVersion {
        // content: the server's version identifier — what an edit made here is derived from, and what the server compares on upload
        let content = item.isFolder ? "folder" : (item.versionID ?? item.sha256)
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data("\(item.rev)|\(pinned ? 1 : 0)|\(hasLink ? 1 : 0)".utf8))
    }
    /// "Keep available offline": the system downloads the item, keeps it up to date and never evicts it.
    var contentPolicy: NSFileProviderContentPolicy { pinned ? .downloadEagerlyAndKeepDownloaded : .inherited }
    /// Read by the activation rules of the context-menu actions (Info.plist `NSExtensionFileProviderActions`).
    var userInfo: [AnyHashable: Any]? { ["scan": item.scan, "pinned": pinned ? 1 : 0, "file": item.isFolder ? 0 : 1, "live": item.isTrashed || item.isRoot ? 0 : 1] }
}
/// Server version identifier carried by a system item version ("" when unknown).
func serverVersionID(_ v: NSFileProviderItemVersion) -> String? {
    let s = String(decoding: v.contentVersion, as: UTF8.self)
    return s.count == 36 && s.contains("-") ? s : nil
}
