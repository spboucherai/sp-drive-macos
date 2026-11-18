// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/Models/Models.swift
// Description: Value types of SP Drive as the server describes them: items (files and folders), account, share links, deposit portals, versions, sessions.
import Foundation

public enum ItemKind: String, Codable, Sendable, Hashable { case file, folder }

/// A file or a folder of the owner's tree, as the server last described it.
public struct DriveItem: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var kind: ItemKind
    public var name: String
    /// Parent folder; nil for the root folder only.
    public var parentID: String?
    public var size: Int64
    public var sha256: String
    /// Current content version (files); a new one is created each time the content changes.
    public var versionID: String?
    public var versionSeq: Int
    public var versionCount: Int
    /// When the current content was stored (files); `updatedAt` also moves on renames and moves.
    public var contentAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var starred: Bool
    public var trashedAt: Date?
    /// True for the item that was put in the trash itself (its descendants follow it).
    public var trashRoot: Bool
    /// Server revision: grows with every committed change of the owner's tree.
    public var rev: Int64
    /// Antivirus state of the content: pending, clean, infected, error.
    public var scan: String
    public var hasThumbnail: Bool
    /// How the server previews it (pdf, image, video, text, office…), decided from the name.
    public var previewKind: String

    public var isFolder: Bool { kind == .folder }
    public var isTrashed: Bool { trashedAt != nil }
    public var isRoot: Bool { kind == .folder && parentID == nil }
    public var fileExtension: String { kind == .file ? NameRules.fileExtension(name) : "" }

    public init(id: String, kind: ItemKind, name: String, parentID: String?, size: Int64 = 0, sha256: String = "", versionID: String? = nil, versionSeq: Int = 1,
                versionCount: Int = 1, contentAt: Date = Date(), createdAt: Date = Date(), updatedAt: Date = Date(), starred: Bool = false, trashedAt: Date? = nil,
                trashRoot: Bool = false, rev: Int64 = 0, scan: String = "clean", hasThumbnail: Bool = false, previewKind: String = "none") {
        self.id = id; self.kind = kind; self.name = name; self.parentID = parentID; self.size = size; self.sha256 = sha256; self.versionID = versionID
        self.versionSeq = versionSeq; self.versionCount = versionCount; self.contentAt = contentAt; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.starred = starred; self.trashedAt = trashedAt; self.trashRoot = trashRoot; self.rev = rev; self.scan = scan; self.hasThumbnail = hasThumbnail; self.previewKind = previewKind
    }

    private enum K: String, CodingKey {
        case id, type, name, parentId, folderId, size, sha256, versionId, versionSeq, versions, contentAt, createdAt, updatedAt, starred, trashedAt, trashRoot, rev, scan, thumb, kind
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ItemKind.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        parentID = kind == .folder ? try c.decodeIfPresent(String.self, forKey: .parentId) : try c.decode(String.self, forKey: .folderId)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        versionID = try c.decodeIfPresent(String.self, forKey: .versionId)
        versionSeq = try c.decodeIfPresent(Int.self, forKey: .versionSeq) ?? 1
        versionCount = try c.decodeIfPresent(Int.self, forKey: .versions) ?? 1
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        contentAt = try c.decodeIfPresent(Date.self, forKey: .contentAt) ?? updatedAt
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        trashRoot = try c.decodeIfPresent(Bool.self, forKey: .trashRoot) ?? false
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev) ?? 0
        scan = try c.decodeIfPresent(String.self, forKey: .scan) ?? "clean"
        hasThumbnail = try c.decodeIfPresent(Bool.self, forKey: .thumb) ?? false
        previewKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "none"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .type); try c.encode(name, forKey: .name)
        if kind == .folder { try c.encodeIfPresent(parentID, forKey: .parentId) } else { try c.encodeIfPresent(parentID, forKey: .folderId) }
        try c.encode(size, forKey: .size); try c.encode(sha256, forKey: .sha256); try c.encodeIfPresent(versionID, forKey: .versionId)
        try c.encode(versionSeq, forKey: .versionSeq); try c.encode(versionCount, forKey: .versions); try c.encode(contentAt, forKey: .contentAt)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt); try c.encode(starred, forKey: .starred)
        try c.encodeIfPresent(trashedAt, forKey: .trashedAt); try c.encode(trashRoot, forKey: .trashRoot); try c.encode(rev, forKey: .rev)
        try c.encode(scan, forKey: .scan); try c.encode(hasThumbnail, forKey: .thumb); try c.encode(previewKind, forKey: .kind)
    }
}

