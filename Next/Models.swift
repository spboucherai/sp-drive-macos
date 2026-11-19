// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Next/Models.swift
// Description: SPDriveNext — value types of the SP Drive 2.0 API, as the server sends them (API-NEXT.md §2–§8). Decoding is tolerant: a field the server omits in one context (shared files, uploader answers) is optional here.
import Foundation

// MARK: Files and folders (the 1.0 objects, plus what 2.0 adds around them)
public struct SearchMatch: Codable, Sendable, Hashable {
    /// name | content | both
    public var `where`: String
    /// Plain text; matched words are wrapped in ⟦ ⟧ (U+27E6 / U+27E7). Present for content and both.
    public var snippet: String?
    public var page: Int?
    /// The snippet cut at its markers: (text, isMatch) runs, for display with highlights.
    public var snippetRuns: [(text: String, matched: Bool)] {
        guard let snippet else { return [] }
        var runs: [(String, Bool)] = [], current = "", inside = false
        for ch in snippet {
            if ch == "⟦" { if !current.isEmpty { runs.append((current, inside)) }; current = ""; inside = true }
            else if ch == "⟧" { if !current.isEmpty { runs.append((current, inside)) }; current = ""; inside = false }
            else { current.append(ch) }
        }
        if !current.isEmpty { runs.append((current, inside)) }
        return runs
    }
}
public struct NextFile: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var folderId: String?
    public var size: Int64
    public var sha256: String?
    /// How the server previews it: image, pdf, video, audio, text, office, heic, archive, sheet, none…
    public var kind: String?
    public var starred: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var contentAt: Date?
    public var trashedAt: Date?
    public var scan: String?
    public var thumb: Bool
    public var tagIds: [String]
    public var versions: Int?
    public var rev: Int64?
    public var versionId: String?
    public var versionSeq: Int?
    /// Search results only.
    public var match: SearchMatch?
    /// `duplicates?mode=similar-images` only: 64-bit difference hash, hexadecimal.
    public var dhash: String?
    public var modified: Date? { contentAt ?? updatedAt }
    public var fileExtension: String { let e = (name as NSString).pathExtension; return e.lowercased() }
    enum K: String, CodingKey { case id, name, folderId, size, sha256, kind, starred, createdAt, updatedAt, contentAt, trashedAt, scan, thumb, tagIds, versions, rev, versionId, versionSeq, match, dhash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId); size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256); kind = try c.decodeIfPresent(String.self, forKey: .kind)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt); updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        contentAt = try c.decodeIfPresent(Date.self, forKey: .contentAt); trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        scan = try c.decodeIfPresent(String.self, forKey: .scan); thumb = try c.decodeIfPresent(Bool.self, forKey: .thumb) ?? false
        tagIds = try c.decodeIfPresent([String].self, forKey: .tagIds) ?? []; versions = try c.decodeIfPresent(Int.self, forKey: .versions)
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev); versionId = try c.decodeIfPresent(String.self, forKey: .versionId)
        versionSeq = try c.decodeIfPresent(Int.self, forKey: .versionSeq); match = try c.decodeIfPresent(SearchMatch.self, forKey: .match)
        dhash = try c.decodeIfPresent(String.self, forKey: .dhash)
    }
}
public struct NextFolder: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// nil for the account's root, and for the granted folder seen through a grant.
    public var parentId: String?
    public var starred: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var trashedAt: Date?
    public var rev: Int64?
    /// A shared folder with a name of its own ("workspace").
    public var workspaceName: String?
    /// Grant routes only: true for the folder the grant was given on.
    public var isGrantRoot: Bool?
    public var match: SearchMatch?
    public var displayName: String { workspaceName?.isEmpty == false ? workspaceName! : name }
    enum K: String, CodingKey { case id, name, parentId, starred, createdAt, updatedAt, trashedAt, rev, workspaceName, isGrantRoot, match }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId); starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt); updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt); rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName); isGrantRoot = try c.decodeIfPresent(Bool.self, forKey: .isGrantRoot)
        match = try c.decodeIfPresent(SearchMatch.self, forKey: .match)
    }
}
public struct NextCrumb: Codable, Sendable, Hashable, Identifiable { public var id: String; public var name: String; public init(id: String, name: String) { self.id = id; self.name = name } }

