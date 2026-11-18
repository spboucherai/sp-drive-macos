// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/Metadata/LocalSearch.swift
// Description: Search in the local metadata mirror — by name, extension, type, folder, date, size, favourites, shared — paginated, usable without a network.
import Foundation

public enum FileCategory: String, CaseIterable, Sendable, Identifiable {
    case any, folder, image, pdf, document, sheet, video, audio, archive, text
    public var id: String { rawValue }
    /// Same families as the server's own search.
    public var extensions: [String] {
        switch self {
        case .any, .folder: return []
        case .image: return ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "svg", "tiff", "bmp"]
        case .pdf: return ["pdf"]
        case .document: return ["doc", "docx", "odt", "ppt", "pptx", "odp", "rtf", "pages", "key"]
        case .sheet: return ["xlsx", "xls", "ods", "csv", "numbers"]
        case .video: return ["mp4", "m4v", "mov", "webm", "mkv", "avi"]
        case .audio: return ["mp3", "m4a", "aac", "wav", "ogg", "flac"]
        case .archive: return ["zip", "tar", "gz", "tgz", "7z", "rar"]
        case .text: return ["txt", "md", "json", "xml", "log", "yaml", "yml", "tex"]
        }
    }
    public static func of(_ item: DriveItem) -> FileCategory {
        if item.isFolder { return .folder }
        let e = item.fileExtension
        return allCases.first { $0.extensions.contains(e) } ?? .any
    }
}
public enum SortKey: String, Sendable, CaseIterable { case name, updated, size, kind }

public struct LocalSearch: Sendable {
    public var text = ""
    public var category = FileCategory.any
    /// Explicit extension ("pdf"), in addition to the category.
    public var fileExtension: String?
    /// Restricts to a folder and everything below it.
    public var folderID: String?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var minSize: Int64?
    public var maxSize: Int64?
    public var starredOnly = false
    /// When set, only these identifiers (e.g. the items that have a share link).
    public var onlyIDs: Set<String>?
    public var sort = SortKey.name
    public var ascending = true
    public var limit = 200
    public var offset = 0
    public init(text: String = "") { self.text = text }
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && category == .any && fileExtension == nil && modifiedAfter == nil && modifiedBefore == nil && minSize == nil && maxSize == nil && !starredOnly && onlyIDs == nil
    }
}

extension MetadataStore {
    /// Live items matching the query. Words of the text must all appear in the name (accents and case ignored).
    public func search(_ q: LocalSearch) throws -> [DriveItem] {
        var sql = "", v: [SQLValue] = [], w: [String] = ["i.trashed_at IS NULL", "i.parent_id IS NOT NULL"]
        if let f = q.folderID {
            sql = "WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT c.id FROM items c JOIN sub ON c.parent_id = sub.id WHERE c.trashed_at IS NULL AND c.kind = 'folder') "
            v.append(.text(f)); w.append("i.parent_id IN (SELECT id FROM sub)")
        }
        for word in NameRules.searchKey(q.text).split(separator: " ") where !word.isEmpty {
            w.append("i.name_key LIKE ? ESCAPE '\\'")
            v.append(.text("%" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"))
        }
        if q.category == .folder { w.append("i.kind = 'folder'") }
        else if !q.category.extensions.isEmpty { w.append("i.kind = 'file' AND i.ext IN (\(q.category.extensions.map { _ in "?" }.joined(separator: ",")))"); v += q.category.extensions.map(SQLValue.text) }
        if let e = q.fileExtension?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")), !e.isEmpty { w.append("i.kind = 'file' AND i.ext = ?"); v.append(.text(e)) }
        if let d = q.modifiedAfter { w.append("i.updated_at >= ?"); v.append(.double(d.timeIntervalSince1970)) }
        if let d = q.modifiedBefore { w.append("i.updated_at < ?"); v.append(.double(d.timeIntervalSince1970)) }
        if let s = q.minSize { w.append("i.kind = 'file' AND i.size >= ?"); v.append(.int(s)) }
        if let s = q.maxSize { w.append("i.kind = 'file' AND i.size <= ?"); v.append(.int(s)) }
        if q.starredOnly { w.append("i.starred = 1") }
        if let ids = q.onlyIDs {
            guard !ids.isEmpty else { return [] }
            w.append("i.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"); v += ids.sorted().map(SQLValue.text)
        }
        let dir = q.ascending ? "ASC" : "DESC"
        let order: String
        switch q.sort {
        case .name: order = "i.kind DESC, i.name_key \(dir)"
        case .updated: order = "i.updated_at \(dir)"
        case .size: order = "i.kind DESC, i.size \(dir), i.name_key"
        case .kind: order = "i.kind DESC, i.ext \(dir), i.name_key"
        }
        sql += "SELECT i.* FROM items i WHERE \(w.joined(separator: " AND ")) ORDER BY \(order), i.id LIMIT ? OFFSET ?"
        v += [.int(Int64(q.limit)), .int(Int64(q.offset))]
        return try db.query(sql, v).map(MetadataStore.item)
    }
}
