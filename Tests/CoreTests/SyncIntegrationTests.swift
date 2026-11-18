// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Tests/CoreTests/SyncIntegrationTests.swift
// Description: Integration tests of the sync layer against the real local backend: incremental change feed, offline journal replayed after a "restart", persistent transfer queue, the sync loop through a server outage.
import Foundation
import XCTest
@testable import SPDriveCore
@testable import SPDriveSync

final class ChangeFeedTests: LiveCase {
    func testPullMirrorsRemoteChangesIncrementally() async throws {
        let s = try store(), d = ChangeDetector(api: api, store: s)
        _ = try await d.pull(pageSize: 3) // first sync, in small pages
        XCTAssertNotNil(s.rootID); XCTAssertEqual(try s.item(folder.id)?.name, folder.name)
        let head = try await api.syncCursor().head; XCTAssertEqual(s.cursor, head)
        let none = try await d.pull(); XCTAssertTrue(none.isEmpty)
        let dirty = try await d.hasRemoteChanges(); XCTAssertFalse(dirty)

        // "another device" works on the same account
        let other = try Backend.api()
        let sub = try await other.createFolder(parent: folder.id, name: "Venu d'ailleurs")
        let f = try await UploadEngine(api: other, store: nil, deviceName: "Autre").upload(file: try text("a.txt", "un"), to: .newFile(folderID: sub.id, name: "a.txt", onConflict: .fail)).item
        var changes = try await d.pull()
        XCTAssertEqual(changes.first { $0.id == sub.id }?.kind, .created); XCTAssertEqual(changes.first { $0.id == f.id }?.kind, .created)
        XCTAssertEqual(try s.children(of: sub.id).map(\.name), ["a.txt"])
        _ = try await other.updateFile(f.id, name: "b.txt")
        changes = try await d.pull(); XCTAssertEqual(changes.first { $0.id == f.id }?.kind, .renamed)
        _ = try await UploadEngine(api: other, store: nil, deviceName: "Autre").upload(file: try text("a2.txt", "deux"), to: .newVersion(fileID: f.id, folderID: sub.id, name: "b.txt", baseVersionID: f.versionID))
        changes = try await d.pull(); XCTAssertEqual(changes.first { $0.id == f.id }?.kind, .contentChanged); XCTAssertEqual(try s.item(f.id)?.versionSeq, 2)
        try await other.move(Selection(fileIds: [f.id]), to: folder.id)
        changes = try await d.pull(); XCTAssertEqual(changes.first { $0.id == f.id }?.kind, .moved); XCTAssertEqual(try s.item(f.id)?.parentID, folder.id)
        try await other.trash(Selection(fileIds: [f.id]))
        changes = try await d.pull(); XCTAssertEqual(changes.first { $0.id == f.id }?.kind, .trashed)
        XCTAssertTrue(try s.children(of: folder.id).allSatisfy { $0.id != f.id }); XCTAssertTrue(try s.trashRoots().contains { $0.id == f.id })
        try await other.restore(Selection(fileIds: [f.id]))
        changes = try await d.pull(); XCTAssertEqual(changes.first { $0.id == f.id }?.kind, .restored)
        try await other.trash(Selection(fileIds: [f.id])); try await other.purge(Selection(fileIds: [f.id]))
        let anchor = s.seq
        changes = try await d.pull(); XCTAssertEqual(changes.last { $0.id == f.id }?.kind, .deleted)
        XCTAssertNil(try s.item(f.id)); XCTAssertFalse(try s.changes(since: anchor).deleted.isEmpty) // a tombstone for the File Provider
    }
    func testInterruptedPullLosesNothing() async throws {
        let s = try store(), d = ChangeDetector(api: api, store: s)
        _ = try await d.pull()
        var made: Set<String> = []
        for i in 0..<9 { made.insert(try await api.createFolder(parent: folder.id, name: "d\(i)").id) }
        _ = try await d.pull(pageSize: 2, maxPages: 1) // the process stops after one page
        let mid = s.cursor
        let reopened = try store() // "restart"
        XCTAssertEqual(reopened.cursor, mid)
        _ = try await ChangeDetector(api: api, store: reopened).pull(pageSize: 2)
        XCTAssertTrue(made.isSubset(of: Set(try reopened.children(of: folder.id).map(\.id))))
        let head = try await api.syncCursor().head; XCTAssertEqual(reopened.cursor, head)
    }
    func testOwnWritesAreNotReportedAsRemoteChanges() async throws {
        let s = try store(), d = ChangeDetector(api: api, store: s)
        _ = try await d.pull()
        let made = try await api.createFolder(parent: folder.id, name: "local")
        try s.upsert([made]) // what the app does with the answer of its own request
        let changes = try await d.pull()
        XCTAssertNil(changes.first { $0.id == made.id })
    }
}

