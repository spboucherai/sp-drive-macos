// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Core/Security/NameRules.swift
// Description      : Naming rules shared with the server (sanitised names,
//                    uniqueness key, free-name search, conflict-copy names) and
//                    path-traversal guards for anything written on disk.
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

public enum NameRules {
    public static let maxNameBytes = 255
    private static let reserved: Set<String> = ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]

    private static func isBad(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200F, 0xFEFF: return true
        default: return "/\\:*?\"<>|".unicodeScalars.contains(u)
        }
    }
    /// "archive.tar.gz" → ("archive", ".tar.gz"); a leading dot belongs to the stem.
    public static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let r = name.range(of: #"^(.+?)((?:\.tar)?\.[A-Za-z0-9]{1,10})$"#, options: .regularExpression), r == name.startIndex..<name.endIndex else { return (name, "") }
        // find the split: shortest stem such that the remainder matches the extension pattern
        var idx = name.index(after: name.startIndex)
        while idx < name.endIndex {
            let tail = String(name[idx...])
            if tail.range(of: #"^(?:\.tar)?\.[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil { return (String(name[..<idx]), tail) }
            idx = name.index(after: idx)
        }
        return (name, "")
    }
    /// Lower-case extension without the dot ("" when none).
    public static func fileExtension(_ name: String) -> String {
        let e = splitExtension(name).ext
        guard let dot = e.lastIndex(of: ".") else { return "" }
        return String(e[e.index(after: dot)...]).lowercased()
    }
    private static func truncate(_ s: String, toBytes max: Int) -> String {
        var out = "", n = 0
        for ch in s { let l = String(ch).utf8.count; if n + l > max { break }; out.append(ch); n += l }
        return out
    }
    /// The name the server will store for a client-supplied name: never a path, never empty, never "." or "..".
    public static func sanitize(_ raw: String, fallback: String = "sans-nom") -> String {
        var s = String(String.UnicodeScalarView(raw.precomposedStringWithCanonicalMapping.unicodeScalars.map { isBad($0) ? "_" : $0 }))
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^\.+"#, with: "", options: .regularExpression).replacingOccurrences(of: #"[. ]+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = fallback }
        if reserved.contains(splitExtension(s).stem.lowercased()) { s = "_" + s }
        if s.utf8.count > maxNameBytes {
            let (st, ex) = splitExtension(s)
            let keep = ex.utf8.count <= 20 ? ex : ""
            s = truncate(st, toBytes: maxNameBytes - keep.utf8.count) + keep
        }
        return s.isEmpty ? fallback : s
    }
    /// Uniqueness key inside a folder: case- and normalisation-insensitive.
    public static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
    /// Key used by the local search index: also accent-insensitive.
    public static func searchKey(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
    /// "rapport.pdf" → "rapport (2).pdf" → "rapport (3).pdf" …
    public static func nextFree(_ name: String, taken: (String) -> Bool) -> String {
        if !taken(key(name)) { return name }
        let (stem0, ext) = splitExtension(name)
        var stem = stem0, start = 2
        if let m = stem0.range(of: #" \((\d+)\)$"#, options: .regularExpression) {
            let digits = stem0[m].dropFirst(2).dropLast()
            stem = String(stem0[..<m.lowerBound]); start = (Int(digits) ?? 1) + 1
        }
        for i in start..<100_000 {
            let candidate = sanitize("\(truncate(stem, toBytes: maxNameBytes - ext.utf8.count - 12)) (\(i))\(ext)")
            if !taken(key(candidate)) { return candidate }
        }
        return sanitize("\(stem) \(UUID().uuidString.prefix(8))\(ext)")
    }
    /// Name of the copy kept when the same file was changed on two devices: "rapport (conflit Mac de SP 2026-11-18 14.35).pdf".
    public static func conflictCopyName(_ name: String, device: String, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH.mm"
        let (stem, ext) = splitExtension(name)
        let who = sanitize(device, fallback: "appareil").prefix(40)
        let suffix = " (conflit \(who) \(f.string(from: date)))"
        return sanitize(truncate(stem, toBytes: maxNameBytes - ext.utf8.count - suffix.utf8.count) + suffix + ext)
    }
}

public enum PathSafety {
    public struct Violation: Error, Sendable { public let path: String }
    /// A single path component that can be appended to a directory without leaving it.
    public static func isSafeComponent(_ c: String) -> Bool {
        !c.isEmpty && c != "." && c != ".." && !c.contains("/") && !c.contains("\0") && c.utf8.count <= NameRules.maxNameBytes
    }
    /// `base/component`, refusing anything that would land outside `base` (after resolving symbolic links of what exists).
    public static func child(of base: URL, named component: String) throws -> URL {
        guard isSafeComponent(component) else { throw Violation(path: component) }
        let url = base.appendingPathComponent(component, isDirectory: false)
        guard contains(base, url) else { throw Violation(path: url.path) }
        return url
    }
    /// True when `url` is `base` or lies below it. Resolves the existing ancestors so a symbolic link cannot lead outside.
    public static func contains(_ base: URL, _ url: URL) -> Bool {
        let b = realPath(base), u = realPath(url)
        return u == b || u.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
    /// realpath of the deepest existing ancestor, plus the remaining components (which may not exist yet).
    public static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { rest.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent() }
        let resolved = existing.path.withCString { p -> String in
            guard let r = realpath(p, nil) else { return existing.path }
            defer { free(r) }
            return String(cString: r)
        }
        return rest.reduce(resolved) { ($0 == "/" ? "" : $0) + "/" + $1 }
    }
}
