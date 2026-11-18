// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/TransferQueue.swift
// Description: Persistent queue of uploads and downloads: priorities, controlled parallelism that adapts to the measured link, pause, resume, cancel, retry with back-off, bandwidth limits. A transfer is "done" only after the server (upload) or the SHA-256 check (download) confirmed it; the queue survives restarts.
import Foundation
import SPDriveCore

public enum TransferDirection: String, Sendable { case upload, download }
public enum TransferState: String, Sendable { case queued, running, paused, done, failed, cancelled }
public struct Transfer: Sendable, Identifiable, Equatable {
    public var id: String
    public var direction: TransferDirection
    public var state: TransferState
    /// Upload: the file being replaced (new version), if any. Download: the file fetched.
    public var itemID: String?
    /// Upload: destination folder.
    public var parentID: String?
    public var name: String
    /// Upload: the staged copy being sent. Download: the destination.
    public var localPath: String
    public var size: Int64
    public var done: Int64
    public var sha256: String?
    public var baseVersionID: String?
    public var versionID: String?
    public var priority: Int
    public var attempts: Int
    public var error: String?
    public var source: String
    public var createdAt: Date
    public var finishedAt: Date?
    /// Bytes per second over the last seconds (running transfers only).
    public var speed: Double = 0
    public var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : (state == .done ? 1 : 0) }
    public var isActive: Bool { state == .queued || state == .running }
}
public enum TransferEvent: Sendable {
    case changed(Transfer)
    case finished(Transfer, item: DriveItem?)
    case conflict(SyncConflict)
    case failed(Transfer, persistent: Bool)
    case removed(String)
}

/// Decides how many transfers run at once from what the link actually delivers.
public struct ConcurrencyAdvisor: Sendable {
    public var manual: Int?
    public private(set) var limit = 3
    private var best: Double = 0, sinceChange = 0, lastDirection = 0
    public static let range = 1...6
    public init(manual: Int? = nil) { self.manual = manual }
    /// The number of transfers allowed now.
    public func allowed(network: NetworkStatus) -> Int {
        if let manual { return min(max(manual, 1), 12) }
        if network.constrained { return 1 }
        if network.expensive { return min(limit, 2) }
        return limit
    }
    /// Feeds one measurement window: aggregate bytes per second, and whether every slot was in use.
    public mutating func observe(throughput: Double, saturated: Bool) {
        guard manual == nil, saturated else { return }
        sinceChange += 1
        guard sinceChange >= 2 else { return } // let a change settle before judging it
        if throughput > best * 1.12 {
            best = throughput
            if limit < ConcurrencyAdvisor.range.upperBound { limit += 1; lastDirection = 1; sinceChange = 0 }
        } else if lastDirection == 1, throughput < best * 0.85 {
            // the extra slot bought nothing (or cost throughput): step back
            if limit > 2 { limit -= 1 }
            lastDirection = -1; sinceChange = 0; best = throughput
        } else if throughput < best * 0.5 { best = throughput } // the link itself got slower: forget the old record
    }
}