final class OfflineJournalTests: LiveCase {
    func testOfflineOperationsSurviveRestartAndReplayInOrder() async throws {
        var s: MetadataStore? = try store()
        _ = try await ChangeDetector(api: api, store: s!).pull()
        let keep = try await upload(try text("garde.txt", "contenu")), toss = try await upload(try text("jette.txt", "x")), ren = try await upload(try text("ancien nom.txt", "y"))
        _ = try await ChangeDetector(api: api, store: s!).pull()
        try Backend.serverDown()
        var up = false; defer { if !up { try? Backend.serverUp() } }
        // --- offline: everything below is decided without a server ---
        var j = OperationJournal(api: api, store: s!)
        let local = try j.createFolder(parent: folder.id, name: "Créé hors ligne")
        XCTAssertTrue(OperationJournal.isLocal(local.id))
        let nested = try j.createFolder(parent: local.id, name: "Sous-dossier")
        try j.move([try XCTUnwrap(s!.item(keep.id))], to: nested.id)
        try j.rename(try XCTUnwrap(s!.item(ren.id)), to: "nouveau nom.txt")
        try j.setStarred(try XCTUnwrap(s!.item(ren.id)), true)
        try j.trash([try XCTUnwrap(s!.item(toss.id))])
        // the mirror already shows the intent
        XCTAssertEqual(try s!.children(of: nested.id).map(\.id), [keep.id]); XCTAssertEqual(try s!.item(ren.id)?.name, "nouveau nom.txt")
        XCTAssertNotNil(try s!.item(toss.id)?.trashedAt); var inFolder = LocalSearch(text: "nouveau"); inFolder.folderID = folder.id // the account is shared with other runs: look in this test's folder
        XCTAssertEqual(try s!.search(inFolder).map(\.id), [ren.id])
        do { try j.rename(try XCTUnwrap(s!.item(keep.id)), to: "garde.txt"); try j.move([local], to: nested.id); XCTFail("a folder cannot go into itself") } catch { XCTAssertEqual((error as? DriveError)?.code, "move_into_self") }
        // a file added offline into the folder created offline
        let work = dir.appendingPathComponent("work")
        var q: TransferQueue? = TransferQueue(api: api, store: s!, workDirectory: work, deviceName: "Tests")
        let added = try text("ajouté hors ligne.txt", "ajouté sans réseau")
        let t = try await q!.enqueueUpload(file: added, parent: local.id)
        try FileManager.default.removeItem(at: added) // the original may disappear: the queue owns a staged copy
        let r = await j.run()
        XCTAssertTrue(r.blocked); XCTAssertEqual(r.done, 0); XCTAssertEqual(try j.pendingCount(), 6)
        // --- restart of the Mac: every object is dropped, the database is reopened ---
        q = nil; s = nil
        let s2 = try store()
        j = OperationJournal(api: api, store: s2)
        XCTAssertEqual(try j.pendingCount(), 6); XCTAssertEqual(try s2.item(ren.id)?.name, "nouveau nom.txt")
        let q2 = TransferQueue(api: api, store: s2, workDirectory: work, deviceName: "Tests")
        let pendingTransfer = await q2.get(t.id); XCTAssertEqual(pendingTransfer?.state, .queued)
        // --- back online ---
        try Backend.serverUp(); up = true
        let done = await j.run()
        XCTAssertEqual(done, .init(done: 6, failed: 0, blocked: false)); XCTAssertEqual(try j.pendingCount(), 0)
        let realFolder = j.resolve(local.id), realNested = j.resolve(nested.id)
        XCTAssertFalse(OperationJournal.isLocal(realFolder)); XCTAssertNil(try s2.item(local.id))
        await q2.start()
        try await waitUntil { await q2.get(t.id)?.state == .done }
        // the server now agrees with everything decided offline
        let top = try await api.listFolder(folder.id)
        XCTAssertEqual(top.folders.map(\.name), ["Créé hors ligne"]); XCTAssertEqual(top.folders.first?.id, realFolder)
        XCTAssertEqual(top.files.map(\.name), ["nouveau nom.txt"]); XCTAssertEqual(top.files.first?.starred, true)
        let inside = try await api.listFolder(realFolder)
        XCTAssertEqual(inside.folders.map(\.id), [realNested]); XCTAssertEqual(inside.files.map(\.name), ["ajouté hors ligne.txt"])
        let bytes = try await serverBytes(inside.files[0].id); XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "ajouté sans réseau")
        let deep = try await api.listFolder(realNested); XCTAssertEqual(deep.files.map(\.id), [keep.id])
        let tossed = try await api.item(toss.id, kind: .file); XCTAssertNotNil(tossed?.trashedAt) // in the trash, not destroyed
        await q2.stop()
        // and the mirror converges on the server's description
        _ = try await ChangeDetector(api: api, store: s2).pull()
        XCTAssertEqual(try s2.children(of: realFolder).map(\.name).sorted(), ["Sous-dossier", "ajouté hors ligne.txt"])
        XCTAssertEqual(try j.history().filter { $0.state == "done" }.count, 6)
    }
    func testRefusedOperationIsReportedAndMirrorRealigned() async throws {
        let s = try store()
        let a = try await upload(try text("a.txt", "a"))
        _ = try await ChangeDetector(api: api, store: s).pull()
        let j = OperationJournal(api: api, store: s)
        try j.rename(try XCTUnwrap(s.item(a.id)), to: "pris.txt") // free as far as this device knows…
        _ = try await upload(try text("pris.txt", "b"))            // …but another device took the name meanwhile
        let other = try await upload(try text("c.txt", "c"))
        try s.upsert([other]); try j.setStarred(other, true)      // a later operation must still go through
        let r = await j.run()
        XCTAssertEqual(r, .init(done: 1, failed: 1, blocked: false))
        XCTAssertEqual(try s.item(a.id)?.name, "a.txt") // the optimistic name is withdrawn
        let failed = try j.history().first { $0.state == "failed" }; XCTAssertEqual(failed?.kind, .rename); XCTAssertNotNil(failed?.error)
        let server = try await api.item(a.id, kind: .file); XCTAssertEqual(server?.name, "a.txt")
        let starred = try await api.item(other.id, kind: .file); XCTAssertEqual(starred?.starred, true)
    }
}