// MARK: §2 Capabilities, sessions
public struct ServerMeta: Codable, Sendable, Equatable {
    public var api: Int
    public var version: String
    public var features: [String]
    public init(api: Int, version: String, features: [String]) { self.api = api; self.version = version; self.features = features }
    /// What a 1.0 server (404 on /meta) amounts to.
    public static let v1 = ServerMeta(api: 1, version: "1", features: [])
    public func has(_ feature: Feature) -> Bool { features.contains(feature.rawValue) }
    public enum Feature: String, Sendable, CaseIterable {
        case events, contentSearch = "content-search", ocr, semantic, ai, collab, collections, activity, storage, similarImages = "similar-images", uploadHistory = "upload-history"
    }
}
public struct ClientInfo: Codable, Sendable, Hashable { public var platform: String; public var version: String; public var os: String? }
public struct NextSession: Codable, Sendable, Identifiable, Hashable {
    public var id: String; public var createdAt: Date; public var lastSeenAt: Date; public var ip: String; public var userAgent: String; public var method: String
    public var kind: String?; public var deviceName: String?; public var current: Bool
    /// nil for web sessions and for devices that never sent `X-SPD-Client`.
    public var client: ClientInfo?
}
public struct AccountPatch: Encodable, Sendable {
    public var displayName: String?; public var locale: String?; public var aiExternal: Bool?
    public init(displayName: String? = nil, locale: String? = nil, aiExternal: Bool? = nil) { self.displayName = displayName; self.locale = locale; self.aiExternal = aiExternal }
}

// MARK: §3 Sync events
public enum SyncEvent: Sendable, Equatable {
    case hello(head: Int64)
    case change(head: Int64)
    case notify(kind: String)
}

// MARK: §4 Search
public enum SearchScope: String, Sendable { case name, content, all }
public struct SearchParameters: Sendable {
    public var q: String
    public var scope = SearchScope.all
    /// any, image, pdf, document, sheet, video, audio, archive, text, folder
    public var kind: String?
    public var starred: Bool?
    public var from: Date?; public var to: Date?
    public var minSize: Int64?; public var maxSize: Int64?
    public var sort: String?; public var dir: String?
    public init(q: String, scope: SearchScope = .all) { self.q = q; self.scope = scope }
}
public struct SearchResults: Codable, Sendable { public var folders: [NextFolder]; public var files: [NextFile] }
public struct SemanticHit: Codable, Sendable, Identifiable {
    public struct Passage: Codable, Sendable, Hashable { public var text: String; public var page: Int? }
    public var file: NextFile
    /// Cosine in [-1, 1]. Only the ORDER of hits means something: never show it, never threshold on it (API-NEXT §4.4).
    public var score: Double
    public var passage: Passage
    public var id: String { file.id }
}
public struct SemanticResults: Codable, Sendable { public var available: Bool; public var hits: [SemanticHit] }
public struct FileTextStatus: Codable, Sendable, Equatable {
    /// pending | ready | empty | unsupported | failed
    public var status: String
    public var source: String?
    public var pages: Int?; public var chars: Int?
    public var excerpt: String?
    public var error: String?
}
public struct IndexStatus: Codable, Sendable, Equatable {
    public struct Content: Codable, Sendable, Equatable { public var enabled: Bool?; public var ready: Int; public var pending: Int; public var failed: Int; public var unsupported: Int; public var empty: Int? }
    public struct Semantic: Codable, Sendable, Equatable { public var available: Bool; public var model: String?; public var embedded: Int? }
    public var content: Content; public var semantic: Semantic
}

