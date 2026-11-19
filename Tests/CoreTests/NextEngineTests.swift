// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Tests/CoreTests/NextEngineTests.swift
// Description: Tests of the 2.0 sync engine policies: retry back-off with jitter, power awareness, error-rate concurrency, priorities and pre-emption, bandwidth cap, global pause, automatic retries across an outage, crash-safe resume after a real SIGKILL, the event listener with its polling fallback, and "keep mine as a new version". Integration tests run against the real local backend.
import Foundation
import XCTest
@testable import SPDriveCore
@testable import SPDriveSync

final class PolicyTests: XCTestCase {
    func testRetryPolicyGrowsIsCappedAndStaysInsideItsJitterBand() {
        let p = RetryPolicy(base: 2, cap: 600, jitter: 0.25)
        XCTAssertEqual((1...6).map { p.nominal(attempt: $0) }, [2, 4, 8, 16, 32, 64])
        XCTAssertEqual(p.nominal(attempt: 30), 600); XCTAssertEqual(p.nominal(attempt: 0), 2)
        XCTAssertEqual(p.delay(attempt: 3, unit: 0), 6, accuracy: 1e-9); XCTAssertEqual(p.delay(attempt: 3, unit: 1), 10, accuracy: 1e-9); XCTAssertEqual(p.delay(attempt: 3, unit: 0.5), 8, accuracy: 1e-9)
        var seen = Set<Int>()
        for _ in 0..<400 { let d = p.delay(attempt: 4); XCTAssertGreaterThanOrEqual(d, 12); XCTAssertLessThanOrEqual(d, 20); seen.insert(Int(d * 10)) }
        XCTAssertGreaterThan(seen.count, 20, "delays must actually be spread") // jitter is real, not a constant
        XCTAssertLessThanOrEqual(p.delay(attempt: 50, unit: 1), 600)
        XCTAssertEqual(RetryPolicy.reconnect.nominal(attempt: 1), 1); XCTAssertEqual(RetryPolicy.reconnect.nominal(attempt: 20), 60)
    }
    func testPowerStateShapesConcurrencyAndDefersBackground() {
        let net = NetworkStatus(online: true, expensive: false, constrained: false)
        let a = ConcurrencyAdvisor()
        XCTAssertEqual(a.allowed(network: net, power: .unconstrained), 3)
        XCTAssertEqual(a.allowed(network: net, power: PowerState(onBattery: true, lowPowerMode: false, level: 0.8)), 3) // battery alone changes nothing
        XCTAssertEqual(a.allowed(network: net, power: PowerState(onBattery: true, lowPowerMode: false, level: 0.18)), 2)
        XCTAssertEqual(a.allowed(network: net, power: PowerState(onBattery: true, lowPowerMode: false, level: 0.07)), 1)
        XCTAssertEqual(a.allowed(network: net, power: PowerState(onBattery: false, lowPowerMode: true, level: 1)), 1)
        XCTAssertEqual(a.allowed(network: net, power: PowerState(onBattery: false, lowPowerMode: false, level: 0.05)), 3) // plugged in: the level does not matter
        XCTAssertTrue(PowerState(lowPowerMode: true).defersBackground); XCTAssertTrue(PowerState(onBattery: true, level: 0.1).defersBackground)
        XCTAssertFalse(PowerState(onBattery: true, level: 0.5).defersBackground)
        XCTAssertEqual(ConcurrencyAdvisor(manual: 4).allowed(network: net, power: PowerState(lowPowerMode: true)), 4) // an explicit choice of the person stands
        let real = SystemPowerSource().state // whatever this Mac says, it must be coherent
        if let l = real.level { XCTAssertTrue((0...1).contains(l)) }
        XCTAssertEqual(real.lowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    func testAdvisorGivesSlotsBackWhenTransfersKeepFailing() {
        var a = ConcurrencyAdvisor()
        let net = NetworkStatus(online: true, expensive: false, constrained: false)
        for t in [10.0, 10, 20, 20, 30, 30, 40, 40, 50, 50] { a.observe(throughput: t * 1e6, saturated: true) }
        let grown = a.limit; XCTAssertGreaterThanOrEqual(grown, 5)
        a.record(success: true); a.record(success: false); a.record(success: false)
        XCTAssertEqual(a.limit, grown, "two failures are not a trend")
        a.record(success: false)
        XCTAssertEqual(a.limit, grown - 1); XCTAssertEqual(a.errorRate, 0) // window restarted after the decision
        for _ in 0..<40 { a.record(success: false) }
        XCTAssertEqual(a.limit, 1); XCTAssertEqual(a.allowed(network: net), 1) // never below one
        let before = a.limit
        a.observe(throughput: 90e6, saturated: true); a.observe(throughput: 90e6, saturated: true)
        XCTAssertEqual(a.limit, before, "growth waits for calm windows after errors")
        for t in [10.0, 10, 10, 20, 20, 30, 30] { a.observe(throughput: t * 1e6, saturated: true) }
        XCTAssertGreaterThan(a.limit, before) // and comes back when the link behaves
        var m = ConcurrencyAdvisor(manual: 5); for _ in 0..<20 { m.record(success: false) }
        XCTAssertEqual(m.allowed(network: net), 5)
    }
    func testListing1000ItemsFromTheMirrorIsFast() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spdrive-perf-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try MetadataStore(url: dir.appendingPathComponent("m.sqlite"))
        try s.upsert([item("root", "", parent: nil, kind: .folder, rev: 1), item("d", "Mille", parent: "root", kind: .folder, rev: 2)])
        try s.upsert((0..<1000).map { item("f\($0)", "Document \($0).pdf", parent: "d", rev: Int64($0 + 3), size: 1000) })
        var best = Double.infinity
        for _ in 0..<10 { let t = Date(); let rows = try s.children(of: "d"); best = min(best, Date().timeIntervalSince(t)); XCTAssertEqual(rows.count, 1000) }
        print(String(format: "MEASURE mirror-list-1000: %.2f ms (best of 10)", best * 1000))
        XCTAssertLessThan(best, 0.1)
    }
}

/// A scripted event source: each `connect()` hands out the next prepared connection.
final class FakeEventSource: RemoteEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var live: AsyncThrowingStream<RemoteEvent, Error>.Continuation?
    private(set) var connections = 0
    var refuse = false
    func connect() -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { c in
            lock.withLock { connections += 1 }
            if refuse { c.finish(throwing: DriveError.offline("refused")); return }
            lock.withLock { live = c }
        }
    }
    func send(_ e: RemoteEvent) { _ = lock.withLock { live }?.yield(e) }
    func drop() { let c = lock.withLock { let c = live; live = nil; return c }; c?.finish(throwing: DriveError.offline("dropped")) }
    var count: Int { lock.withLock { connections } }
}

