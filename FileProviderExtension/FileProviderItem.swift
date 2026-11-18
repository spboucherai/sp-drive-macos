// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: FileProviderExtension/FileProviderItem.swift
// Description: A file or folder of SP Drive as the system sees it: stable identifiers, versions (content = server version, metadata = server revision), capabilities, offline policy.
import FileProvider
import Foundation
import SPDriveCore
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let item: DriveItem
    let rootID: String
    let pinned: Bool
    init(_ item: DriveItem, rootID: String, pinned: Bool) { self.item = item; self.rootID = rootID; self.pinned = pinned }

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
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data("\(item.rev)|\(pinned ? 1 : 0)".utf8))
    }
    /// "Keep available offline": the system downloads the item, keeps it up to date and never evicts it.
    var contentPolicy: NSFileProviderContentPolicy { pinned ? .downloadEagerlyAndKeepDownloaded : .inherited }
    var userInfo: [AnyHashable: Any]? { ["scan": item.scan] }
}
/// Server version identifier carried by a system item version ("" when unknown).
func serverVersionID(_ v: NSFileProviderItemVersion) -> String? {
    let s = String(decoding: v.contentVersion, as: UTF8.self)
    return s.count == 36 && s.contains("-") ? s : nil
}