// MARK: §5 Document intelligence
public struct AIModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String; public var label: String
    /// Who made the model — distinct from the provider, which is the route to it.
    public var creator: String?
}
public struct AIProvider: Codable, Sendable, Hashable, Identifiable {
    public var id: String; public var label: String
    public var local: Bool; public var configured: Bool
    /// configured and (local, or external providers allowed by both the server and the account).
    public var usable: Bool?
    public var models: [AIModel]
}
public struct AIProviders: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Hashable { public var provider: String; public var model: String; public init(provider: String, model: String) { self.provider = provider; self.model = model } }
    public struct External: Codable, Sendable, Hashable { public var server: Bool; public var account: Bool }
    /// At least one provider is usable by this account.
    public var enabled: Bool
    public var externalAllowed: Bool
    public var external: External?
    public var `default`: Choice?
    public var providers: [AIProvider]
}
public enum AIScope: Sendable, Equatable { case files([String]), folder(String), all }
public struct AITurn: Codable, Sendable, Hashable { public var role: String; public var content: String; public init(role: String, content: String) { self.role = role; self.content = content } }
public struct AIAskRequest: Encodable, Sendable {
    public var scope: AIScope; public var question: String; public var provider: String?; public var model: String?; public var history: [AITurn]?
    public init(scope: AIScope, question: String, provider: String? = nil, model: String? = nil, history: [AITurn]? = nil) { self.scope = scope; self.question = question; self.provider = provider; self.model = model; self.history = history }
    enum K: String, CodingKey { case scope, question, provider, model, history }
    enum S: String, CodingKey { case fileIds, folderId, all }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        var s = c.nestedContainer(keyedBy: S.self, forKey: .scope)
        switch scope { case .files(let ids): try s.encode(ids, forKey: .fileIds); case .folder(let id): try s.encode(id, forKey: .folderId); case .all: try s.encode(true, forKey: .all) }
        try c.encode(question, forKey: .question); try c.encodeIfPresent(provider, forKey: .provider); try c.encodeIfPresent(model, forKey: .model)
        if let history, !history.isEmpty { try c.encode(history, forKey: .history) }
    }
}
public struct AISource: Codable, Sendable, Hashable, Identifiable {
    /// What `[n]` in the answer refers to; starts at 1.
    public var n: Int; public var fileId: String; public var name: String; public var page: Int?; public var text: String
    public var id: Int { n }
}
public struct AIUnindexed: Codable, Sendable, Hashable { public var fileId: String; public var name: String; public var status: String }
public struct AIDone: Codable, Sendable, Equatable {
    public struct Usage: Codable, Sendable, Equatable { public var inputTokens: Int?; public var outputTokens: Int? }
    /// true: nothing in the scope matched the question; no model was called.
    public var empty: Bool?
    public var provider: String?; public var model: String?; public var usage: Usage?; public var stopReason: String?
    public init(empty: Bool? = nil, provider: String? = nil, model: String? = nil, usage: Usage? = nil, stopReason: String? = nil) { self.empty = empty; self.provider = provider; self.model = model; self.usage = usage; self.stopReason = stopReason }
}
/// The events of one streamed answer, in order: optional notice, sources (once), deltas, then done or error.
public enum AIEvent: Sendable, Equatable {
    case notice(unindexed: [AIUnindexed])
    case sources([AISource])
    case delta(String)
    case done(AIDone)
    /// provider_auth, provider_unreachable, provider_unavailable, provider_rate_limited, provider_refused, model_unknown, provider_error
    case error(code: String, message: String)
}
public struct AISuggestion: Codable, Sendable, Hashable, Identifiable {
    public struct Folder: Codable, Sendable, Hashable { public var id: String; public var path: String }
    public var fileId: String; public var name: String?; public var tags: [String]?; public var folder: Folder?; public var category: String?; public var reason: String?
    public var id: String { fileId }
}
public struct AISuggestions: Codable, Sendable { public var provider: String?; public var model: String?; public var suggestions: [AISuggestion] }

// MARK: §6 Private sharing
public enum GrantRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case viewer, editor, uploader
    public var id: String { rawValue }
    public var canList: Bool { self != .uploader }
    public var canWrite: Bool { self == .editor }
    public var canUpload: Bool { self != .viewer }
}
public struct ResolvedUser: Codable, Sendable, Hashable { public var userId: String; public var displayName: String }
public struct FolderMember: Codable, Sendable, Hashable, Identifiable {
    public var grantId: String; public var userId: String; public var displayName: String; public var email: String?; public var role: GrantRole; public var createdAt: Date?
    public var id: String { userId }
}
public struct FolderMembers: Codable, Sendable { public var folder: NextFolder; public var members: [FolderMember] }
public struct OutgoingShare: Codable, Sendable, Identifiable { public var folder: NextFolder; public var members: Int; public var id: String { folder.id } }
public struct SharedGrant: Codable, Sendable, Hashable, Identifiable {
    public struct Owner: Codable, Sendable, Hashable { public var displayName: String }
    public struct Folder: Codable, Sendable, Hashable { public var id: String; public var name: String; public var workspaceName: String?; public var updatedAt: Date? }
    public var grantId: String; public var role: GrantRole; public var owner: Owner; public var folder: Folder; public var createdAt: Date?
    public var id: String { grantId }
    public var displayName: String { folder.workspaceName?.isEmpty == false ? folder.workspaceName! : folder.name }
}
public struct SharedListing: Codable, Sendable {
    public var grantId: String; public var role: GrantRole; public var folder: NextFolder; public var breadcrumbs: [NextCrumb]; public var folders: [NextFolder]; public var files: [NextFile]
}
public struct SharedFileDetails: Codable, Sendable { public var grantId: String; public var role: GrantRole; public var file: NextFile; public var path: [NextCrumb]? }
public enum SharedItem: Sendable { case file(NextFile), folder(NextFolder) }
public struct NextUpload: Codable, Sendable, Identifiable, Hashable {
    public var id: String; public var name: String; public var size: Int64; public var received: Int64
    /// active | completing | done | aborted
    public var status: String
    public var fileId: String?
    // history only
    public var fileExists: Bool?; public var folderId: String?; public var grantId: String?; public var createdAt: Date?; public var updatedAt: Date?
}
public struct NextUploadResult: Codable, Sendable { public var id: String; public var status: String; public var file: NextFile; public var created: Bool? }
public struct UploadHistory: Codable, Sendable { public var uploads: [NextUpload] }