final class EventListenerTests: XCTestCase {
    func testPollingOnlyReportsHeadMovesOnce() async throws {
        let head = Box<Int64>(5), seen = Box<[Int64]>([])
        let l = EventListener(source: nil, pollInterval: 0.05, head: { head.value }, onChange: { h in seen.update { $0.append(h) } })
        await l.start()
        try await waitUntil { seen.value == [5] }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(seen.value, [5], "an unchanged head is not news")
        head.value = 9
        try await waitUntil { seen.value == [5, 9] }
        let ch = await l.channel; XCTAssertEqual(ch, .polling)
        await l.stop()
        head.value = 12; try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(seen.value, [5, 9]); let off = await l.channel; XCTAssertEqual(off, .off)
    }
    func testStreamTakesOverThenPollingCoversADropAndReconnectBacksOff() async throws {
        let src = FakeEventSource(), head = Box<Int64>(1), seen = Box<[Int64]>([]), notes = Box<[String]>([])
        let l = EventListener(source: src, pollInterval: 0.05, retry: RetryPolicy(base: 0.3, cap: 1, jitter: 0.2), head: { head.value },
                              onNotify: { k in notes.update { $0.append(k) } }, onChange: { h in seen.update { $0.append(h) } })
        await l.start()
        try await waitUntil { src.count == 1 }
        src.send(.hello(head: 1))
        try await waitUntil { await l.channel == .stream }
        try await waitUntil { seen.value == [1] }
        let pollsWhenLive = await l.polls
        src.send(.change(head: 2)); src.send(.change(head: 2)); src.send(.notify(kind: "request.submission")); src.send(.change(head: 3))
        try await waitUntil { seen.value == [1, 2, 3] }
        XCTAssertEqual(notes.value, ["request.submission"])
        try await Task.sleep(nanoseconds: 250_000_000)
        let pollsStill = await l.polls; XCTAssertEqual(pollsStill, pollsWhenLive, "no polling while the stream is live")
        // the stream drops: polling takes over at once, and reports what the stream can no longer say
        head.value = 3 // what the server really has at that point
        src.refuse = true; src.drop()
        try await waitUntil { await l.channel == .polling }
        head.value = 7
        try await waitUntil { seen.value == [1, 2, 3, 7] }
        // reconnection attempts are spaced by the back-off (0.3 s, 0.6 s, 1 s…): far fewer than one per poll tick
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let attempts = src.count; XCTAssertGreaterThanOrEqual(attempts, 3); XCTAssertLessThanOrEqual(attempts, 5)
        // the server is back: the stream is live again and polling stops
        src.refuse = false
        try await waitUntil(timeout: 5) { src.count > attempts }
        src.send(.hello(head: 8))
        try await waitUntil { await l.channel == .stream }
        try await waitUntil { seen.value.last == 8 }
        let reconnects = await l.reconnects; XCTAssertGreaterThanOrEqual(reconnects, 2)
        await l.stop()
    }
}