extension XCTestCase {
    func waitUntil(timeout: Double = 30, _ what: String = "condition", file: StaticString = #filePath, line: UInt = #line, _ cond: @escaping @Sendable () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if await cond() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTFail("timeout: \(what)", file: file, line: line); throw DriveError.local("timeout")
    }
}

final class TransferQueueTests: LiveCase {
    func testQueueRunsPausesResumesCancelsAndVerifies() async throws {
        let s = try store(), work = dir.appendingPathComponent("work")
        let q = TransferQueue(api: api, store: s, workDirectory: work, deviceName: "Tests")
        let events = Box<[String]>([])
        let watcher = Task { for await e in await q.events() { if case .finished(let t, _) = e { events.update { $0.append(t.name) } } } }
        defer { watcher.cancel() }
        await q.setLimits(uploadBytesPerSecond: 3 * 1024 * 1024, downloadBytesPerSecond: 0)
        let big = try randomFile("gros.bin", bytes: 12 * 1024 * 1024), big2 = try randomFile("annulé.bin", bytes: 12 * 1024 * 1024)
        var ids: [String] = []
        for i in 0..<5 { ids.append(try await q.enqueueUpload(file: try text("petit\(i).txt", "contenu \(i)"), parent: folder.id).id) }
        let slow = try await q.enqueueUpload(file: big.url, parent: folder.id), doomed = try await q.enqueueUpload(file: big2.url, parent: folder.id)
        await q.start()
        try await waitUntil { (await q.get(slow.id)?.done ?? 0) > 1024 * 1024 }
        await q.pause(slow.id); await q.cancel(doomed.id)
        let paused = await q.get(slow.id); XCTAssertEqual(paused?.state, .paused)
        for id in ids { try await waitUntil { await q.get(id)?.state == .done } }
        try await Task.sleep(nanoseconds: 600_000_000)
        let still = await q.get(slow.id); XCTAssertEqual(still?.state, .paused) // a paused transfer stays paused
        var listed = try await api.listFolder(folder.id); XCTAssertEqual(listed.files.count, 5)
        await q.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
        await q.resume(slow.id)
        try await waitUntil { await q.get(slow.id)?.state == .done }
        listed = try await api.listFolder(folder.id)
        XCTAssertEqual(listed.files.first { $0.name == "gros.bin" }?.sha256, big.sha)
        XCTAssertNil(listed.files.first { $0.name == "annulé.bin" }) // cancelled: nothing appeared on the server
        let cancelled = await q.get(doomed.id); XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.localPath)); XCTAssertFalse(FileManager.default.fileExists(atPath: slow.localPath)) // staging cleaned
        XCTAssertEqual(try s.item(listed.files.first { $0.name == "gros.bin" }!.id)?.sha256, big.sha) // the mirror learnt the new file
        // downloads through the queue, verified
        let dest = dir.appendingPathComponent("out/gros.bin")
        let dl = try await q.enqueueDownload(listed.files.first { $0.name == "gros.bin" }!, to: dest)
        try await waitUntil { await q.get(dl.id)?.state == .done }
        XCTAssertEqual(try Hashing.sha256Hex(of: dest).sha256, big.sha)
        XCTAssertTrue(events.value.contains("gros.bin")); XCTAssertEqual(events.value.filter { $0.hasPrefix("petit") }.count, 5)
        let sum = await q.summary(); XCTAssertEqual(sum.running + sum.queued + sum.paused + sum.failed, 0)
        await q.clearFinished()
        let left = await q.list(); XCTAssertTrue(left.isEmpty)
        await q.stop()
    }
    func testQueueResumesAfterProcessDeathAndServerOutage() async throws {
        let work = dir.appendingPathComponent("work")
        var s: MetadataStore? = try store()
        let big = try randomFile("reprise.bin", bytes: 14 * 1024 * 1024)
        let t: Transfer
        do {
            let q = TransferQueue(api: api, store: s!, workDirectory: work, deviceName: "Tests")
            await q.setLimits(uploadBytesPerSecond: 3 * 1024 * 1024, downloadBytesPerSecond: 0)
            let queued = try await q.enqueueUpload(file: big.url, parent: folder.id); t = queued
            await q.start()
            try await waitUntil { (await q.get(queued.id)?.done ?? 0) > 2 * 1024 * 1024 }
            await q.stop()
        }
        s = nil // the app is killed in the middle
        try Backend.serverDown()
        var up = false; defer { if !up { try? Backend.serverUp() } }
        let s2 = try store()
        try s2.db.run("UPDATE transfers SET state = 'running'") // what a crash leaves behind: a row still marked running
        let q2 = TransferQueue(api: api, store: s2, workDirectory: work, deviceName: "Tests")
        await q2.start() // server down: the transfer waits, it is not declared failed
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let waiting = await q2.get(t.id); XCTAssertEqual(waiting?.state, .queued); XCTAssertNotNil(waiting?.error)
        try Backend.serverUp(); up = true
        await q2.kick()
        try await waitUntil(timeout: 60) { await q2.get(t.id)?.state == .done }
        let listed = try await api.listFolder(folder.id)
        XCTAssertEqual(listed.files.map(\.name), ["reprise.bin"]); XCTAssertEqual(listed.files.first?.sha256, big.sha) // once, intact
        await q2.stop()
    }
    func testReplacingAStaleFileThroughTheQueueRaisesAConflict() async throws {
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Mac de test")
        let base = try await upload(try text("plan.txt", "base"))
        try s.upsert([base])
        _ = try await UploadEngine(api: api, store: nil, deviceName: "Autre").upload(file: try text("x.txt", "autre appareil"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "plan.txt", baseVersionID: base.versionID))
        let got = Box<SyncConflict?>(nil)
        let watcher = Task { for await e in await q.events() { if case .conflict(let c) = e { got.value = c } } }
        defer { watcher.cancel() }
        // the queue sends a new version derived from the version this device knew
        let t = try await q.enqueueUpload(file: try text("y.txt", "ce Mac"), parent: folder.id, replacing: base)
        try s.db.run("UPDATE transfers SET base_version_id = ? WHERE id = ?", [.text(base.versionID!), .text(t.id)])
        await q.start()
        try await waitUntil { await q.get(t.id)?.state == .done }
        try await waitUntil { got.value != nil }
        XCTAssertEqual(got.value?.itemID, base.id); XCTAssertTrue(got.value?.copyName.contains("conflit Mac de test") ?? false)
        let files = try await api.listFolder(folder.id).files; XCTAssertEqual(files.count, 2)
        let original = try await serverBytes(base.id); XCTAssertEqual(String(decoding: original, as: UTF8.self), "autre appareil")
        XCTAssertEqual(try ConflictResolver(api: api, store: s).openCount(), 1)
        await q.stop()
    }
}