// MARK: §7.1 Collections
public enum RuleValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) } }
    }
}
public struct RuleCondition: Codable, Sendable, Hashable {
    /// kind, ext, name, tag, untagged, size, modified, created, starred, shared, folder, text
    public var field: String
    /// is, isNot, contains, gt, lt, within
    public var op: String
    public var value: RuleValue
    public init(field: String, op: String, value: RuleValue) { self.field = field; self.op = op; self.value = value }
}
public struct CollectionRule: Codable, Sendable, Hashable {
    public struct Sort: Codable, Sendable, Hashable { public var by: String; public var dir: String; public init(by: String, dir: String) { self.by = by; self.dir = dir } }
    /// all | any
    public var match: String
    public var conditions: [RuleCondition]
    public var sort: Sort?
    public init(match: String = "all", conditions: [RuleCondition], sort: Sort? = nil) { self.match = match; self.conditions = conditions; self.sort = sort }
    /// Fields, their operators and the kind of value each takes (API-NEXT §7.1), for rule builders.
    public static let fields: [(field: String, ops: [String], value: String)] = [
        ("kind", ["is", "isNot"], "kind"), ("ext", ["is", "isNot"], "string"), ("name", ["contains", "is", "isNot"], "string"), ("text", ["contains"], "string"),
        ("size", ["gt", "lt"], "bytes"), ("modified", ["within", "gt", "lt"], "date"), ("created", ["within", "gt", "lt"], "date"),
        ("starred", ["is"], "bool"), ("shared", ["is"], "bool"), ("untagged", ["is"], "bool"), ("folder", ["is", "isNot"], "folder"), ("tag", ["is", "isNot"], "tag")]
    public static let kinds = ["image", "pdf", "document", "sheet", "video", "audio", "archive", "text"]
    public static let colors = ["slate", "red", "orange", "amber", "green", "teal", "blue", "violet", "pink"]
}
public struct SmartCollection: Codable, Sendable, Identifiable, Hashable {
    public var id: String; public var name: String; public var icon: String?; public var color: String?; public var rule: CollectionRule
    public var createdAt: Date?; public var updatedAt: Date?
    /// Present in the list only.
    public var count: Int?
}
public struct CollectionDraft: Encodable, Sendable {
    public var name: String?; public var icon: String?; public var color: String?; public var rule: CollectionRule?
    public init(name: String? = nil, icon: String? = nil, color: String? = nil, rule: CollectionRule? = nil) { self.name = name; self.icon = icon; self.color = color; self.rule = rule }
}
public struct CollectionItems: Codable, Sendable { public var collection: SmartCollection?; public var files: [NextFile]; public var total: Int; public var limit: Int?; public var offset: Int? }

// MARK: §7.2 Activity
public struct ActivityEvent: Codable, Sendable, Identifiable, Hashable {
    public struct Actor: Codable, Sendable, Hashable { public var kind: String; public var userId: String?; public var displayName: String?; public var me: Bool? }
    public struct Target: Codable, Sendable, Hashable { public var type: String; public var id: String? }
    public var id: String; public var at: Date; public var action: String; public var actor: Actor; public var target: Target?; public var meta: [String: NextJSON]?
    /// Done by a member through a grant.
    public var viaGrant: Bool { meta?["via"]?.string == "grant" }
}
public struct ActivityPage: Codable, Sendable { public var events: [ActivityEvent]; public var more: Bool }