public struct Crumb: Codable, Sendable, Hashable, Identifiable { public var id: String; public var name: String }

/// A folder with its direct children, as listed by the server.
public struct FolderListing: Decodable, Sendable {
    public var folder: DriveItem
    public var breadcrumbs: [Crumb]
    public var folders: [DriveItem]
    public var files: [DriveItem]
    public var children: [DriveItem] { folders + files }
}
public struct ItemList: Decodable, Sendable {
    public var folders: [DriveItem]
    public var files: [DriveItem]
    public var all: [DriveItem] { folders + files }
}

public struct Account: Codable, Sendable, Hashable {
    public var id: String
    public var email: String
    public var displayName: String
    public var role: String
    public var locale: String
    private enum CodingKeys: String, CodingKey { case id, email, displayName = "display_name", role, locale }
}
public struct Quota: Codable, Sendable, Hashable { public var limit: Int64; public var used: Int64; public var free: Int64 { max(0, limit - used) } }
public struct AuthState: Decodable, Sendable {
    public var authenticated: Bool
    public var recovery: Bool?
    public var kind: String?
    public var user: Account?
    public var quota: Quota?
    public var freshAuth: Bool?
}

public struct FileVersion: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var seq: Int
    public var size: Int64
    public var sha256: String
    public var createdAt: Date
    public var note: String
    public var current: Bool
}
public struct FileDetails: Decodable, Sendable {
    public var file: DriveItem
    public var path: [Crumb]
    public var shares: Int
    public var versions: [FileVersion]
}

public struct ShareLink: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var type: ItemKind
    public var targetId: String?
    public var targetName: String
    public var label: String
    public var canDownload: Bool
    public var hasPassword: Bool
    public var expiresAt: Date?
    public var maxViews: Int?
    public var viewCount: Int
    public var maxDownloads: Int?
    public var downloadCount: Int
    public var singleUse: Bool
    public var revokedAt: Date?
    public var createdAt: Date
    public var lastAccessAt: Date?
    /// active, revoked, expired, exhausted, target_missing
    public var status: String
    public var isActive: Bool { status == "active" }
}
public struct ShareAccessEvent: Decodable, Sendable, Identifiable, Hashable {
    public var id: String; public var at: Date; public var kind: String; public var ok: Bool; public var ip: String; public var userAgent: String; public var detail: String
}
/// What the owner chooses for a share link. `nil` leaves a setting untouched on update; `.some(nil)` clears it.
public struct ShareSettings: Encodable, Sendable {
    public var label: String?
    public var canDownload: Bool?
    public var password: String??
    public var expiresAt: Date??
    public var maxViews: Int??
    public var maxDownloads: Int??
    public var singleUse: Bool?
    public init(label: String? = nil, canDownload: Bool? = nil, password: String?? = nil, expiresAt: Date?? = nil, maxViews: Int?? = nil, maxDownloads: Int?? = nil, singleUse: Bool? = nil) {
        self.label = label; self.canDownload = canDownload; self.password = password; self.expiresAt = expiresAt; self.maxViews = maxViews; self.maxDownloads = maxDownloads; self.singleUse = singleUse
    }
    private enum K: String, CodingKey { case label, canDownload, password, expiresAt, maxViews, maxDownloads, singleUse, fileId, folderId }
    public func encode(to encoder: Encoder) throws { try encode(to: encoder, target: nil) }
    func encode(to encoder: Encoder, target: (kind: ItemKind, id: String)?) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(label, forKey: .label); try c.encodeIfPresent(canDownload, forKey: .canDownload); try c.encodeIfPresent(singleUse, forKey: .singleUse)
        if let password { try c.encode(password, forKey: .password) }
        if let expiresAt { try c.encode(expiresAt, forKey: .expiresAt) }
        if let maxViews { try c.encode(maxViews, forKey: .maxViews) }
        if let maxDownloads { try c.encode(maxDownloads, forKey: .maxDownloads) }
        if let target { try c.encode(target.id, forKey: target.kind == .file ? .fileId : .folderId) }
    }
}