final class SyncEngineTests: LiveCase {
    func testLoopSyncsGoesOfflineAndCatchesUp() async throws {
        let s = try store()
        let engine = SyncEngine(api: api, store: s, network: NetworkMonitor(), workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        let remote = Box<[DetectedChange]>([])
        await engine.setRemoteChangeHandler { c in remote.update { $0.append(contentsOf: c) } }
        let phases = Box<[SyncPhase]>([])
        let watcher = Task { for await st in await engine.statusStream() { phases.update { if $0.last != st.phase { $0.append(st.phase) } } } }
        defer { watcher.cancel() }
        await engine.start()
        let folderID = folder.id
        try await waitUntil { s.rootID != nil && (try? s.item(folderID)) != nil }
        try await waitUntil { await engine.currentStatus().phase == .idle }
        // a remote change is picked up after a poke
        let made = try await api.createFolder(parent: folder.id, name: "distant")
        await engine.poke()
        try await waitUntil { (try? s.item(made.id)) != nil }
        XCTAssertTrue(remote.value.contains { $0.id == made.id && $0.kind == .created })
        // server down: local decisions are journaled, the engine reports offline and keeps them
        try Backend.serverDown()
        var up = false; defer { if !up { try? Backend.serverUp() } }
        let local = try await engine.journal.createFolder(parent: folder.id, name: "pendant la panne")
        await engine.poke()
        try await waitUntil { await engine.currentStatus().phase == .offline }
        let st = await engine.currentStatus(); XCTAssertEqual(st.pendingOperations, 1); XCTAssertNotNil(st.lastError)
        try Backend.serverUp(); up = true
        await engine.poke()
        try await waitUntil { await engine.currentStatus().pendingOperations == 0 }
        try await waitUntil { await engine.currentStatus().phase == .idle }
        let names = try await api.listFolder(folder.id).folders.map(\.name).sorted(); XCTAssertEqual(names, ["distant", "pendant la panne"])
        XCTAssertNil(try s.item(local.id)); let last = await engine.currentStatus().lastSync; XCTAssertNotNil(last)
        // paused: nothing is pulled until resumed
        await engine.pause()
        let quiet = try await api.createFolder(parent: folder.id, name: "pendant la pause")
        await engine.poke(); try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(try s.item(quiet.id)); let ph = await engine.currentStatus().phase; XCTAssertEqual(ph, .paused)
        await engine.resume()
        try await waitUntil { (try? s.item(quiet.id)) != nil }
        XCTAssertTrue(phases.value.contains(.syncing)); XCTAssertTrue(phases.value.contains(.offline)); XCTAssertTrue(phases.value.contains(.paused))
        await engine.stop()
    }
    func testRevokedSessionStopsTheEngineWithoutLosingTheJournal() async throws {
        let token = try Backend.script("token", "Session à révoquer")
        let dev = try Backend.api(token: token)
        let s = try store()
        let engine = SyncEngine(api: dev, store: s, network: NetworkMonitor(), workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        await engine.start()
        try await waitUntil { await engine.currentStatus().phase == .idle }
        let id = try await api.sessions().first { $0.deviceName == "Session à révoquer" }!.id
        try await api.revokeSession(id) // the owner revokes this device from another one
        _ = try await engine.journal.createFolder(parent: folder.id, name: "après révocation")
        await engine.poke()
        try await waitUntil { await engine.currentStatus().phase == .needsLogin }
        let pending = await engine.currentStatus().pendingOperations; XCTAssertEqual(pending, 1) // kept for after the next sign-in
        let names = try await api.listFolder(folder.id).folders.map(\.name); XCTAssertFalse(names.contains("après révocation"))
        await engine.stop()
    }
}