public actor TransferQueue {
    public let api: APIClient
    public let store: MetadataStore
    public let uploadThrottle = Throttle()
    public let downloadThrottle = Throttle()
    private let uploader: UploadEngine
    private let downloader: DownloadEngine
    private let conflicts: ConflictResolver
    private let journal: OperationJournal
    private let network: NetworkMonitor?
    /// Staged uploads and partial downloads live here (same volume as their destinations is not required).
    public let workDirectory: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    private var live: [String: (done: Int64, speed: Double, lastBytes: Int64, lastAt: Date, savedAt: Date)] = [:]
    private var listeners: [UUID: AsyncStream<TransferEvent>.Continuation] = [:]
    private var advisor = ConcurrencyAdvisor()
    private var paused = false
    private var started = false
    private var ticker: Task<Void, Never>?
    private var windowBytes: Int64 = 0

    public init(api: APIClient, store: MetadataStore, workDirectory: URL, deviceName: String, network: NetworkMonitor? = nil) {
        self.api = api; self.store = store; self.workDirectory = workDirectory; self.network = network
        uploader = UploadEngine(api: api, store: store, throttle: uploadThrottle, deviceName: deviceName)
        downloader = DownloadEngine(api: api, throttle: downloadThrottle)
        conflicts = ConflictResolver(api: api, store: store)
        journal = OperationJournal(api: api, store: store)
    }

    // MARK: Observation
    public func events() -> AsyncStream<TransferEvent> {
        AsyncStream { c in
            let id = UUID(); listeners[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.dropListener(id) } }
        }
    }
    private func dropListener(_ id: UUID) { listeners[id] = nil }
    private func emit(_ e: TransferEvent) { for l in listeners.values { l.yield(e) } }

    private static func transfer(_ r: SQLRow) -> Transfer {
        Transfer(id: r["id"]?.text ?? "", direction: TransferDirection(rawValue: r["direction"]?.text ?? "") ?? .upload, state: TransferState(rawValue: r["state"]?.text ?? "") ?? .failed,
                 itemID: r["item_id"]?.text, parentID: r["parent_id"]?.text, name: r["name"]?.text ?? "", localPath: r["local_path"]?.text ?? "", size: r["size"]?.int ?? 0, done: r["done"]?.int ?? 0,
                 sha256: r["sha256"]?.text, baseVersionID: r["base_version_id"]?.text, versionID: r["version_id"]?.text, priority: Int(r["priority"]?.int ?? 0), attempts: Int(r["attempts"]?.int ?? 0),
                 error: r["error"]?.text, source: r["source"]?.text ?? "app", createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0), finishedAt: r["finished_at"]?.double.map(Date.init(timeIntervalSince1970:)))
    }
    private func decorate(_ t: Transfer) -> Transfer { var t = t; if let l = live[t.id] { t.done = max(t.done, l.done); t.speed = l.speed }; return t }
    public func list(limit: Int = 500) -> [Transfer] {
        ((try? store.db.query("SELECT * FROM transfers ORDER BY CASE state WHEN 'running' THEN 0 WHEN 'queued' THEN 1 WHEN 'paused' THEN 2 WHEN 'failed' THEN 3 ELSE 4 END, ord DESC LIMIT ?", [.int(Int64(limit))])) ?? [])
            .map(TransferQueue.transfer).map(decorate)
    }
    public func get(_ id: String) -> Transfer? { (try? store.db.query("SELECT * FROM transfers WHERE id = ?", [.text(id)]).first).map(TransferQueue.transfer).map(decorate) }
    public struct Summary: Sendable, Equatable { public var running = 0; public var queued = 0; public var paused = 0; public var failed = 0; public var bytesLeft: Int64 = 0; public var speed: Double = 0 }
    public func summary() -> Summary {
        var s = Summary()
        for r in (try? store.db.query("SELECT id, state, size, done FROM transfers WHERE state IN ('running','queued','paused','failed')")) ?? [] {
            let id = r["id"]?.text ?? "", done = max(r["done"]?.int ?? 0, live[id]?.done ?? 0)
            switch r["state"]?.text { case "running": s.running += 1; s.speed += live[id]?.speed ?? 0; case "queued": s.queued += 1; case "paused": s.paused += 1; default: s.failed += 1 }
            if r["state"]?.text != "failed" { s.bytesLeft += max(0, (r["size"]?.int ?? 0) - done) }
        }
        return s
    }
    public var isPaused: Bool { paused }
    public var concurrencyLimit: Int { advisor.allowed(network: network?.status ?? .unknown) }

    // MARK: Enqueue
    private func insert(_ t: Transfer) throws {
        let ord = (try store.db.scalar("SELECT COALESCE(MAX(ord), 0) + 1 FROM transfers").int) ?? 1
        try store.db.run("INSERT INTO transfers (id, direction, state, item_id, parent_id, name, local_path, size, done, sha256, base_version_id, version_id, priority, source, created_at, updated_at, ord) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                         [.text(t.id), .text(t.direction.rawValue), .text(t.state.rawValue), t.itemID.map(SQLValue.text) ?? .null, t.parentID.map(SQLValue.text) ?? .null, .text(t.name), .text(t.localPath), .int(t.size), .int(0),
                          t.sha256.map(SQLValue.text) ?? .null, t.baseVersionID.map(SQLValue.text) ?? .null, t.versionID.map(SQLValue.text) ?? .null, .int(Int64(t.priority)), .text(t.source),
                          .double(t.createdAt.timeIntervalSince1970), .double(t.createdAt.timeIntervalSince1970), .int(ord)])
        emit(.changed(t)); pump()
    }
    /// Queues a file for upload. The file is first copied into the work directory (a copy-on-write clone on APFS), so the
    /// queue owns stable bytes whatever happens to the original, across restarts and without the original's permissions.
    /// - Parameter replacing: send as a new version of this file instead of creating a new one.
    @discardableResult public func enqueueUpload(file: URL, parent: String, name: String? = nil, replacing: DriveItem? = nil, priority: Int = 0, source: String = "app") throws -> Transfer {
        let id = UUID().uuidString
        let clean = replacing?.name ?? NameRules.sanitize(name ?? file.lastPathComponent)
        let dir = workDirectory.appendingPathComponent("staging/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = try PathSafety.child(of: dir, named: "content")
        try FileManager.default.copyItem(at: file, to: staged)
        let size = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0
        let t = Transfer(id: id, direction: .upload, state: .queued, itemID: replacing?.id, parentID: replacing?.parentID ?? parent, name: clean, localPath: staged.path, size: size, done: 0, sha256: nil,
                         baseVersionID: nil, versionID: nil, priority: priority, attempts: 0, error: nil, source: source, createdAt: Date(), finishedAt: nil)
        try insert(t)
        return t
    }
    /// Queues a download of a file (or of one of its versions) to `destination`.
    @discardableResult public func enqueueDownload(_ item: DriveItem, version: FileVersion? = nil, to destination: URL, priority: Int = 0, source: String = "app") throws -> Transfer {
        guard !item.isFolder else { throw DriveError.local("un dossier se télécharge fichier par fichier") }
        let t = Transfer(id: UUID().uuidString, direction: .download, state: .queued, itemID: item.id, parentID: nil, name: destination.lastPathComponent, localPath: destination.path,
                         size: version?.size ?? item.size, done: 0, sha256: version?.sha256 ?? item.sha256, baseVersionID: nil, versionID: version?.id, priority: priority, attempts: 0, error: nil, source: source,
                         createdAt: Date(), finishedAt: nil)
        try insert(t)
        return t
    }

    // MARK: Control
    private func set(_ id: String, state: TransferState, error: String? = nil, nextTry: Date? = nil, finished: Bool = false) {
        let now = Date().timeIntervalSince1970
        _ = try? store.db.run("UPDATE transfers SET state = ?, error = ?, updated_at = ?, finished_at = ?, done = MAX(done, ?) WHERE id = ?",
                              [.text(state.rawValue), error.map(SQLValue.text) ?? .null, .double(nextTry?.timeIntervalSince1970 ?? now), finished ? .double(now) : .null, .int(live[id]?.done ?? 0), .text(id)])
        if state != .running { live[id] = nil }
        if let t = get(id) { emit(.changed(t)) }
    }
    public func pause(_ id: String) { guard let t = get(id), t.isActive else { return }; tasks[id]?.cancel(); tasks[id] = nil; set(id, state: .paused); pump() }
    public func resume(_ id: String) { guard let t = get(id), t.state == .paused || t.state == .failed else { return }; set(id, state: .queued); pump() }
    public func retry(_ id: String) { resume(id) }
    public func cancel(_ id: String) {
        guard let t = get(id), t.state != .done, t.state != .cancelled else { return }
        tasks[id]?.cancel(); tasks[id] = nil
        set(id, state: .cancelled, finished: true); cleanup(t); pump()
    }
    /// Pauses everything: running transfers stop at once and keep what they have (server session, partial file).
    public func pauseAll() { paused = true; for (id, task) in tasks { task.cancel(); set(id, state: .queued) }; tasks.removeAll() }
    public func resumeAll() { paused = false; pump() }
    public func clearFinished() {
        for r in (try? store.db.query("SELECT id FROM transfers WHERE state IN ('done','cancelled')")) ?? [] { if let id = r["id"]?.text { emit(.removed(id)) } }
        _ = try? store.db.run("DELETE FROM transfers WHERE state IN ('done','cancelled')")
    }
    public func remove(_ id: String) { guard let t = get(id), !t.isActive else { return }; cleanup(t); _ = try? store.db.run("DELETE FROM transfers WHERE id = ?", [.text(id)]); emit(.removed(id)) }
    public func setManualConcurrency(_ n: Int?) { advisor.manual = n; pump() }
    public func setLimits(uploadBytesPerSecond: Int64, downloadBytesPerSecond: Int64) async {
        await uploadThrottle.setLimit(uploadBytesPerSecond); await downloadThrottle.setLimit(downloadBytesPerSecond)
    }
    private func partial(_ t: Transfer) -> URL { workDirectory.appendingPathComponent("partials/\(t.id).part") }
    private func cleanup(_ t: Transfer) {
        if t.direction == .upload { try? FileManager.default.removeItem(at: URL(fileURLWithPath: t.localPath).deletingLastPathComponent()) }
        else { try? FileManager.default.removeItem(at: partial(t)) }
    }

    // MARK: Running
    /// Starts the queue: transfers that were running when the process stopped are queued again and resume where they were.
    public func start() {
        guard !started else { return }
        started = true
        _ = try? store.db.run("UPDATE transfers SET state = 'queued' WHERE state = 'running'")
        ticker = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); await self?.tick() }
        }
        pump()
    }
    public func stop() { ticker?.cancel(); ticker = nil; started = false; for t in tasks.values { t.cancel() }; tasks.removeAll() }
    /// Call when the network came back or the machine woke up: retries waiting for their back-off run now.
    public func kick() { _ = try? store.db.run("UPDATE transfers SET updated_at = 0 WHERE state = 'queued'"); pump() }

    private func tick() {
        // one measurement window: feed the advisor, persist progress, start what may start
        let running = tasks.count
        if running > 0 { advisor.observe(throughput: Double(windowBytes) / 2.0, saturated: running >= concurrencyLimit) }
        windowBytes = 0
        let now = Date()
        for (id, l) in live where now.timeIntervalSince(l.savedAt) >= 2 {
            _ = try? store.db.run("UPDATE transfers SET done = ? WHERE id = ?", [.int(l.done), .text(id)]); live[id]?.savedAt = now
            if let t = get(id) { emit(.changed(t)) }
        }
        pump()
    }
    private func pump() {
        guard started, !paused else { return }
        if let network, !network.status.online { return }
        let free = concurrencyLimit - tasks.count
        guard free > 0 else { return }
        // queued transfers whose back-off is over (updated_at holds the earliest next try)
        let rows = (try? store.db.query("SELECT * FROM transfers WHERE state = 'queued' AND updated_at <= ? ORDER BY priority DESC, ord LIMIT ?", [.double(Date().timeIntervalSince1970), .int(Int64(free + tasks.count))])) ?? []
        for t in rows.map(TransferQueue.transfer) where tasks[t.id] == nil && tasks.count < concurrencyLimit {
            set(t.id, state: .running)
            live[t.id] = (t.done, 0, t.done, Date(), Date())
            tasks[t.id] = Task { [weak self] in await self?.run(t) }
        }
    }
    private func progress(_ id: String, _ done: Int64) {
        guard var l = live[id] else { return }
        windowBytes += max(0, done - l.done)
        l.done = done
        let dt = Date().timeIntervalSince(l.lastAt)
        if dt >= 1 { l.speed = Double(done - l.lastBytes) / dt * 0.7 + l.speed * 0.3; l.lastBytes = done; l.lastAt = Date() }
        live[id] = l
    }
    private func run(_ t: Transfer) async {
        let report: @Sendable (Int64, Int64) -> Void = { [weak self] done, _ in Task { await self?.progress(t.id, done) } }
        do {
            var stored: DriveItem?
            switch t.direction {
            case .upload:
                let parent = journal.resolve(t.parentID ?? "root")
                if OperationJournal.isLocal(parent) { throw DriveError.offline("le dossier de destination n’est pas encore créé sur le serveur") }
                let target: UploadTarget = t.itemID.map { .newVersion(fileID: $0, folderID: parent, name: t.name, baseVersionID: t.baseVersionID) } ?? .newFile(folderID: parent, name: t.name, onConflict: .rename)
                let outcome = try await uploader.upload(file: URL(fileURLWithPath: t.localPath), to: target, progress: report)
                try store.upsert([outcome.item]); stored = outcome.item
                if case .conflictCopy(let copy, let original) = outcome, let c = try? conflicts.record(itemID: original, itemName: t.name, copy: copy) { emit(.conflict(c)) }
            case .download:
                guard let id = t.itemID else { throw DriveError.local("transfert sans fichier") }
                try await downloader.download(fileID: id, versionID: t.versionID, sha256: t.sha256 ?? "", size: t.size > 0 ? t.size : nil, to: URL(fileURLWithPath: t.localPath), partial: partial(t), progress: report)
            }
            finish(t, item: stored)
        } catch {
            fail(t, DriveError.wrap(error))
        }
    }
    private func finish(_ t: Transfer, item: DriveItem?) {
        tasks[t.id] = nil
        live[t.id]?.done = t.size
        set(t.id, state: .done, finished: true)
        _ = try? store.db.run("UPDATE transfers SET done = size WHERE id = ?", [.text(t.id)])
        if t.direction == .upload { cleanup(t) }
        if let done = get(t.id) { emit(.finished(done, item: item)) }
        pump()
    }
    private func fail(_ t: Transfer, _ e: DriveError) {
        tasks[t.id] = nil
        guard let now = get(t.id), now.state == .running else { pump(); return } // paused or cancelled meanwhile: that decision stands
        if e == .cancelled { set(t.id, state: .queued); pump(); return }
        let attempts = t.attempts + 1
        _ = try? store.db.run("UPDATE transfers SET attempts = ? WHERE id = ?", [.int(Int64(attempts)), .text(t.id)])
        if e.isTransient || e.code == "content_changed" || e == .unauthenticated {
            // not a verdict: wait and try again, with what was already transferred
            let delay = min(600.0, pow(2.0, Double(min(attempts, 10))) * 2)
            set(t.id, state: .queued, error: e.errorDescription, nextTry: Date().addingTimeInterval(delay))
            if attempts == 6, let cur = get(t.id) { emit(.failed(cur, persistent: true)) }
        } else {
            set(t.id, state: .failed, error: e.errorDescription ?? e.code, finished: true)
            if let cur = get(t.id) { emit(.failed(cur, persistent: false)) }
        }
        pump()
    }
}
