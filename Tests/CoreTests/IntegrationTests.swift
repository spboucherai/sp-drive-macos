// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Tests/CoreTests/IntegrationTests.swift
// Description      : Integration tests against the real local backend: sessions
//                    and device linking, the tree, resumable verified transfers
//                    (interruptions, server restarts, damaged bytes), version
//                    conflicts, share links, deposit portals, versions.
// Module           : CoreTests
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
import XCTest
@testable import SPDriveCore
@testable import SPDriveSync

class LiveCase: TempCase {
    var api: APIClient!
    var folder: DriveItem!   // a fresh folder per test, so tests do not see each other's files
    override func setUp() async throws {
        api = try Backend.api()
        folder = try await api.createFolder(parent: "root", name: "test-\(UUID().uuidString.prefix(8))")
    }
    func upload(_ url: URL, name: String? = nil, to parent: String? = nil) async throws -> DriveItem {
        try await UploadEngine(api: api, store: nil, deviceName: "Tests").upload(file: url, to: .newFile(folderID: parent ?? folder.id, name: name ?? url.lastPathComponent, onConflict: .fail)).item
    }
    func serverBytes(_ id: String, version: String? = nil) async throws -> Data { try await api.data(for: api.contentRequest(fileID: id, versionID: version)).0 }
    /// Anonymous HTTP call (a visitor of a public link), with its own cookie jar.
    func visitor() -> URLSession { let c = URLSessionConfiguration.ephemeral; return URLSession(configuration: c) }
    func call(_ s: URLSession, _ method: String, _ url: URL, json: [String: Any]? = nil, raw: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, [String: Any], Data) {
        var r = URLRequest(url: url); r.httpMethod = method
        r.setValue("1", forHTTPHeaderField: "X-SPD-CSRF")
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        else if let raw { r.httpBody = raw; r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        else if method != "GET" { r.httpBody = Data("{}".utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await s.data(for: r)
        return ((resp as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:], d)
    }
    func publicURL(_ link: URL, _ kind: String, _ rest: String = "") throws -> URL {
        let b = try Backend.require().url // links carry the public origin; the test reaches the same server on its loopback address
        return URL(string: "\(b.absoluteString)/api/v1/public/\(kind)/\(link.lastPathComponent)\(rest)")!
    }
}

final class SessionTests: LiveCase {
    func testBearerSessionAndRejectedToken() async throws {
        let s = try await api.authState()
        XCTAssertTrue(s.authenticated); XCTAssertEqual(s.kind, "device"); XCTAssertEqual(s.user?.email, "owner@example.test")
        XCTAssertGreaterThan(s.quota?.limit ?? 0, 0)
        let bad = try Backend.api(token: String(repeating: "x", count: 43))
        let st = try await bad.authState(); XCTAssertFalse(st.authenticated)
        do { _ = try await bad.listFolder(); XCTFail("should be refused") } catch { XCTAssertEqual(error as? DriveError, .unauthenticated) }
    }
    func testDeviceLinkApprovedThenSignOutRevokes() async throws {
        let fresh = try APIClient(baseURL: try Backend.require().url, tokens: MemoryTokenStore(), userAgent: "SPDriveTests/1.0")
        let link = try await fresh.startDeviceLink(deviceName: "Mac lié par code")
        XCTAssertEqual(link.userCode.count, 9)
        let pending = try await fresh.pollDeviceLink(link.deviceCode); XCTAssertEqual(pending, .pending)
        XCTAssertNil(try fresh.tokens.readToken())
        XCTAssertEqual(try Backend.script("approve", link.userCode), "approved")
        let done = try await fresh.pollDeviceLink(link.deviceCode); XCTAssertEqual(done, .approved)
        XCTAssertNotNil(try fresh.tokens.readToken())
        let st = try await fresh.authState(); XCTAssertEqual(st.kind, "device")
        let sessions = try await api.sessions()
        XCTAssertTrue(sessions.contains { $0.deviceName == "Mac lié par code" && $0.kind == "device" })
        let again = try await fresh.pollDeviceLink(link.deviceCode); XCTAssertEqual(again, .expired) // handed over once
        await fresh.signOut()
        XCTAssertNil(try fresh.tokens.readToken())
        let after = try await api.sessions(); XCTAssertFalse(after.contains { $0.deviceName == "Mac lié par code" })
    }
}

final class TreeTests: LiveCase {
    func testFolderLifecycle() async throws {
        let a = try await api.createFolder(parent: folder.id, name: "Été / 2026")
        XCTAssertEqual(a.name, NameRules.sanitize("Été / 2026")) // the client predicts the name the server stores
        do { _ = try await api.createFolder(parent: folder.id, name: "été _ 2026"); XCTFail("duplicate") } catch { XCTAssertEqual((error as? DriveError)?.code, "name_conflict") }
        let b = try await api.createFolder(parent: folder.id, name: "Été _ 2026", onConflict: .rename); XCTAssertEqual(b.name, "Été _ 2026 (2)")
        let f = try await upload(try text("note.txt", "bonjour"))
        let renamed = try await api.updateFile(f.id, name: "note finale.txt", starred: true)
        XCTAssertEqual(renamed.name, "note finale.txt"); XCTAssertTrue(renamed.starred); XCTAssertGreaterThan(renamed.rev, f.rev)
        try await api.move(Selection(fileIds: [f.id]), to: a.id)
        let listed = try await api.listFolder(a.id); XCTAssertEqual(listed.files.map(\.id), [f.id]); XCTAssertEqual(listed.breadcrumbs.last?.id, a.id)
        do { try await api.move(Selection(folderIds: [folder.id]), to: a.id); XCTFail("cycle") } catch { XCTAssertEqual((error as? DriveError)?.code, "move_into_self") }
        let n = try await api.copy(Selection(folderIds: [a.id]), to: folder.id); XCTAssertEqual(n.files, 1); XCTAssertEqual(n.folders, 1)
        let starred = try await api.starred(); XCTAssertTrue(starred.files.contains { $0.id == f.id })
        let found = try await api.search(SearchQuery(text: "NOTE FINALE")); XCTAssertGreaterThanOrEqual(found.files.filter { $0.name == "note finale.txt" }.count, 2)
        // trash a folder → its file follows; restore → both live again; purge only from the trash
        try await api.trash(Selection(folderIds: [a.id]))
        let trashed = try await api.item(f.id, kind: .file); XCTAssertNotNil(trashed?.trashedAt); XCTAssertEqual(trashed?.trashRoot, false)
        let bin = try await api.trashList(); XCTAssertTrue(bin.folders.contains { $0.id == a.id }); XCTAssertFalse(bin.files.contains { $0.id == f.id })
        do { try await api.purge(Selection(fileIds: [f.id])); XCTFail("not a trash root") } catch { XCTAssertTrue((error as? DriveError)?.isNotFound ?? false) }
        try await api.restore(Selection(folderIds: [a.id]))
        let back = try await api.item(f.id, kind: .file); XCTAssertNil(back?.trashedAt)
        do { try await api.purge(Selection(folderIds: [a.id])); XCTFail("live items cannot be purged") } catch { XCTAssertTrue((error as? DriveError)?.isNotFound ?? false) }
        try await api.trash(Selection(folderIds: [a.id])); try await api.purge(Selection(folderIds: [a.id]))
        let gone = try await api.item(f.id, kind: .file); XCTAssertNil(gone)
    }
}

final class TransferTests: LiveCase {
    func testLargeFileRoundTripIsStreamedAndVerified() async throws {
        let src = try randomFile("gros.bin", bytes: 48 * 1024 * 1024 + 4321)
        let blocks = Box<[Int64]>([])
        let stored = try await UploadEngine(api: api, store: nil, deviceName: "Tests").upload(file: src.url, to: .newFile(folderID: folder.id, name: "gros.bin", onConflict: .fail)) { done, _ in blocks.update { $0.append(done) } }.item
        XCTAssertEqual(stored.sha256, src.sha); XCTAssertEqual(stored.size, Int64(48 * 1024 * 1024 + 4321))
        XCTAssertGreaterThan(Set(blocks.value).count, 3) // several blocks, each confirmed by the server
        XCTAssertEqual(blocks.value, blocks.value.sorted())
        let dest = dir.appendingPathComponent("retour.bin"), part = dir.appendingPathComponent("retour.part")
        let sha = try await DownloadEngine(api: api).download(fileID: stored.id, sha256: stored.sha256, size: stored.size, to: dest, partial: part)
        XCTAssertEqual(sha, src.sha); XCTAssertEqual(try Hashing.sha256Hex(of: dest).sha256, src.sha)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path)) // the partial file became the destination
    }
    func testEmptyFile() async throws {
        let f = try await upload(try text("vide.txt", ""))
        XCTAssertEqual(f.size, 0); XCTAssertEqual(f.sha256, Hashing.sha256Hex(Data()))
        let dest = dir.appendingPathComponent("vide.out")
        try await DownloadEngine(api: api).download(fileID: f.id, sha256: f.sha256, size: 0, to: dest, partial: dir.appendingPathComponent("vide.part"))
        XCTAssertEqual(try Data(contentsOf: dest).count, 0)
    }
    func testInterruptedUploadResumesWhereTheServerIs() async throws {
        let s = try store()
        let src = try randomFile("coupe.bin", bytes: 24 * 1024 * 1024)
        let throttle = Throttle(bytesPerSecond: 6 * 1024 * 1024)
        let engine = UploadEngine(api: api, store: s, throttle: throttle, deviceName: "Tests")
        let target = UploadTarget.newFile(folderID: folder.id, name: "coupe.bin", onConflict: .fail)
        let seen = Box<Int64>(0)
        let task = Task { try await engine.upload(file: src.url, to: target) { done, _ in seen.value = done } }
        while seen.value < 6 * 1024 * 1024 { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("should have been interrupted") } catch { XCTAssertEqual(DriveError.wrap(error), .cancelled) }
        let listed = try await api.listFolder(folder.id); XCTAssertTrue(listed.files.isEmpty) // nothing counts as stored before the final confirmation
        let saved = try s.db.query("SELECT upload_id FROM upload_sessions"); XCTAssertEqual(saved.count, 1)
        let onServer = try await api.uploadStatus(saved[0]["upload_id"]!.text!); XCTAssertGreaterThan(onServer.received, 0); XCTAssertLessThan(onServer.received, onServer.size)
        // "after a restart": a new engine on the reopened store resumes the same server session
        let first = Box<Int64?>(nil)
        await throttle.setLimit(0)
        let again = UploadEngine(api: api, store: try store(), deviceName: "Tests")
        let stored = try await again.upload(file: src.url, to: target) { done, _ in if first.value == nil { first.value = done } }.item
        XCTAssertEqual(first.value, onServer.received) // not from zero
        XCTAssertEqual(stored.sha256, src.sha)
        XCTAssertTrue(try s.db.query("SELECT 1 FROM upload_sessions").isEmpty)
        let bytes = try await serverBytes(stored.id); XCTAssertEqual(Hashing.sha256Hex(bytes), src.sha)
    }
    func testUploadSurvivesServerOutage() async throws {
        let s = try store()
        let src = try randomFile("panne.bin", bytes: 16 * 1024 * 1024)
        let throttle = Throttle(bytesPerSecond: 4 * 1024 * 1024)
        let engine = UploadEngine(api: api, store: s, throttle: throttle, deviceName: "Tests")
        let target = UploadTarget.newFile(folderID: folder.id, name: "panne.bin", onConflict: .fail)
        let seen = Box<Int64>(0)
        let task = Task { try await engine.upload(file: src.url, to: target) { done, _ in seen.value = done } }
        while seen.value < 3 * 1024 * 1024 { try await Task.sleep(nanoseconds: 50_000_000) }
        try Backend.serverDown()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try Backend.serverUp() // the engine retries with back-off and continues by itself
        await throttle.setLimit(0)
        let stored = try await task.value.item
        XCTAssertEqual(stored.sha256, src.sha)
        let bytes = try await serverBytes(stored.id); XCTAssertEqual(Hashing.sha256Hex(bytes), src.sha)
    }
    func testUploadFailsCleanlyWhenServerStaysDown() async throws {
        let src = try randomFile("hors-ligne.bin", bytes: 300_000)
        try Backend.serverDown()
        defer { try? Backend.serverUp() }
        do { _ = try await upload(src.url); XCTFail("no server") } catch { XCTAssertTrue(DriveError.wrap(error).isTransient, "\(error)") }
    }
    func testInterruptedDownloadResumesWithRange() async throws {
        let src = try randomFile("dl.bin", bytes: 20 * 1024 * 1024)
        let f = try await upload(src.url)
        let dest = dir.appendingPathComponent("dl.out"), part = dir.appendingPathComponent("dl.part")
        let throttle = Throttle(bytesPerSecond: 5 * 1024 * 1024), seen = Box<Int64>(0)
        let slow = DownloadEngine(api: api, throttle: throttle)
        let task = Task { try await slow.download(fileID: f.id, sha256: f.sha256, size: f.size, to: dest, partial: part) { done, _ in seen.value = done } }
        while seen.value < 4 * 1024 * 1024 { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("should have been interrupted") } catch {}
        let have = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as! NSNumber).int64Value
        XCTAssertGreaterThan(have, 0); XCTAssertLessThan(have, f.size); XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let first = Box<Int64?>(nil)
        let sha = try await DownloadEngine(api: api).download(fileID: f.id, sha256: f.sha256, size: f.size, to: dest, partial: part) { done, _ in if first.value == nil { first.value = done } }
        XCTAssertGreaterThanOrEqual(first.value ?? 0, have) // continued, not restarted
        XCTAssertEqual(sha, src.sha); XCTAssertEqual(try Hashing.sha256Hex(of: dest).sha256, src.sha)
    }
    func testDamagedPartialIsNeverDelivered() async throws {
        let src = try randomFile("abime.bin", bytes: 3 * 1024 * 1024)
        let f = try await upload(src.url)
        let dest = dir.appendingPathComponent("abime.out"), part = dir.appendingPathComponent("abime.part")
        // remains of some other file under the partial's name: not continued, the download starts clean
        try Data(repeating: 0x42, count: 512 * 1024).write(to: part)
        let clean = try await DownloadEngine(api: api).download(fileID: f.id, sha256: f.sha256, size: f.size, to: dest, partial: part)
        XCTAssertEqual(clean, src.sha); try FileManager.default.removeItem(at: dest)
        // a partial file of this very content whose bytes were damaged on disk: resumed, then caught by the SHA-256
        try Data(repeating: 0x41, count: 1024 * 1024).write(to: part); PartialTag.write(part, f.sha256)
        do { _ = try await DownloadEngine(api: api).download(fileID: f.id, sha256: f.sha256, size: f.size, to: dest, partial: part); XCTFail("must not pass verification") }
        catch { XCTAssertEqual((error as? DriveError)?.code, "integrity") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        let sha = try await DownloadEngine(api: api).download(fileID: f.id, sha256: f.sha256, size: f.size, to: dest, partial: part) // the next try starts clean
        XCTAssertEqual(sha, src.sha)
        // an expected hash that is not the content's: refused before a byte is written to the destination
        do { _ = try await DownloadEngine(api: api).download(fileID: f.id, sha256: String(repeating: "0", count: 64), size: f.size, to: dir.appendingPathComponent("x.out"), partial: dir.appendingPathComponent("x.part")); XCTFail("wrong hash") }
        catch { XCTAssertEqual((error as? DriveError)?.code, "content_changed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.out").path))
    }
    func testResumeAfterContentChangedStartsOver() async throws {
        let v1 = try randomFile("v1.bin", bytes: 2 * 1024 * 1024), v2 = try randomFile("v2.bin", bytes: 2 * 1024 * 1024 + 7)
        let f = try await upload(v1.url, name: "doc.bin")
        let part = dir.appendingPathComponent("doc.part"), dest = dir.appendingPathComponent("doc.out")
        try (try Data(contentsOf: v1.url)).prefix(1024 * 1024).write(to: part) // half of version 1 on disk
        let f2 = try await UploadEngine(api: api, store: nil, deviceName: "Tests").upload(file: v2.url, to: .newVersion(fileID: f.id, folderID: folder.id, name: "doc.bin", baseVersionID: f.versionID)).item
        XCTAssertEqual(f2.versionSeq, 2)
        // resuming with the old hash: the server says the content changed; nothing of v1 may be glued to v2
        do { _ = try await DownloadEngine(api: api).download(fileID: f.id, sha256: f.sha256, size: f.size, to: dest, partial: part); XCTFail("stale") } catch { XCTAssertEqual((error as? DriveError)?.code, "content_changed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let sha = try await DownloadEngine(api: api).download(fileID: f.id, sha256: f2.sha256, size: f2.size, to: dest, partial: part)
        XCTAssertEqual(sha, v2.sha)
        // the old version stays downloadable by its identifier
        let old = dir.appendingPathComponent("old.out")
        let shaOld = try await DownloadEngine(api: api).download(fileID: f.id, versionID: f.versionID, sha256: f.sha256, size: f.size, to: old, partial: dir.appendingPathComponent("old.part"))
        XCTAssertEqual(shaOld, v1.sha)
    }
}

final class ConflictTests: LiveCase {
    func testStaleEditBecomesConflictCopyAndNothingIsOverwritten() async throws {
        let s = try store()
        let base = try await upload(try text("rapport.txt", "version de départ"))
        // another device replaces the content
        let other = try await UploadEngine(api: api, store: nil, deviceName: "Autre").upload(file: try text("autre.txt", "version de l'autre appareil"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "rapport.txt", baseVersionID: base.versionID)).item
        XCTAssertEqual(other.versionSeq, 2)
        // this device edited the starting version
        let mine = try text("mien.txt", "version de ce Mac")
        let outcome = try await UploadEngine(api: api, store: s, deviceName: "Mac de test").upload(file: mine, to: .newVersion(fileID: base.id, folderID: folder.id, name: "rapport.txt", baseVersionID: base.versionID))
        guard case .conflictCopy(let copy, let original) = outcome else { return XCTFail("expected a conflict copy, got \(outcome)") }
        XCTAssertEqual(original, base.id); XCTAssertNotEqual(copy.id, base.id)
        XCTAssertTrue(copy.name.hasPrefix("rapport (conflit Mac de test ")); XCTAssertTrue(copy.name.hasSuffix(").txt")); XCTAssertEqual(copy.parentID, folder.id)
        let serverOriginal = try await serverBytes(base.id), serverCopy = try await serverBytes(copy.id)
        XCTAssertEqual(String(decoding: serverOriginal, as: UTF8.self), "version de l'autre appareil") // not overwritten
        XCTAssertEqual(String(decoding: serverCopy, as: UTF8.self), "version de ce Mac")                // not lost
        let details = try await api.fileDetails(base.id); XCTAssertEqual(details.versions.count, 2)
        // identical bytes on both sides are not a conflict
        let same = try await UploadEngine(api: api, store: s, deviceName: "Mac de test").upload(file: try text("meme.txt", "version de l'autre appareil"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "rapport.txt", baseVersionID: base.versionID))
        guard case .stored(let cur) = same else { return XCTFail("same content must not conflict") }
        XCTAssertEqual(cur.versionSeq, 2)

        // resolution: keep mine → the server's version goes to the trash (restorable), mine takes the name
        let resolver = ConflictResolver(api: api, store: s)
        let c = try resolver.record(itemID: base.id, itemName: "rapport.txt", copy: copy)
        XCTAssertEqual(try resolver.openCount(), 1)
        try await resolver.resolve(c, .keepMine)
        XCTAssertEqual(try resolver.openCount(), 0)
        let live = try await api.listFolder(folder.id)
        XCTAssertEqual(live.files.map(\.name), ["rapport.txt"]); XCTAssertEqual(live.files.first?.id, copy.id)
        let trashed = try await api.item(base.id, kind: .file); XCTAssertNotNil(trashed?.trashedAt) // set aside, not destroyed
    }
    func testKeepServerTrashesTheCopyOnly() async throws {
        let s = try store()
        let base = try await upload(try text("a.txt", "un"))
        _ = try await UploadEngine(api: api, store: nil, deviceName: "Autre").upload(file: try text("b.txt", "deux"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "a.txt", baseVersionID: base.versionID))
        let outcome = try await UploadEngine(api: api, store: s, deviceName: "Mac").upload(file: try text("c.txt", "trois"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "a.txt", baseVersionID: base.versionID))
        guard case .conflictCopy(let copy, _) = outcome else { return XCTFail("conflict expected") }
        let resolver = ConflictResolver(api: api, store: s)
        try await resolver.resolve(try resolver.record(itemID: base.id, itemName: "a.txt", copy: copy), .keepServer)
        let live = try await api.listFolder(folder.id); XCTAssertEqual(live.files.map(\.id), [base.id])
        let set = try await api.item(copy.id, kind: .file); XCTAssertNotNil(set?.trashedAt)
        let kept = try await serverBytes(base.id); XCTAssertEqual(String(decoding: kept, as: UTF8.self), "deux")
    }
}

final class SharingTests: LiveCase {
    func testShareLinkPasswordExpiryRevocation() async throws {
        let f = try await upload(try text("partagé.txt", "contenu partagé"))
        do { _ = try await api.createShare(for: f, settings: ShareSettings(expiresAt: .some(Date(timeIntervalSinceNow: -60)))); XCTFail("past expiry") } catch { XCTAssertEqual((error as? DriveError)?.code, "bad_expiry") }
        let made = try await api.createShare(for: f, settings: ShareSettings(label: "Pour Erika", canDownload: true, password: .some("s3cret!"), expiresAt: .some(Date(timeIntervalSinceNow: 3600)), maxDownloads: .some(1)))
        XCTAssertTrue(made.share.hasPassword); XCTAssertEqual(made.share.maxDownloads, 1); XCTAssertEqual(made.share.status, "active")
        XCTAssertFalse(made.url.absoluteString.contains(folder.id)); XCTAssertFalse(made.url.absoluteString.contains("blobs")) // no internal path in a link
        let v = visitor()
        var (st, body, _) = try await call(v, "GET", try publicURL(made.url, "shares")); XCTAssertEqual(st, 200); XCTAssertEqual(body["needsPassword"] as? Bool, true)
        (st, _, _) = try await call(v, "POST", try publicURL(made.url, "shares", "/open"), json: ["password": "faux"]); XCTAssertEqual(st, 401)
        (st, _, _) = try await call(v, "GET", try publicURL(made.url, "shares", "/files/\(f.id)/content?download=1")); XCTAssertEqual(st, 401) // not opened: nothing
        (st, body, _) = try await call(v, "POST", try publicURL(made.url, "shares", "/open"), json: ["password": "s3cret!"]); XCTAssertEqual(st, 200)
        XCTAssertEqual((body["file"] as? [String: Any])?["name"] as? String, "partagé.txt")
        var data: Data
        (st, _, data) = try await call(v, "GET", try publicURL(made.url, "shares", "/files/\(f.id)/content?download=1")); XCTAssertEqual(st, 200); XCTAssertEqual(String(decoding: data, as: UTF8.self), "contenu partagé")
        (st, _, _) = try await call(v, "GET", try publicURL(made.url, "shares", "/files/\(f.id)/content?download=1")); XCTAssertEqual(st, 403) // download limit
        let other = try await upload(try text("privé.txt", "secret"))
        (st, _, _) = try await call(v, "GET", try publicURL(made.url, "shares", "/files/\(other.id)/content")); XCTAssertEqual(st, 404) // only the shared file
        let events = try await api.shareEvents(made.share.id); XCTAssertTrue(events.contains { $0.kind == "password" && !$0.ok }); XCTAssertTrue(events.contains { $0.kind == "download" && $0.ok })
        // settings, rotation, revocation
        let changed = try await api.updateShare(made.share.id, settings: ShareSettings(canDownload: false, password: .some(nil), maxDownloads: .some(nil)))
        XCTAssertFalse(changed.hasPassword); XCTAssertFalse(changed.canDownload); XCTAssertNil(changed.maxDownloads)
        let rotated = try await api.rotateShare(made.share.id); XCTAssertNotEqual(rotated, made.url)
        (st, _, _) = try await call(visitor(), "GET", try publicURL(made.url, "shares")); XCTAssertEqual(st, 404) // the old address is dead
        (st, _, _) = try await call(visitor(), "GET", try publicURL(rotated, "shares")); XCTAssertEqual(st, 200)
        try await api.revokeShare(made.share.id)
        (st, _, _) = try await call(visitor(), "GET", try publicURL(rotated, "shares")); XCTAssertEqual(st, 404)
        let mine = try await api.shares(of: f); XCTAssertEqual(mine.first?.status, "revoked")
    }
    func testFolderShareStaysInsideTheFolder() async throws {
        let sub = try await api.createFolder(parent: folder.id, name: "Public")
        let inside = try await upload(try text("dedans.txt", "ok"), to: sub.id), outside = try await upload(try text("dehors.txt", "non"))
        let made = try await api.createShare(for: sub, settings: ShareSettings(canDownload: true))
        let v = visitor()
        var (st, body, _) = try await call(v, "POST", try publicURL(made.url, "shares", "/open")); XCTAssertEqual(st, 200); XCTAssertEqual(body["type"] as? String, "folder")
        (st, body, _) = try await call(v, "GET", try publicURL(made.url, "shares", "/list")); XCTAssertEqual((body["files"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [inside.id])
        (st, _, _) = try await call(v, "GET", try publicURL(made.url, "shares", "/list?folder=\(folder.id)")); XCTAssertEqual(st, 404) // the parent is out of reach
        (st, _, _) = try await call(v, "GET", try publicURL(made.url, "shares", "/files/\(outside.id)/content?download=1")); XCTAssertEqual(st, 404)
        do { _ = try await api.createShare(for: try await api.listFolder("root").folder, settings: ShareSettings()); XCTFail("root") } catch { XCTAssertEqual((error as? DriveError)?.code, "bad_target") }
    }
    func testDepositPortalReceivesWithoutExposingTheFolder() async throws {
        let existing = try await upload(try text("déjà-là.txt", "privé"))
        var p = PortalSettings(); p.folderId = folder.id; p.title = "Dépôt de travaux"; p.password = .some("porte"); p.expiresAt = .some(Date(timeIntervalSinceNow: 3600))
        p.maxFileBytes = 1024 * 1024; p.maxFilesPerSubmission = 2; p.subfolderPerSubmission = false; p.notifyOwner = true
        let made = try await api.createPortal(p)
        XCTAssertEqual(made.request.state, "open"); XCTAssertTrue(made.request.hasPassword); XCTAssertEqual(made.request.maxFileBytes, 1024 * 1024)
        let v = visitor()
        var (st, body, _) = try await call(v, "GET", try publicURL(made.url, "requests")); XCTAssertEqual(st, 200); XCTAssertEqual(body["title"] as? String, "Dépôt de travaux")
        XCTAssertNil(body["folderId"]); XCTAssertFalse("\(body)".contains(existing.name)) // nothing about the folder or its files
        let payload = Data("travail remis".utf8)
        (st, body, _) = try await call(v, "POST", try publicURL(made.url, "requests", "/submissions"), json: ["password": "faux", "files": [["name": "travail.txt", "size": payload.count]]]); XCTAssertEqual(st, 401)
        (st, body, _) = try await call(v, "POST", try publicURL(made.url, "requests", "/submissions"), json: ["password": "porte", "files": [["name": "gros.bin", "size": 2 * 1024 * 1024]]]); XCTAssertEqual(st, 422) // size limit enforced by the server
        (st, body, _) = try await call(v, "POST", try publicURL(made.url, "requests", "/submissions"), json: ["password": "porte", "name": "Étudiant", "files": [["name": "travail.txt", "size": payload.count]]]); XCTAssertEqual(st, 200)
        let subToken = body["submissionToken"] as! String, uploadID = ((body["items"] as! [[String: Any]])[0]["uploadId"] as! String)
        let base = try Backend.require().url.absoluteString + "/api/v1/public"
        (st, _, _) = try await call(v, "PATCH", URL(string: "\(base)/uploads/\(uploadID)?offset=0")!, raw: payload, headers: ["Authorization": "Bearer \(subToken)"]); XCTAssertEqual(st, 200)
        // the submission token opens nothing of the owner's account
        (st, _, _) = try await call(v, "GET", URL(string: "\(try Backend.require().url.absoluteString)/api/v1/folders/\(folder.id)")!, headers: ["Authorization": "Bearer \(subToken)"]); XCTAssertEqual(st, 401)
        (st, _, _) = try await call(v, "GET", URL(string: "\(try Backend.require().url.absoluteString)/api/v1/files/\(existing.id)/content")!, headers: ["Authorization": "Bearer \(subToken)"]); XCTAssertEqual(st, 401)
        (st, body, _) = try await call(v, "POST", URL(string: "\(base)/submissions/finalize")!, headers: ["Authorization": "Bearer \(subToken)"]); XCTAssertEqual(st, 200)
        // the worker inspects and places the file
        var received: DriveItem?
        for _ in 0..<60 { received = try await api.listFolder(folder.id).files.first { $0.name == "travail.txt" }; if received != nil { break }; try await Task.sleep(nanoseconds: 250_000_000) }
        let got = try XCTUnwrap(received, "the deposited file never arrived")
        let bytes = try await serverBytes(got.id); XCTAssertEqual(bytes, payload)
        let subs = try await api.portalSubmissions(made.request.id); XCTAssertEqual(subs.first?.placed, 1); XCTAssertEqual(subs.first?.name, "Étudiant")
        let notes = try await api.notifications(); XCTAssertTrue(notes.contains { $0.kind == "request.submission" && $0.data["requestId"]?.string == made.request.id })
        let listed = try await api.portals(); XCTAssertTrue(listed.contains { $0.id == made.request.id && $0.submissions == 1 })
        // pause, then revoke: the link stops accepting at once
        let paused = try await api.updatePortal(made.request.id, { var s = PortalSettings(); s.active = false; return s }()); XCTAssertEqual(paused.state, "paused")
        (st, _, _) = try await call(visitor(), "GET", try publicURL(made.url, "requests")); XCTAssertEqual(st, 410)
        try await api.revokePortal(made.request.id)
        (st, _, _) = try await call(visitor(), "GET", try publicURL(made.url, "requests")); XCTAssertEqual(st, 404)
    }
}

final class VersionTests: LiveCase {
    func testHistoryRestoreAndDownloadOfOldVersions() async throws {
        let f = try await upload(try text("doc.txt", "v1"))
        let up = UploadEngine(api: api, store: nil, deviceName: "Tests")
        let f2 = try await up.upload(file: try text("v2.txt", "v2 plus longue"), to: .newVersion(fileID: f.id, folderID: folder.id, name: "doc.txt", baseVersionID: f.versionID)).item
        let f3 = try await up.upload(file: try text("v3.txt", "v3"), to: .newVersion(fileID: f.id, folderID: folder.id, name: "doc.txt", baseVersionID: f2.versionID)).item
        XCTAssertEqual(f3.versionSeq, 3); XCTAssertEqual(f3.versionCount, 3)
        let d = try await api.fileDetails(f.id)
        XCTAssertEqual(d.versions.map(\.seq), [3, 2, 1]); XCTAssertEqual(d.versions.filter(\.current).map(\.seq), [3]); XCTAssertEqual(d.versions[1].size, 14)
        let v1 = d.versions[2]
        let old = try await serverBytes(f.id, version: v1.id); XCTAssertEqual(String(decoding: old, as: UTF8.self), "v1")
        // restoring creates a new version: the history only grows
        let restored = try await api.restoreVersion(fileID: f.id, versionID: v1.id)
        XCTAssertEqual(restored.versionSeq, 4); XCTAssertEqual(restored.sha256, v1.sha256)
        let now = try await serverBytes(f.id); XCTAssertEqual(String(decoding: now, as: UTF8.self), "v1")
        let after = try await api.fileDetails(f.id); XCTAssertEqual(after.versions.count, 4)
        do { try await api.deleteVersion(fileID: f.id, versionID: after.versions[0].id); XCTFail("current") } catch { XCTAssertEqual((error as? DriveError)?.code, "current_version") }
        try await api.deleteVersion(fileID: f.id, versionID: d.versions[1].id)
        let last = try await api.fileDetails(f.id); XCTAssertEqual(last.versions.count, 3)
    }
}