// MARK: §7.3 Storage
public struct StorageOverview: Codable, Sendable {
    public struct Quota: Codable, Sendable, Hashable { public var limit: Int64; public var used: Int64; public var uploading: Int64? }
    public struct Counts: Codable, Sendable, Hashable { public var files: Int; public var folders: Int; public var versions: Int; public var trashedFiles: Int }
    public struct Kind: Codable, Sendable, Hashable, Identifiable { public var kind: String; public var files: Int; public var bytes: Int64; public var id: String { kind } }
    public struct FolderShare: Codable, Sendable, Identifiable { public var folder: NextFolder; public var files: Int; public var bytes: Int64; public var direct: Bool?; public var id: String { folder.id + (direct == true ? "-direct" : "") } }
    public struct Day: Codable, Sendable, Hashable, Identifiable { public var date: String; public var bytes: Int64; public var versions: Int; public var id: String { date } }
    /// `reclaimableBytes` is always 0 (identical content is stored once): deleting a duplicate frees a name, not bytes. `duplicateBytes` is the logical size of the redundant copies.
    public struct Duplicates: Codable, Sendable, Hashable { public var groups: Int; public var duplicateBytes: Int64?; public var reclaimableBytes: Int64 }
    public var quota: Quota; public var liveBytes: Int64; public var trashBytes: Int64; public var oldVersionBytes: Int64
    public var counts: Counts; public var byKind: [Kind]; public var byFolder: [FolderShare]; public var largest: [NextFile]; public var growth: [Day]; public var duplicates: Duplicates
}
public struct StorageFolder: Codable, Sendable {
    public struct Sum: Codable, Sendable, Hashable { public var files: Int; public var bytes: Int64 }
    public struct Child: Codable, Sendable, Identifiable { public var folder: NextFolder; public var files: Int; public var bytes: Int64; public var id: String { folder.id } }
    public var folder: NextFolder; public var breadcrumbs: [NextCrumb]; public var total: Sum; public var direct: Sum; public var children: [Child]; public var files: [NextFile]
}

// MARK: §7.4 Duplicates
public enum DuplicateMode: String, Sendable { case exact, similarImages = "similar-images" }
public struct DuplicateGroup: Codable, Sendable, Identifiable {
    public var sha256: String?; public var size: Int64?
    /// exact mode: same content under different names.
    public var distinctNames: Bool?
    /// similar-images mode: largest number of differing bits inside the group.
    public var maxDistance: Int?
    public var files: [NextFile]
    public var id: String { sha256 ?? files.map(\.id).joined(separator: "+") }
}
public struct Duplicates: Codable, Sendable { public var mode: String?; public var distance: Int?; public var groups: [DuplicateGroup] }

// MARK: §7.5 Versions
public struct VersionInfo: Codable, Sendable, Identifiable, Hashable {
    public struct Author: Codable, Sendable, Hashable { public var userId: String?; public var displayName: String?; public var me: Bool? }
    public var id: String; public var seq: Int; public var size: Int64; public var sha256: String; public var createdAt: Date; public var note: String?
    public var current: Bool; public var scan: String?
    /// nil for a file that came through a deposit portal.
    public var createdBy: Author?
}
public struct VersionList: Codable, Sendable { public var fileId: String; public var currentVersionId: String?; public var versions: [VersionInfo] }

// MARK: §8 Administration
public struct AdminSystem: Sendable {
    public struct Worker: Codable, Sendable, Hashable { public var alive: Bool?; public var heartbeatAgeS: Double?; public var pid: Int? }
    public struct Job: Codable, Sendable, Hashable, Identifiable { public var kind: String; public var status: String; public var count: Int; public var oldestAgeS: Double?; public var id: String { kind + "/" + status } }
    public struct PreviewFailure: Codable, Sendable, Hashable, Identifiable { public var kind: String; public var count: Int; public var lastError: String?; public var id: String { kind } }
    public var version: String?
    public var features: [String]
    public var worker: Worker?
    public var jobs: [Job]
    public var previewFailures: [PreviewFailure]
    /// Everything the server answered (1.0 fields included), for what has no typed accessor: converter, textkit, antivirusSignatures, index, events, backup…
    public var raw: [String: NextJSON]
}