final class EngineEventTests: LiveCase {
    func testEnginePicksUpRemoteChangesFromThePollingFallbackWithoutBeingPoked() async throws {
        let s = try store()
        let engine = SyncEngine(api: api, store: s, network: NetworkMonitor(), workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests", eventPollInterval: 1)
        await engine.start()
        let fid = folder.id
        try await waitUntil { (try? s.item(fid)) != nil }
        try await waitUntil { let st = await engine.currentStatus(); return st.phase == .idle && st.events == .polling }
        try await Task.sleep(nanoseconds: 1_500_000_000) // let the first poll settle
        let made = try await api.createFolder(parent: folder.id, name: "vu par le sondage")
        let t0 = Date()
        try await waitUntil(timeout: 6, "the engine's own loop rests at least 10 s: only the listener can bring this in time") { (try? s.item(made.id)) != nil }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
        // paused: the listener is off; resumed: it is back
        await engine.pause()
        try await waitUntil { await engine.currentStatus().events == .off }
        await engine.resume()
        try await waitUntil { await engine.currentStatus().events == .polling }
        await engine.stop()
    }
    func testEngineFollowsAPluggedInEventStream() async throws {
        let s = try store(), src = FakeEventSource()
        let engine = SyncEngine(api: api, store: s, network: NetworkMonitor(), workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests", eventPollInterval: 600)
        await engine.setEventSource(src)
        await engine.start()
        let fid = folder.id
        try await waitUntil { (try? s.item(fid)) != nil }
        try await waitUntil { src.count >= 1 }
        src.send(.hello(head: try await api.syncCursor().head))
        try await waitUntil { await engine.currentStatus().events == .stream }
        try await waitUntil { await engine.currentStatus().phase == .idle }
        let made = try await api.createFolder(parent: folder.id, name: "annoncé par le flux")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(try s.item(made.id)) // nobody said anything yet (polling is 10 minutes away)
        src.send(.change(head: try await api.syncCursor().head))
        try await waitUntil(timeout: 5) { (try? s.item(made.id)) != nil }
        await engine.stop()
    }
}

/// The real stream of the 2.0 server (SSE through SPDriveNext) plugged into the engine.
final class LiveEventStreamTests: LiveCase {
    func testRealStreamBringsARemoteChangeAtOnceAndPollingCoversAKilledStream() async throws {
        let s = try store()
        let engine = SyncEngine(api: api, store: s, network: NetworkMonitor(), workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests", eventPollInterval: 2)
        await engine.setEventSource(NextEventSource(api: api, idleTimeout: 30)) // above the server's 25 s ping, so a healthy stream is never cut
        await engine.start()
        let fid = folder.id
        try await waitUntil { (try? s.item(fid)) != nil }
        try await waitUntil(timeout: 10, "stream live") { await engine.currentStatus().events == .stream }
        try await waitUntil { await engine.currentStatus().phase == .idle }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        // another client of the account changes something: the Mac learns of it without being poked and well before any poll
        let other = try Backend.api()
        var t0 = Date()
        let made = try await other.createFolder(parent: folder.id, name: "poussé par le serveur")
        try await waitUntil(timeout: 4, "pushed change mirrored") { (try? s.item(made.id)) != nil }
        let pushed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(pushed, 1.9, "faster than the 2 s poll of this test (and than the 30 s poll of the app): it came from the stream")
        // the server goes away. A server stopped with SIGTERM may leave the open stream hanging without closing it: only the
        // silence (no ping) gives it away. Within the idle timeout the listener declares the stream dead and polls.
        try Backend.serverDown()
        var up = false; defer { if !up { try? Backend.serverUp() } }
        let tDown = Date()
        try await waitUntil(timeout: 45, "fallback to polling") { await engine.currentStatus().events == .polling }
        let noticed = Date().timeIntervalSince(tDown)
        try Backend.serverUp(); up = true
        // while the stream is still reconnecting (back-off), a change is found by the poll
        t0 = Date()
        let later = try await other.createFolder(parent: folder.id, name: "vu après la coupure")
        try await waitUntil(timeout: 15, "change after the outage mirrored") { (try? s.item(later.id)) != nil }
        // and the stream comes back by itself
        try await waitUntil(timeout: 70, "stream live again") { await engine.currentStatus().events == .stream }
        let again = try await other.createFolder(parent: folder.id, name: "poussé de nouveau")
        try await waitUntil(timeout: 4) { (try? s.item(again.id)) != nil }
        print(String(format: "MEASURE sse: pushed change mirrored in %.2f s; dead stream noticed after %.1f s", pushed, noticed))
        await engine.stop()
    }
}

final class QueuePolicyTests: LiveCase {
    private func finishOrder(_ q: TransferQueue) -> (Box<[String]>, Task<Void, Never>) {
        let order = Box<[String]>([])
        let w = Task { for await e in await q.events() { if case .finished(let t, _) = e { order.update { $0.append(t.name) } } } }
        return (order, w)
    }
    func testUserInitiatedTransfersPreemptAndPrecedeBackgroundOnes() async throws {
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        let (order, w) = finishOrder(q); defer { w.cancel() }
        await q.setManualConcurrency(1)
        await q.setLimits(uploadBytesPerSecond: 1024 * 1024, downloadBytesPerSecond: 0)
        var shas: [String: String] = [:]
        for i in 1...3 { let f = try randomFile("fond\(i).bin", bytes: 2 * 1024 * 1024 + i); shas["fond\(i).bin"] = f.sha; _ = try await q.enqueueUpload(file: f.url, parent: folder.id, priority: TransferPriority.background) }
        await q.start()
        try await waitUntil { await q.list().contains { $0.name == "fond1.bin" && $0.state == .running && $0.done > 0 } }
        let user = try randomFile("demandé.bin", bytes: 700 * 1024); shas["demandé.bin"] = user.sha
        let u = try await q.enqueueUpload(file: user.url, parent: folder.id, priority: TransferPriority.userInitiated)
        // the running background transfer is put back in the queue (not failed, progress kept) and the user's goes first
        try await waitUntil { await q.get(u.id)?.state == .running }
        let stopped = await q.list().first { $0.name == "fond1.bin" }; XCTAssertEqual(stopped?.state, .queued); XCTAssertNil(stopped?.error)
        try await waitUntil(timeout: 60) { order.value.count == 4 }
        XCTAssertEqual(order.value.first, "demandé.bin")
        // "send this one first" on a queued transfer
        let files = try await api.listFolder(folder.id).files
        XCTAssertEqual(files.count, 4); for f in files { XCTAssertEqual(f.sha256, shas[f.name], f.name) } // pre-emption lost and duplicated nothing
        await q.stop()
    }
    func testSendFirstReordersTheQueue() async throws {
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        let (order, w) = finishOrder(q); defer { w.cancel() }
        await q.setManualConcurrency(1)
        var ids: [String] = []
        for i in 1...4 { ids.append(try await q.enqueueUpload(file: try text("f\(i).txt", "contenu \(i)"), parent: folder.id).id) }
        await q.setPriority(ids[3], TransferPriority.urgent)
        await q.start()
        try await waitUntil { order.value.count == 4 }
        XCTAssertEqual(order.value, ["f4.txt", "f1.txt", "f2.txt", "f3.txt"])
        await q.stop()
    }
    func testLowPowerModeRunsOnlyWhatThePersonAskedForOneAtATime() async throws {
        let power = FixedPowerSource(PowerState(onBattery: true, lowPowerMode: true, level: 0.5))
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests", power: power)
        let bg = try await q.enqueueUpload(file: try text("fond.txt", "arrière-plan"), parent: folder.id, priority: TransferPriority.background)
        let u1 = try await q.enqueueUpload(file: try text("a.txt", "demandé a"), parent: folder.id, priority: TransferPriority.userInitiated)
        let u2 = try await q.enqueueUpload(file: try text("b.txt", "demandé b"), parent: folder.id, priority: TransferPriority.userInitiated)
        await q.start()
        let pol = await q.policy(); XCTAssertEqual(pol.concurrency, 1); XCTAssertTrue(pol.deferringBackground)
        try await waitUntil { let a = await q.get(u1.id)?.state, b = await q.get(u2.id)?.state; return a == .done && b == .done }
        try await Task.sleep(nanoseconds: 2_500_000_000) // more than one queue tick
        let waiting = await q.get(bg.id); XCTAssertEqual(waiting?.state, .queued); XCTAssertNil(waiting?.error) // deferred, not failed
        var names = try await api.listFolder(folder.id).files.map(\.name).sorted(); XCTAssertEqual(names, ["a.txt", "b.txt"])
        // the person turns the power policy off for this queue: the deferred transfer runs
        await q.setPowerAware(false)
        try await waitUntil { await q.get(bg.id)?.state == .done }
        await q.setPowerAware(true)
        // back on mains: nothing is held any more
        let bg2 = try await q.enqueueUpload(file: try text("fond2.txt", "arrière-plan 2"), parent: folder.id, priority: TransferPriority.background)
        try await Task.sleep(nanoseconds: 600_000_000)
        let held = await q.get(bg2.id); XCTAssertEqual(held?.state, .queued)
        power.state = .unconstrained
        try await waitUntil(timeout: 10) { await q.get(bg2.id)?.state == .done } // picked up at the next tick, without anyone asking
        names = try await api.listFolder(folder.id).files.map(\.name).sorted(); XCTAssertEqual(names, ["a.txt", "b.txt", "fond.txt", "fond2.txt"])
        await q.stop()
    }
    func testBandwidthCapHoldsARealUploadAndDownload() async throws {
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        let f = try randomFile("plafonné.bin", bytes: 4 * 1024 * 1024)
        await q.setLimits(uploadBytesPerSecond: 1024 * 1024, downloadBytesPerSecond: 1024 * 1024)
        await q.start()
        var t0 = Date()
        let up = try await q.enqueueUpload(file: f.url, parent: folder.id)
        try await waitUntil(timeout: 30) { await q.get(up.id)?.state == .done }
        let upSeconds = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(upSeconds, 2.6, "4 MiB at 1 MiB/s cannot take less than ~3 s (one second of burst allowed)"); XCTAssertLessThan(upSeconds, 9)
        let item = try await api.listFolder(folder.id).files.first!
        XCTAssertEqual(item.sha256, f.sha)
        // downloads are paced on the delivery of the bytes to the engine: what the loader buffered does not escape the cap
        let g = try randomFile("retour-source.bin", bytes: 6 * 1024 * 1024)
        let big = try await upload(g.url)
        t0 = Date()
        let dest = dir.appendingPathComponent("retour.bin")
        let down = try await q.enqueueDownload(big, to: dest)
        try await waitUntil(timeout: 30) { await q.get(down.id)?.state == .done }
        let downSeconds = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(downSeconds, 4.5, "6 MiB at 1 MiB/s, minus one second of burst"); XCTAssertEqual(try Hashing.sha256Hex(of: dest).sha256, g.sha)
        // cap lifted: the same upload is several times faster
        await q.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
        t0 = Date()
        let free = try await q.enqueueUpload(file: f.url, parent: folder.id, name: "libre.bin")
        try await waitUntil(timeout: 30) { await q.get(free.id)?.state == .done }
        XCTAssertLessThan(Date().timeIntervalSince(t0), upSeconds / 2)
        print(String(format: "MEASURE cap 1 MiB/s: upload 4 MiB in %.2f s, download 6 MiB in %.2f s; uncapped upload %.2f s", upSeconds, downSeconds, Date().timeIntervalSince(t0)))
        await q.stop()
    }
    func testGlobalPauseFreezesTheServerSideOffsetAndResumeFinishes() async throws {
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        let f = try randomFile("pause.bin", bytes: 8 * 1024 * 1024)
        await q.setLimits(uploadBytesPerSecond: 2 * 1024 * 1024, downloadBytesPerSecond: 0)
        let t = try await q.enqueueUpload(file: f.url, parent: folder.id)
        await q.start()
        try await waitUntil { (await q.get(t.id)?.done ?? 0) > 1024 * 1024 }
        await q.pauseAll()
        let session = try XCTUnwrap(try s.db.query("SELECT upload_id FROM upload_sessions").first?["upload_id"]?.text)
        try await Task.sleep(nanoseconds: 700_000_000) // a block in flight may still land
        let a = try await api.uploadStatus(session).received
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let b = try await api.uploadStatus(session).received
        XCTAssertEqual(a, b, "nothing travels while paused"); XCTAssertGreaterThan(a, 0); XCTAssertLessThan(a, Int64(8 * 1024 * 1024))
        let st = await q.get(t.id); XCTAssertEqual(st?.state, .queued); let paused = await q.isPaused; XCTAssertTrue(paused)
        let late = try await q.enqueueUpload(file: try text("pendant.txt", "ajouté pendant la pause"), parent: folder.id)
        try await Task.sleep(nanoseconds: 500_000_000)
        let lateState = await q.get(late.id)?.state; XCTAssertEqual(lateState, .queued) // nothing starts either
        await q.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
        await q.resumeAll()
        try await waitUntil(timeout: 30) { let a = await q.get(t.id)?.state, b = await q.get(late.id)?.state; return a == .done && b == .done }
        let done = try await api.uploadStatus(session); XCTAssertEqual(done.status, "done") // the same server session was continued
        let sha = try await api.listFolder(folder.id).files.first { $0.name == "pause.bin" }?.sha256; XCTAssertEqual(sha, f.sha)
        await q.stop()
    }
    func testOutageRetriesBackOffWithJitterGiveSlotsBackAndRecoverAlone() async throws {
        let s = try store(), q = TransferQueue(api: api, store: s, workDirectory: dir.appendingPathComponent("work"), deviceName: "Tests")
        await q.setRetryPolicy(RetryPolicy(base: 1, cap: 4, jitter: 0.5))
        var ids: [String] = []
        for i in 1...4 { ids.append(try await q.enqueueUpload(file: try text("r\(i).txt", "retry \(i)"), parent: folder.id).id) }
        try Backend.serverDown()
        var up = false; defer { if !up { try? Backend.serverUp() } }
        await q.start()
        // every transfer fails for a transient reason: none is declared failed, each gets a later next try, delays differ (jitter)
        try await waitUntil(timeout: 30) { ((try? s.db.query("SELECT COUNT(*) AS n FROM transfers WHERE attempts >= 2 AND state = 'queued'").first?["n"]?.int) ?? 0) == 4 }
        let rows = try s.db.query("SELECT attempts, updated_at, error, state FROM transfers")
        let now = Date().timeIntervalSince1970
        var waits = Set<Int>()
        for r in rows {
            XCTAssertEqual(r["state"]?.text, "queued"); XCTAssertNotNil(r["error"]?.text)
            let attempts = Int(r["attempts"]?.int ?? 0), next = (r["updated_at"]?.double ?? 0) - now
            XCTAssertLessThanOrEqual(next, RetryPolicy(base: 1, cap: 4, jitter: 0.5).nominal(attempt: attempts) * 1.5 + 0.05) // never beyond the band
            waits.insert(Int((r["updated_at"]?.double ?? 0) * 1000))
        }
        XCTAssertGreaterThan(waits.count, 1, "retries must not be synchronised")
        let pol = await q.policy()
        XCTAssertLessThan(pol.measuredLimit, 3, "repeated failures give slots back"); XCTAssertEqual(pol.concurrency, pol.measuredLimit)
        // the server comes back; nobody kicks the queue: the back-off itself brings every transfer in
        try Backend.serverUp(); up = true
        try await waitUntil(timeout: 30) { let m = await q.summary(); return m.queued + m.running == 0 }
        for id in ids { let st = await q.get(id)?.state; XCTAssertEqual(st, .done) }
        let names = try await api.listFolder(folder.id).files.map(\.name).sorted(); XCTAssertEqual(names, ["r1.txt", "r2.txt", "r3.txt", "r4.txt"]) // each exactly once
        await q.stop()
    }
}

/// The transfer queue runs in another process (spdrive-cli), which is killed with SIGKILL in the middle of a transfer.
final class CrashResumeTests: LiveCase {
    private func cli() throws -> URL {
        let u = Bundle(for: CrashResumeTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("spdrive-cli")
        guard FileManager.default.isExecutableFile(atPath: u.path) else { XCTFail("spdrive-cli not built next to the tests: \(u.path)"); throw DriveError.local("no cli") }
        return u
    }
    // `Process.waitUntilExit()` is not used: called from a Swift concurrency thread it can wait forever (seen once in this suite).
    private func spawn(_ args: [String]) throws -> Process {
        let b = try Backend.require()
        let p = Process(); p.executableURL = try cli(); p.arguments = args
        p.environment = ["SPDRIVE_URL": b.url.absoluteString, "SPDRIVE_TOKEN": b.token]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); return p
    }
    func testUploadKilledMidTransferResumesOnTheSameServerSession() async throws {
        let db = dir.appendingPathComponent("meta.sqlite"), work = dir.appendingPathComponent("work")
        let big = try randomFile("tué.bin", bytes: 12 * 1024 * 1024)
        let p = try spawn(["queue-put", db.path, work.path, big.url.path, folder.id, String(2 * 1024 * 1024)])
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let s = try MetadataStore(url: db)
        let api = self.api!
        try await waitUntil(timeout: 30, "the other process is uploading") {
            guard let id = try? s.db.query("SELECT upload_id FROM upload_sessions").first?["upload_id"]?.text else { return false }
            return ((try? await api.uploadStatus(id).received) ?? 0) > 3 * 1024 * 1024
        }
        let session = try XCTUnwrap(try s.db.query("SELECT upload_id FROM upload_sessions").first?["upload_id"]?.text)
        XCTAssertEqual(kill(p.processIdentifier, SIGKILL), 0); try await waitUntil(timeout: 10, "the killed process is gone") { !p.isRunning }
        XCTAssertEqual(p.terminationReason, .uncaughtSignal); XCTAssertEqual(p.terminationStatus, SIGKILL) // really killed, no clean-up ran
        let row = try XCTUnwrap(try s.db.query("SELECT id, state FROM transfers").first)
        XCTAssertEqual(row["state"]?.text, "running", "the crash leaves the row as it was")
        let before = try await api.uploadStatus(session)
        XCTAssertEqual(before.status, "active"); XCTAssertGreaterThan(before.received, 3 * 1024 * 1024); XCTAssertLessThan(before.received, Int64(12 * 1024 * 1024))
        let none = try await api.listFolder(folder.id).files; XCTAssertTrue(none.isEmpty) // nothing half-written is visible
        // "relaunch": a new queue on the same database and work directory
        let q = TransferQueue(api: api, store: s, workDirectory: work, deviceName: "Tests")
        let firstProgress = Box<Int64?>(nil)
        let id = row["id"]?.text ?? ""
        let w = Task { for await e in await q.events() { if case .changed(let t) = e, t.id == id, t.state == .running, t.done > 0, firstProgress.value == nil { firstProgress.value = t.done } } }
        defer { w.cancel() }
        await q.start()
        try await waitUntil(timeout: 60) { await q.get(id)?.state == .done }
        let after = try await api.uploadStatus(session); XCTAssertEqual(after.status, "done") // the same session was finished, not a new one
        let files = try await api.listFolder(folder.id).files
        XCTAssertEqual(files.map(\.name), ["tué.bin"]); XCTAssertEqual(files.first?.sha256, big.sha) // once, intact
        XCTAssertEqual(try s.db.query("SELECT COUNT(*) AS n FROM upload_sessions").first?["n"]?.int, 0)
        print("MEASURE kill-resume upload: server had \(before.received) of \(12 * 1024 * 1024) bytes at SIGKILL; first progress after relaunch \(firstProgress.value ?? -1)")
        await q.stop()
    }
    func testDownloadKilledMidTransferResumesFromItsPartialFile() async throws {
        let db = dir.appendingPathComponent("meta.sqlite"), work = dir.appendingPathComponent("work"), dest = dir.appendingPathComponent("out/reçu.bin")
        let big = try randomFile("source.bin", bytes: 12 * 1024 * 1024)
        let item = try await upload(big.url)
        let p = try spawn(["queue-get", db.path, work.path, item.id, dest.path, String(2 * 1024 * 1024)])
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let partials = work.appendingPathComponent("partials")
        @Sendable func partialSize() -> Int64 {
            guard let f = (try? FileManager.default.contentsOfDirectory(at: partials, includingPropertiesForKeys: nil))?.first else { return 0 }
            return ((try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        try await waitUntil(timeout: 30, "the other process is downloading") { partialSize() > 3 * 1024 * 1024 }
        XCTAssertEqual(kill(p.processIdentifier, SIGKILL), 0); try await waitUntil(timeout: 10, "the killed process is gone") { !p.isRunning }
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        let had = partialSize()
        XCTAssertGreaterThan(had, 3 * 1024 * 1024); XCTAssertLessThan(had, Int64(12 * 1024 * 1024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "an unfinished download is never placed at its destination")
        let s = try MetadataStore(url: db)
        let id = try XCTUnwrap(try s.db.query("SELECT id FROM transfers").first?["id"]?.text)
        let q = TransferQueue(api: api, store: s, workDirectory: work, deviceName: "Tests")
        let lowest = Box<Int64>(.max)
        let w = Task { for await e in await q.events() { if case .changed(let t) = e, t.id == id, t.state == .running, t.done > 0 { lowest.update { $0 = min($0, t.done) } } } }
        defer { w.cancel() }
        await q.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 2 * 1024 * 1024)
        await q.start()
        try await waitUntil(timeout: 60) { await q.get(id)?.state == .done }
        XCTAssertEqual(try Hashing.sha256Hex(of: dest).sha256, big.sha)
        XCTAssertEqual(partialSize(), 0) // the partial became the file
        if lowest.value != .max { XCTAssertGreaterThanOrEqual(lowest.value, had, "progress restarts from the partial file, not from zero") }
        print("MEASURE kill-resume download: partial had \(had) bytes at SIGKILL; lowest progress reported after relaunch \(lowest.value == .max ? -1 : lowest.value)")
        await q.stop()
    }
}

final class ConflictVersionTests: LiveCase {
    func testKeepMineAsNewVersionKeepsTheServerVersionInHistoryAndOverwritesNothingSilently() async throws {
        let s = try store(), work = dir.appendingPathComponent("work")
        let base = try await upload(try text("contrat.txt", "version de départ"))
        // a real conflict: another device replaces the content, then this device sends an edit derived from the old version
        let other = try await UploadEngine(api: api, store: nil, deviceName: "Autre").upload(file: try text("o.txt", "version de l'autre appareil"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "contrat.txt", baseVersionID: base.versionID)).item
        let outcome = try await UploadEngine(api: api, store: s, deviceName: "Mac de test").upload(file: try text("m.txt", "version de ce Mac"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "contrat.txt", baseVersionID: base.versionID))
        guard case .conflictCopy(let copy, _) = outcome else { return XCTFail("expected a conflict") }
        let untouched = try await serverBytes(base.id); XCTAssertEqual(String(decoding: untouched, as: UTF8.self), "version de l'autre appareil")
        let resolver = ConflictResolver(api: api, store: s)
        let c = try resolver.record(itemID: base.id, itemName: "contrat.txt", copy: copy)
        // while the person hesitates, the file changes a third time: the resolution must refuse, not overwrite
        let stale = SyncConflict(id: c.id, itemID: c.itemID, itemName: c.itemName, copyID: c.copyID, copyName: c.copyName, kind: c.kind, detail: c.detail, detectedAt: c.detectedAt, resolvedAt: nil, resolution: nil)
        let updated = try await resolver.resolveKeepingMineAsNewVersion(stale, workDirectory: work, deviceName: "Mac de test")
        XCTAssertEqual(updated.id, base.id); XCTAssertEqual(updated.versionSeq, 3)
        let now = try await serverBytes(base.id); XCTAssertEqual(String(decoding: now, as: UTF8.self), "version de ce Mac")
        let details = try await api.fileDetails(base.id)
        XCTAssertEqual(details.versions.count, 3) // start, other device, this Mac: the whole history is there
        let v2 = try XCTUnwrap(details.versions.first { $0.seq == 2 }); XCTAssertEqual(v2.id, other.versionID)
        let kept = try await serverBytes(base.id, version: v2.id); XCTAssertEqual(String(decoding: kept, as: UTF8.self), "version de l'autre appareil") // set aside, still readable
        let live = try await api.listFolder(folder.id).files; XCTAssertEqual(live.map(\.id), [base.id]) // the copy left the folder…
        let trashedCopy = try await api.item(copy.id, kind: .file); XCTAssertNotNil(trashedCopy?.trashedAt) // …for the trash, not for nowhere
        XCTAssertEqual(try resolver.openCount(), 0); XCTAssertEqual(try resolver.conflicts().first?.resolution, "keepMineVersion")
        XCTAssertEqual(try s.item(base.id)?.versionSeq, 3) // the mirror knows
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("conflicts/\(c.id)").path)) // nothing left behind
    }
    func testKeepMineAsNewVersionRefusesWhenTheFileChangedAgain() async throws {
        let s = try store(), work = dir.appendingPathComponent("work")
        let base = try await upload(try text("plan.txt", "v1"))
        _ = try await UploadEngine(api: api, store: nil, deviceName: "Autre").upload(file: try text("o.txt", "v2 autre"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "plan.txt", baseVersionID: base.versionID))
        let outcome = try await UploadEngine(api: api, store: s, deviceName: "Mac").upload(file: try text("m.txt", "v2 mienne"), to: .newVersion(fileID: base.id, folderID: folder.id, name: "plan.txt", baseVersionID: base.versionID))
        guard case .conflictCopy(let copy, _) = outcome else { return XCTFail("expected a conflict") }
        let resolver = ConflictResolver(api: api, store: s)
        let c = try resolver.record(itemID: base.id, itemName: "plan.txt", copy: copy)
        // identical content on both sides resolves without sending a byte and without a new version
        let twin = try await upload(try text("twin.txt", "même contenu"))
        let twinCopy = try await upload(try text("twin (copie).txt", "même contenu"))
        let c2 = try resolver.record(itemID: twin.id, itemName: "twin.txt", copy: twinCopy)
        let same = try await resolver.resolveKeepingMineAsNewVersion(c2, workDirectory: work, deviceName: "Mac")
        XCTAssertEqual(same.versionSeq, 1); let gone = try await api.item(twinCopy.id, kind: .file); XCTAssertNotNil(gone?.trashedAt)
        // the first conflict is still open and resolves normally
        _ = try await resolver.resolveKeepingMineAsNewVersion(c, workDirectory: work, deviceName: "Mac")
        let bytes = try await serverBytes(base.id); XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "v2 mienne")
        XCTAssertEqual(try resolver.openCount(), 0)
    }
}
