// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Tests/CoreTests/UnitTests.swift
// Description: Unit tests without a server: naming rules, path safety, the metadata mirror (revisions, tombstones, anchors, pins, search), change classification, concurrency advisor, throttle, client guards.
import Foundation
import XCTest
@testable import SPDriveCore
@testable import SPDriveSync

final class NameRulesTests: XCTestCase {
    func testSanitizeMatchesServerRules() {
        XCTAssertEqual(NameRules.sanitize("a/b\\c:d*e?f\"g<h>i|j.txt"), "a_b_c_d_e_f_g_h_i_j.txt")
        XCTAssertEqual(NameRules.sanitize("../../etc/passwd"), "_.._etc_passwd") // separators replaced, leading dots dropped
        XCTAssertEqual(NameRules.sanitize(".."), "sans-nom")
        XCTAssertEqual(NameRules.sanitize("  rapport   final .pdf  "), "rapport final .pdf")
        XCTAssertEqual(NameRules.sanitize("nom. . ."), "nom")
        XCTAssertEqual(NameRules.sanitize("CON.txt"), "_CON.txt")
        XCTAssertEqual(NameRules.sanitize("a\u{202E}b\u{200B}c\u{0007}"), "a_b_c_")
        XCTAssertEqual(NameRules.sanitize("e\u{0301}te\u{0301}.txt"), "été.txt") // NFC
        XCTAssertLessThanOrEqual(NameRules.sanitize(String(repeating: "é", count: 400) + ".pdf").utf8.count, 255)
        XCTAssertTrue(NameRules.sanitize(String(repeating: "é", count: 400) + ".pdf").hasSuffix(".pdf"))
    }
    func testExtensionsAndFreeNames() {
        XCTAssertEqual(NameRules.splitExtension("archive.tar.gz").stem, "archive"); XCTAssertEqual(NameRules.splitExtension("archive.tar.gz").ext, ".tar.gz")
        XCTAssertEqual(NameRules.splitExtension(".gitignore").ext, ""); XCTAssertEqual(NameRules.fileExtension("Photo.JPG"), "jpg"); XCTAssertEqual(NameRules.fileExtension("sans"), "")
        let taken: Set<String> = ["rapport.pdf", "rapport (2).pdf"]
        XCTAssertEqual(NameRules.nextFree("Rapport.pdf") { taken.contains($0) }, "Rapport (3).pdf")
        XCTAssertEqual(NameRules.nextFree("libre.pdf") { taken.contains($0) }, "libre.pdf")
        XCTAssertEqual(NameRules.key("ÉTÉ.TXT"), "été.txt"); XCTAssertEqual(NameRules.searchKey("Été À Québec"), "ete a quebec")
    }
    func testConflictCopyName() {
        let d = Date(timeIntervalSince1970: 1_795_000_000), tz = TimeZone(identifier: "UTC")!
        let n = NameRules.conflictCopyName("rapport.pdf", device: "Mac de SP", at: d, timeZone: tz)
        XCTAssertTrue(n.hasPrefix("rapport (conflit Mac de SP 20")); XCTAssertTrue(n.hasSuffix(").pdf"))
        XCTAssertFalse(n.contains(":")); XCTAssertEqual(NameRules.sanitize(n), n)
        XCTAssertLessThanOrEqual(NameRules.conflictCopyName(String(repeating: "x", count: 300) + ".pdf", device: "Mac", at: d, timeZone: tz).utf8.count, 255)
    }
}

