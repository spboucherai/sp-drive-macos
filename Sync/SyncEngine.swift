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
    /// How server changes reach this device right now: pushed stream, polling fallback, or nothing (paused, stopped).
    public var events = EventListener.Channel.off
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
    private var eventSource: RemoteEventSource?
    private var listener: EventListener?
    private var channelWatch: Task<Void, Never>?
    private let eventPollInterval: Double

    /// - Parameters:
    ///   - power: battery and Low Power Mode, read by the transfer queue (nil = ignore power).
    ///   - eventPollInterval: seconds between two looks at the head revision while no event stream is live (contract: 30 s).
    public init(api: APIClient, store: MetadataStore, network: NetworkMonitor, workDirectory: URL, deviceName: String, power: PowerSource? = nil, eventPollInterval: Double = 30) {
        self.api = api; self.store = store; self.network = network; self.eventPollInterval = eventPollInterval
        journal = OperationJournal(api: api, store: store)
        transfers = TransferQueue(api: api, store: store, workDirectory: workDirectory, deviceName: deviceName, network: network, power: power)
        detector = ChangeDetector(api: api, store: store)
        conflicts = ConflictResolver(api: api, store: store)
    }
    /// Called after remote changes were written to the mirror (the app signals the File Provider and refreshes its views).
    public func setRemoteChangeHandler(_ h: @escaping @Sendable ([DetectedChange]) async -> Void) { onRemoteChanges = h }

    /// Plugs in the pushed event stream (SSE in 2.0). Without one, or while it is down, the engine polls.
    public func setEventSource(_ source: RemoteEventSource?) async {
        eventSource = source
        if listener != nil { await stopListening(); await startListening() }
    }
    private func startListening() async {
        guard listener == nil else { return }
        let api = self.api
        let l = EventListener(source: eventSource, pollInterval: eventPollInterval, head: { try await api.syncCursor().head }, onChange: { [weak self] _ in await self?.poke() })
        listener = l
        channelWatch = Task { [weak self] in for await c in await l.channels() { await self?.channelChanged(c) } }
        await l.start()
    }
    private func stopListening() async {
        channelWatch?.cancel(); channelWatch = nil
        await listener?.stop(); listener = nil
        await channelChanged(.off)
    }
    private func channelChanged(_ c: EventListener.Channel) async {
        guard status.events != c else { return }
        status.events = c
        for l in listeners.values { l.yield(status) }
    }

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
        s.events = status.events // may have changed while this method was suspended
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
        if !paused { await startListening() }
    }
    public func stop() async {
        loop?.cancel(); netWatch?.cancel(); transferWatch?.cancel(); loop = nil; netWatch = nil; transferWatch = nil
        await transfers.stop(); await stopListening(); wake()
    }
    /// Pauses syncing: transfers stop and keep their progress, the journal keeps recording, nothing is sent or pulled.
    public func pause() async { paused = true; await transfers.pauseAll(); await stopListening(); await publish(.paused) }
    public func resume() async { paused = false; await transfers.resumeAll(); if loop != nil { await startListening() }; poke() }
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
