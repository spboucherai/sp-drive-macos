// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/SyncEngine.swift
// Description: The sync loop of a signed-in device: replays the journal of local operations, pulls the server's changes into the mirror, runs the transfer queue, reacts to network changes and wake-ups, and rests (no timer faster than its poll interval) when nothing happens.
import Foundation
import SPDriveCore

public enum SyncPhase: Sendable, Equatable { case idle, syncing, offline, paused, needsLogin, error(String) }
public struct SyncStatus: Sendable, Equatable {
    public var phase = SyncPhase.idle
    public var lastSync: Date?
    public var pendingOperations = 0
    public var openConflicts = 0
    public var transfers = TransferQueue.Summary()
    public var lastError: String?
    public init() {}
}

public actor SyncEngine {
    public nonisolated let api: APIClient
    public nonisolated let store: MetadataStore
    public nonisolated let journal: OperationJournal
    public nonisolated let transfers: TransferQueue
    public nonisolated let detector: ChangeDetector
    public nonisolated let conflicts: ConflictResolver
    private let network: NetworkMonitor
    private var loop: Task<Void, Never>?
    private var netWatch: Task<Void, Never>?
    private var transferWatch: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var poked = false
    private var paused = false
    private var status = SyncStatus()
    private var listeners: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var onRemoteChanges: (@Sendable ([DetectedChange]) async -> Void)?
    /// Seconds between two looks at the server when nothing happens; shortens after activity.
    public static let pollRange: ClosedRange<Double> = 10...120
    private var interval = SyncEngine.pollRange.lowerBound

    public init(api: APIClient, store: MetadataStore, network: NetworkMonitor, workDirectory: URL, deviceName: String) {
        self.api = api; self.store = store; self.network = network
        journal = OperationJournal(api: api, store: store)
        transfers = TransferQueue(api: api, store: store, workDirectory: workDirectory, deviceName: deviceName, network: network)
        detector = ChangeDetector(api: api, store: store)
        conflicts = ConflictResolver(api: api, store: store)
    }
    /// Called after remote changes were written to the mirror (the app signals the File Provider and refreshes its views).
    public func setRemoteChangeHandler(_ h: @escaping @Sendable ([DetectedChange]) async -> Void) { onRemoteChanges = h }

    // MARK: Status
    public func statusStream() -> AsyncStream<SyncStatus> {
        AsyncStream { c in
            let id = UUID(); listeners[id] = c; c.yield(status)
            c.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        }
    }
    private func drop(_ id: UUID) { listeners[id] = nil }
    public func currentStatus() -> SyncStatus { status }
    private func publish(_ phase: SyncPhase? = nil, error: String?? = nil) async {
        var s = status
        if let phase { s.phase = phase }
        if let error { s.lastError = error }
        s.lastSync = store.lastSync
        s.pendingOperations = (try? journal.pendingCount()) ?? 0
        s.openConflicts = (try? conflicts.openCount()) ?? 0
        s.transfers = await transfers.summary()
        guard s != status else { return }
        status = s
        for l in listeners.values { l.yield(s) }
    }

    // MARK: Lifecycle
    public func start() async {
        guard loop == nil else { return }
        await transfers.start()
        netWatch = Task { [weak self, network] in
            for await s in network.changes() { if s.online { await self?.networkReturned() } else { await self?.publish(.offline) } }
        }
        transferWatch = Task { [weak self, transfers] in for await _ in await transfers.events() { await self?.publish() } }
        loop = Task { [weak self] in await self?.runLoop() }
    }
    public func stop() async {
        loop?.cancel(); netWatch?.cancel(); transferWatch?.cancel(); loop = nil; netWatch = nil; transferWatch = nil
        await transfers.stop(); wake()
    }
    /// Pauses syncing: transfers stop and keep their progress, the journal keeps recording, nothing is sent or pulled.
    public func pause() async { paused = true; await transfers.pauseAll(); await publish(.paused) }
    public func resume() async { paused = false; await transfers.resumeAll(); poke() }
    public var isPaused: Bool { paused }
    /// Asks for a sync pass now (something was just decided locally, the machine woke up, the person asked).
    public func poke() { interval = SyncEngine.pollRange.lowerBound; poked = true; wake() }
    private func networkReturned() async { await transfers.kick(); poke() }
    private func wake() { waiter?.resume(); waiter = nil }
    private func rest(_ seconds: Double) async {
        if poked { poked = false; return }
        let sleeper = Task { [weak self] in try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); await self?.wake() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiter = c }
        sleeper.cancel(); poked = false
    }

    /// One pass: journal first (what was decided here goes out before judging what came in), then the server's changes.
    @discardableResult public func syncOnce() async throws -> [DetectedChange] {
        let r = await journal.run()
        if r.blocked { _ = try await api.syncCursor() } // surfaces the real reason (offline, signed out) as an error
        let changes = try await detector.pull()
        if r.done > 0 || !changes.isEmpty { await onRemoteChanges?(changes) }
        return changes
    }
    private func runLoop() async {
        while !Task.isCancelled {
            if paused { await publish(.paused); await rest(3600); continue }
            if !network.status.online { await publish(.offline); await rest(300); continue }
            await publish(.syncing)
            do {
                let pendingBefore = (try? journal.pendingCount()) ?? 0
                let changes = try await syncOnce()
                await publish(.idle, error: .some(nil))
                // stay attentive while things move, drift toward a slow poll when they do not
                interval = (!changes.isEmpty || pendingBefore > 0) ? SyncEngine.pollRange.lowerBound : min(SyncEngine.pollRange.upperBound, interval * 1.5)
            } catch {
                let e = DriveError.wrap(error)
                if e == .unauthenticated { await publish(.needsLogin, error: e.errorDescription); await rest(3600); continue }
                if e == .cancelled { break }
                if e.isTransient { await publish(.offline, error: e.errorDescription) } else { await publish(.error(e.errorDescription ?? e.code), error: e.errorDescription) }
                interval = min(SyncEngine.pollRange.upperBound, max(15, interval * 2))
            }
            await rest(interval)
        }
    }
}
