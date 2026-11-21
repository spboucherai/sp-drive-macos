// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Sync/UploadManager.swift
// Description      : Resumable, verified uploads: the file is read block by
//                    block (never whole in memory), each block carries its
//                    SHA-256, an interrupted session resumes at the offset the
//                    server reports, and the server confirms the whole-file
//                    hash before anything counts as stored. A changed server
//                    version never gets overwritten: the bytes become a
//                    conflict copy.
// Module           : Sync
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

import CryptoKit
import Foundation
import SPDriveCore

public enum UploadTarget: Sendable, Equatable {
    /// A new file in a folder.
    case newFile(folderID: String, name: String, onConflict: ConflictPolicy)
    /// A new version of an existing file, derived from `baseVersionID` (nil = replace whatever is there, decided by the person).
    case newVersion(fileID: String, folderID: String, name: String, baseVersionID: String?)
    var key: String {
        switch self {
        case .newFile(let f, let n, _): return "new|\(f)|\(NameRules.key(n))"
        case .newVersion(let id, _, _, let base): return "ver|\(id)|\(base ?? "-")"
        }
    }
}
public enum UploadOutcome: Sendable {
    case stored(DriveItem)
    /// The file had changed on the server: nothing was overwritten, the local content was stored next to it as `copy`.
    case conflictCopy(copy: DriveItem, originalID: String)
    public var item: DriveItem { switch self { case .stored(let i): return i; case .conflictCopy(let c, _): return c } }
}

public final class UploadEngine: Sendable {
    public let api: APIClient
    /// Where resumable sessions are remembered across restarts (nil = no resumption after a restart).
    public let store: MetadataStore?
    public let throttle: Throttle?
    /// Name of this device, used in the name of conflict copies.
    public let deviceName: String
    public static let minBlock = 256 * 1024, maxBlock = 16 * 1024 * 1024

    public init(api: APIClient, store: MetadataStore?, throttle: Throttle? = nil, deviceName: String) { self.api = api; self.store = store; self.throttle = throttle; self.deviceName = deviceName }

    private func savedSession(_ key: String) -> String? { try? store?.db.query("SELECT upload_id FROM upload_sessions WHERE key = ?", [.text(key)]).first?["upload_id"]?.text }
    private func save(_ key: String, _ id: String?) {
        if let id { _ = try? store?.db.run("INSERT OR REPLACE INTO upload_sessions (key, upload_id, created_at) VALUES (?, ?, ?)", [.text(key), .text(id), .double(Date().timeIntervalSince1970)]) }
        else { _ = try? store?.db.run("DELETE FROM upload_sessions WHERE key = ?", [.text(key)]) }
    }