/// A deposit portal: a link through which other people send files into one folder, and see nothing else.
public struct DepositPortal: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var folderId: String
    public var folderName: String?
    public var title: String
    public var description: String
    public var instructions: String
    public var hasPassword: Bool
    public var expiresAt: Date?
    public var active: Bool
    public var revokedAt: Date?
    public var maxFileBytes: Int64
    public var maxTotalBytes: Int64
    public var maxFilesPerSubmission: Int
    public var maxSubmissions: Int?
    public var allowedExtensions: [String]
    public var subfolderPerSubmission: Bool
    public var notifyOwner: Bool
    public var bytesReceived: Int64
    public var submissions: Int
    public var createdAt: Date
    /// open, paused, revoked, expired, full, target_missing
    public var state: String
}
public struct PortalSettings: Encodable, Sendable {
    public var folderId: String?
    public var title: String?
    public var description: String?
    public var instructions: String?
    public var password: String??
    public var expiresAt: Date??
    public var active: Bool?
    public var maxFileBytes: Int64?
    public var maxTotalBytes: Int64?
    public var maxFilesPerSubmission: Int?
    public var allowedExtensions: [String]?
    public var subfolderPerSubmission: Bool?
    public var notifyOwner: Bool?
    public init() {}
    private enum K: String, CodingKey { case folderId, title, description, instructions, password, expiresAt, active, maxFileBytes, maxTotalBytes, maxFilesPerSubmission, allowedExtensions, subfolderPerSubmission, notifyOwner }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(folderId, forKey: .folderId); try c.encodeIfPresent(title, forKey: .title); try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(instructions, forKey: .instructions); try c.encodeIfPresent(active, forKey: .active); try c.encodeIfPresent(maxFileBytes, forKey: .maxFileBytes)
        try c.encodeIfPresent(maxTotalBytes, forKey: .maxTotalBytes); try c.encodeIfPresent(maxFilesPerSubmission, forKey: .maxFilesPerSubmission)
        try c.encodeIfPresent(allowedExtensions, forKey: .allowedExtensions); try c.encodeIfPresent(subfolderPerSubmission, forKey: .subfolderPerSubmission); try c.encodeIfPresent(notifyOwner, forKey: .notifyOwner)
        if let password { try c.encode(password, forKey: .password) }
        if let expiresAt { try c.encode(expiresAt, forKey: .expiresAt) }
    }
}
public struct PortalSubmission: Decodable, Sendable, Identifiable, Hashable {
    public var id: String; public var ref: String; public var status: String; public var name: String; public var email: String; public var reference: String
    public var createdAt: Date; public var completedAt: Date?; public var folderId: String?; public var files: Int; public var placed: Int; public var rejected: Int; public var bytes: Int64
}

public struct DeviceSession: Decodable, Sendable, Identifiable, Hashable {
    public var id: String; public var createdAt: Date; public var lastSeenAt: Date; public var ip: String; public var userAgent: String; public var method: String
    public var kind: String?; public var deviceName: String?; public var current: Bool
}
public struct ServerNotification: Decodable, Sendable, Identifiable, Hashable {
    public var id: String; public var kind: String; public var data: [String: JSONValue]; public var read: Bool; public var createdAt: Date
}

/// Page of the change feed.
public struct ChangePage: Decodable, Sendable {
    public struct Deleted: Decodable, Sendable, Hashable { public var id: String; public var type: ItemKind; public var rev: Int64 }
    public var items: [DriveItem]
    public var deleted: [Deleted]
    public var cursor: Int64
    public var more: Bool
    public var head: Int64
    public var rootId: String
}
public struct SyncCursor: Decodable, Sendable { public var head: Int64; public var rootId: String }

/// Loosely typed JSON (error details, notification payloads).
public enum JSONValue: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int64? { if case .number(let n) = self { return Int64(n) }; return nil }
}