final class PathSafetyTests: TempCase {
    func testRefusesTraversalAndSymlinkEscape() throws {
        XCTAssertNoThrow(try PathSafety.child(of: dir, named: "ok.txt"))
        for bad in ["..", ".", "", "a/b", "../x", "a\0b"] { XCTAssertThrowsError(try PathSafety.child(of: dir, named: bad), bad) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("spdrive-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertFalse(PathSafety.contains(dir, dir.appendingPathComponent("link/secret.txt")))
        XCTAssertTrue(PathSafety.contains(dir, dir.appendingPathComponent("a/b/c.txt")))
        XCTAssertFalse(PathSafety.contains(dir, dir.deletingLastPathComponent()))
    }
}

final class MetadataStoreTests: TempCase {
    func testRevisionsOnlyMoveForward() throws {
        let s = try store()
        try s.upsert([item("root", "", parent: nil, kind: .folder, rev: 1), item("f", "a.txt", parent: "root", rev: 5)])
        XCTAssertEqual(s.rootID, "root")
        try s.upsert([item("f", "ancien.txt", parent: "root", rev: 4)]) // an older description must not win
        XCTAssertEqual(try s.item("f")?.name, "a.txt")
        try s.upsert([item("f", "nouveau.txt", parent: "root", rev: 6)])
        XCTAssertEqual(try s.item("f")?.name, "nouveau.txt")
        let seq = s.seq
        try s.upsert([item("f", "nouveau.txt", parent: "root", rev: 6)]) // same revision: nothing changes locally
        XCTAssertEqual(s.seq, seq)
    }
    func testChangesSinceAnchorPageWithoutLossIncludingTombstones() throws {
        let s = try store()
        try s.upsert((0..<25).map { item("f\($0)", "f\($0).txt", parent: "root", rev: Int64($0 + 1)) })
        try s.remove(["f3", "f4"])
        try s.upsert([item("f7", "renommé.txt", parent: "root", rev: 100)])
        var anchor: Int64 = 0, seen: [String: String] = [:], gone: Set<String> = [], rounds = 0
        while true {
            let c = try s.changes(since: anchor, limit: 7)
            for i in c.items { seen[i.id] = i.name }; gone.formUnion(c.deleted)
            XCTAssertGreaterThanOrEqual(c.seq, anchor); anchor = c.seq; rounds += 1
            if !c.more { break }
        }
        XCTAssertGreaterThan(rounds, 2)
        XCTAssertEqual(gone, ["f3", "f4"]); XCTAssertEqual(seen["f7"], "renommé.txt"); XCTAssertEqual(seen.count, 23)
        XCTAssertTrue(try s.changes(since: anchor).items.isEmpty)
        try s.upsert([item("f3", "revenu.txt", parent: "root", rev: 200)]) // an identifier that comes back is no longer a tombstone
        let c = try s.changes(since: anchor)
        XCTAssertEqual(c.items.map(\.id), ["f3"]); XCTAssertTrue(c.deleted.isEmpty)
    }
    func testPinsCoverDescendantsAndSurviveReopen() throws {
        var s: MetadataStore? = try store()
        try s!.upsert([item("root", "", parent: nil, kind: .folder, rev: 1), item("d", "Dossier", parent: "root", kind: .folder, rev: 2), item("sub", "Sous", parent: "d", kind: .folder, rev: 3),
                       item("x", "x.txt", parent: "sub", rev: 4, size: 10), item("y", "y.txt", parent: "root", rev: 5, size: 20)])
        let before = s!.seq
        try s!.setPinned("d", true)
        XCTAssertGreaterThan(s!.seq, before) // the File Provider must re-read the items whose policy changed
        XCTAssertTrue(try s!.isPinned("x")); XCTAssertTrue(try s!.isPinned("sub")); XCTAssertFalse(try s!.isPinned("y")); XCTAssertFalse(try s!.isPinnedItself("x"))
        try s!.replaceMaterialized(["x", "y"])
        XCTAssertEqual(try s!.localUsage(), .init(files: 2, bytes: 30, pinnedBytes: 10))
        XCTAssertEqual(try s!.evictableIDs(), ["y"]) // a pinned copy is never offered for eviction
        s = nil
        let again = try store()
        XCTAssertTrue(try again.isPinned("x")); XCTAssertEqual(try again.pinnedItems().map(\.id), ["d"])
        try again.setPinned("d", false); XCTAssertFalse(try again.isPinned("x"))
    }
    func testSearchFiltersWorkOffline() throws {
        let s = try store(), old = Date(timeIntervalSinceNow: -90 * 86400)
        try s.upsert([item("root", "", parent: nil, kind: .folder, rev: 1), item("d", "Été 2026", parent: "root", kind: .folder, rev: 2), item("a", "Rapport été.PDF", parent: "d", rev: 3, size: 5_000_000),
                       item("b", "notes d'été.txt", parent: "root", rev: 4, size: 100, starred: true), item("c", "photo.jpg", parent: "d", rev: 5, size: 2_000_000, updated: old),
                       item("t", "été supprimé.txt", parent: "root", rev: 6, trashed: true), item("e", "100%_garanti.txt", parent: "root", rev: 7)])
        func ids(_ f: (inout LocalSearch) -> Void) throws -> [String] { var q = LocalSearch(); f(&q); return try s.search(q).map(\.id).sorted() }
        XCTAssertEqual(try ids { $0.text = "ETE" }, ["a", "b", "d"]) // accents and case ignored, trashed excluded
        XCTAssertEqual(try ids { $0.text = "rapport ete" }, ["a"])
        XCTAssertEqual(try ids { $0.category = .pdf }, ["a"]); XCTAssertEqual(try ids { $0.category = .folder }, ["d"]); XCTAssertEqual(try ids { $0.fileExtension = ".TXT" }, ["b", "e"])
        XCTAssertEqual(try ids { $0.folderID = "d" }, ["a", "c"])
        XCTAssertEqual(try ids { $0.minSize = 1_000_000 }, ["a", "c"]); XCTAssertEqual(try ids { $0.maxSize = 1000 }, ["b", "e"])
        XCTAssertEqual(try ids { $0.modifiedBefore = Date(timeIntervalSinceNow: -30 * 86400) }, ["c"]); XCTAssertEqual(try ids { $0.starredOnly = true }, ["b"])
        XCTAssertEqual(try ids { $0.onlyIDs = ["a", "c", "zz"] }, ["a", "c"]); XCTAssertEqual(try ids { $0.onlyIDs = [] }, [])
        XCTAssertEqual(try ids { $0.text = "100%_" }, ["e"]) // LIKE wildcards in the text are literal
        var q = LocalSearch(); q.sort = .size; q.ascending = false; q.category = .any; q.minSize = 1
        XCTAssertEqual(try s.search(q).map(\.id), ["a", "c", "b"])
        q = LocalSearch(); q.limit = 2; let p1 = try s.search(q); q.offset = 2; let p2 = try s.search(q)
        XCTAssertEqual(p1.count, 2); XCTAssertTrue(Set(p1.map(\.id)).isDisjoint(with: p2.map(\.id)))
        XCTAssertEqual(try s.counts(), .init(files: 4, folders: 1, bytes: 7_000_100, trashed: 1))
    }
    func testLargeMirrorStaysPaginatedAndFast() throws {
        let s = try store()
        try s.db.transaction { for chunk in stride(from: 0, to: 60_000, by: 2000) { try s.upsert((chunk..<chunk + 2000).map { item("i\($0)", "fichier \($0).dat", parent: "p\($0 % 300)", rev: Int64($0 + 1), size: Int64($0)) }) } }
        let t0 = Date()
        var q = LocalSearch(text: "fichier 599"); q.limit = 50
        XCTAssertEqual(try s.search(q).count, 50)
        XCTAssertEqual(try s.children(of: "p7", limit: 100).count, 100)
        XCTAssertEqual(try s.changes(since: 59_000, limit: 500).items.count, 500)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
    }
    func testResetMirrorTombstonesEverything() throws {
        let s = try store()
        try s.upsert([item("a", "a", parent: "root", rev: 1), item("b", "b", parent: "root", rev: 2)]); try s.setCursor(42)
        let anchor = s.seq
        try s.resetMirror()
        XCTAssertEqual(s.cursor, 0); XCTAssertNil(try s.item("a")); XCTAssertEqual(Set(try s.changes(since: anchor).deleted), ["a", "b"])
    }
}

final class SyncLogicTests: XCTestCase {
    func testClassify() {
        let base = item("f", "a.txt", parent: "p", rev: 1)
        XCTAssertEqual(ChangeDetector.classify(old: nil, new: base), .created)
        var n = base; n.name = "b.txt"; XCTAssertEqual(ChangeDetector.classify(old: base, new: n), .renamed)
        n = base; n.parentID = "q"; XCTAssertEqual(ChangeDetector.classify(old: base, new: n), .moved)
        n = base; n.versionID = "v2"; n.sha256 = "x"; XCTAssertEqual(ChangeDetector.classify(old: base, new: n), .contentChanged)
        n = base; n.trashedAt = Date(); XCTAssertEqual(ChangeDetector.classify(old: base, new: n), .trashed); XCTAssertEqual(ChangeDetector.classify(old: n, new: base), .restored)
        n = base; n.starred = true; XCTAssertEqual(ChangeDetector.classify(old: base, new: n), .metadata)
    }
    func testAdvisorAddsSlotsOnlyWhileTheyPay() {
        var a = ConcurrencyAdvisor()
        let net = NetworkStatus(online: true, expensive: false, constrained: false)
        XCTAssertEqual(a.allowed(network: net), 3)
        for t in [10.0, 10, 20, 20, 30, 30, 40, 40] { a.observe(throughput: t * 1e6, saturated: true) } // each extra slot brings more
        XCTAssertGreaterThan(a.allowed(network: net), 3)
        let high = a.limit
        for _ in 0..<6 { a.observe(throughput: 20e6, saturated: true) } // the last one made things worse
        XCTAssertLessThan(a.limit, high)
        a.observe(throughput: 500e6, saturated: false) // not saturated: no evidence, no change
        XCTAssertLessThan(a.limit, high)
        XCTAssertEqual(a.allowed(network: .init(online: true, expensive: false, constrained: true)), 1)
        XCTAssertLessThanOrEqual(a.allowed(network: .init(online: true, expensive: true, constrained: false)), 2)
        XCTAssertEqual(ConcurrencyAdvisor(manual: 5).allowed(network: .init(online: true, expensive: false, constrained: true)), 5)
    }
    func testThrottleHoldsTheRate() async throws {
        let t = Throttle(bytesPerSecond: 200_000)
        let t0 = ContinuousClock.now
        for _ in 0..<6 { try await t.consume(100_000) } // 600 kB at 200 kB/s, with one second of initial allowance
        let s = Double((ContinuousClock.now - t0).components.seconds) + Double((ContinuousClock.now - t0).components.attoseconds) / 1e18
        XCTAssertGreaterThan(s, 1.6); XCTAssertLessThan(s, 3.5)
        let free = Throttle(); let t1 = ContinuousClock.now
        try await free.consume(1 << 30)
        XCTAssertLessThan((ContinuousClock.now - t1).components.seconds, 1)
    }
    func testClientRefusesPlainHTTPAndCleansUserAgent() throws {
        XCTAssertThrowsError(try APIClient(baseURL: URL(string: "http://drive.spboucher.ai")!, tokens: MemoryTokenStore(), userAgent: "x"))
        XCTAssertNoThrow(try APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, tokens: MemoryTokenStore(), userAgent: "x"))
        let c = try APIClient(baseURL: URL(string: "https://drive.spboucher.ai")!, tokens: MemoryTokenStore(), userAgent: "SP Drive (Mac de l\u{2019}équipe)\n")
        XCTAssertEqual(c.userAgent, "SP Drive (Mac de lquipe)")
        XCTAssertThrowsError(try c.request("GET", "/folders/root")) { XCTAssertEqual($0 as? DriveError, .unauthenticated) } // no token: nothing leaves
        let r = try APIClient(baseURL: URL(string: "https://drive.spboucher.ai")!, tokens: MemoryTokenStore("abc"), userAgent: "x").request("GET", "/search", query: ["q": "a+b c&d", "kind": nil])
        XCTAssertEqual(r.url?.absoluteString, "https://drive.spboucher.ai/api/v1/search?q=a%2Bb%20c%26d")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer abc"); XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
    }
    func testErrorMapping() {
        XCTAssertTrue(DriveError.wrap(URLError(.notConnectedToInternet)).isTransient); XCTAssertEqual(DriveError.wrap(URLError(.cancelled)), .cancelled)
        XCTAssertTrue(DriveError.server(status: 503, code: "x", message: "", extra: [:]).isTransient); XCTAssertFalse(DriveError.server(status: 409, code: "name_conflict", message: "", extra: [:]).isTransient)
        XCTAssertFalse(DriveError.integrity("x").isTransient); XCTAssertFalse(DriveError.unauthenticated.isTransient)
    }
}