    /// Sends the file. `progress` receives bytes confirmed by the server and the total.
    public func upload(file url: URL, to target: UploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> UploadOutcome {
        let before = try fingerprint(url)
        let (sha, size) = try Hashing.sha256Hex(of: url)
        let key = "\(target.key)|\(sha)|\(size)"
        var restarts = 0
        while true {
            do {
                let outcome = try await attempt(url: url, target: target, sha: sha, size: size, key: key, progress: progress)
                // the file must not have changed while it travelled; if it did, what was stored is a past state: say so
                if try fingerprint(url) != before { throw DriveError.local("le fichier a été modifié pendant l’envoi") }
                return outcome
            } catch let e as DriveError where ["upload_closed", "not_found", "checksum_mismatch", "upload_incomplete"].contains(e.code) && restarts < 2 {
                restarts += 1; save(key, nil) // the server session is gone or damaged: open a new one
            }
        }
    }
    private func fingerprint(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\((a[.size] as? NSNumber)?.int64Value ?? -1)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    private func attempt(url: URL, target: UploadTarget, sha: String, size: Int64, key: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> UploadOutcome {
        var conflicted: String? // identifier of the original when the bytes are being stored as a conflict copy
        var session: UploadSession
        if let id = savedSession(key), let s = try? await api.uploadStatus(id), s.size == size, ["active", "done", "completing"].contains(s.status) { session = s }
        else {
            do {
                switch target {
                case .newFile(let folder, let name, let policy): session = try await api.createUpload(folderID: folder, name: name, size: size, onConflict: policy)
                case .newVersion(let id, let folder, let name, let base): session = try await api.createUpload(folderID: folder, name: name, size: size, fileID: id, baseVersionID: base)
                }
            } catch let e as DriveError where e.code == "version_conflict" {
                guard case .newVersion(let id, let folder, let name, _) = target else { throw e }
                if e.extra["sha256"]?.string == sha, let cur = try await api.item(id, kind: .file) { return .stored(cur) } // same bytes on both sides: nothing to reconcile
                conflicted = id
                session = try await api.createUpload(folderID: folder, name: NameRules.conflictCopyName(name, device: deviceName), size: size, onConflict: .rename)
            }
            save(key, session.id)
        }
        progress(session.received, size)

        if session.status == "active" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var offset = session.received, block = 1 << 20, failures = 0
            while offset < size {
                try Task.checkCancellation()
                let want = await throttle?.preferredBlock(block) ?? block
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: Int(min(Int64(want), size - offset))), !data.isEmpty else { throw DriveError.local("le fichier a raccourci pendant l’envoi") }
                try await throttle?.consume(data.count)
                let request = try api.chunkRequest(uploadID: session.id, offset: offset, sha256: Hashing.sha256Hex(data))
                let started = ContinuousClock.now
                do {
                    let (body, response) = try await api.session.upload(for: request, from: data)
                    let s: UploadSession = try APIClient.decoder.decode(UploadSession.self, from: try APIClient.check(body, response))
                    offset = s.received; failures = 0
                    // aim for blocks of about two seconds: small on a slow link (little to resend), large on a fast one
                    let d = ContinuousClock.now - started
                    let seconds = max(0.05, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                    block = min(UploadEngine.maxBlock, max(UploadEngine.minBlock, Int(Double(data.count) / seconds * 2)))
                    progress(offset, size)
                } catch {
                    let e = DriveError.wrap(error)
                    if e.code == "offset_mismatch", let r = e.extra["received"]?.int { offset = r; continue } // the server knows where it is: follow it
                    if e.code == "chunk_corrupt" { failures += 1; if failures > 5 { throw e }; continue }
                    if e.code == "rate_limited" { try await Task.sleep(nanoseconds: UInt64(min(max(e.extra["retryAfterS"]?.int ?? 2, 1), 30)) * 1_000_000_000); continue }
                    guard e.isTransient else { throw e }
                    failures += 1
                    if failures > 6 { throw e } // gives up for now; the session stays on the server and is resumed later
                    block = max(UploadEngine.minBlock, block / 2)
                    try await Task.sleep(nanoseconds: UInt64(min(30.0, pow(2.0, Double(failures)) * 0.4) * 1e9))
                    if let s = try? await api.uploadStatus(session.id) { offset = s.received } // a block may have landed although its answer was lost
                }
            }
        }
        // completion is idempotent: asking again after a lost answer returns the file that was created
        do {
            let r = try await api.completeUpload(session.id, sha256: sha)
            save(key, nil)
            if let conflicted { return .conflictCopy(copy: r.file, originalID: conflicted) }
            return .stored(r.file)
        } catch let e as DriveError where e.code == "version_conflict" {
            guard case .newVersion(let id, _, let name, _) = target else { throw e }
            // the file changed while the bytes travelled: keep both, without sending the content again
            try await api.convertUploadToNewFile(session.id, name: NameRules.conflictCopyName(name, device: deviceName))
            let r = try await api.completeUpload(session.id, sha256: sha)
            save(key, nil)
            return .conflictCopy(copy: r.file, originalID: id)
        }
    }
}
