// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/RemoteEvents.swift
// Description: Listening for "something changed on the server": an event stream behind a protocol (Server-Sent Events in SP Drive 2.0), with the polling fallback that keeps working whenever the stream is absent or down. Events are a hint, never the source of truth: a change only tells the engine to pull the change feed.
import Foundation
import SPDriveCore

/// What the server pushes (contract §3). `hello` once per connection, `change` when the owner's head revision moved.
public enum RemoteEvent: Sendable, Equatable {
    case hello(head: Int64)
    case change(head: Int64)
    case notify(kind: String)
}

/// A source of pushed events. `connect()` opens one connection; the stream ends (or throws) when the connection drops.
/// SP Drive 2.0 plugs its SSE client (`GET /sync/events`) in here; nothing else in the engine knows about the transport.
public protocol RemoteEventSource: Sendable {
    func connect() -> AsyncThrowingStream<RemoteEvent, Error>
}

/// Keeps the engine informed of server changes: follows the event stream when there is one, reconnects with exponential
/// back-off and jitter (1 s → 60 s), and polls the head revision (every 30 s by default) for as long as the stream is not live.
public actor EventListener {
    public enum Channel: String, Sendable, Equatable { case off, polling, stream }
    private let source: RemoteEventSource?
    private let head: @Sendable () async throws -> Int64
    private let onChange: @Sendable (Int64) async -> Void
    private let onNotify: (@Sendable (String) async -> Void)?
    private let pollInterval: Double
    private let retry: RetryPolicy
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastHead: Int64?
    public private(set) var channel = Channel.off
    public private(set) var reconnects = 0
    public private(set) var polls = 0
    private var channelListeners: [UUID: AsyncStream<Channel>.Continuation] = [:]

    /// - Parameters:
    ///   - source: the pushed stream, or nil to poll only.
    ///   - head: reads the owner's head revision (one small request).
    ///   - onChange: called when the head revision is seen to move (from either channel).
    public init(source: RemoteEventSource?, pollInterval: Double = 30, retry: RetryPolicy = .reconnect, head: @escaping @Sendable () async throws -> Int64,
                onNotify: (@Sendable (String) async -> Void)? = nil, onChange: @escaping @Sendable (Int64) async -> Void) {
        self.source = source; self.pollInterval = pollInterval; self.retry = retry; self.head = head; self.onNotify = onNotify; self.onChange = onChange
    }
    public func channels() -> AsyncStream<Channel> {
        AsyncStream { c in
            let id = UUID(); channelListeners[id] = c; c.yield(channel)
            c.onTermination = { [weak self] _ in Task { await self?.dropListener(id) } }
        }
    }
    private func dropListener(_ id: UUID) { channelListeners[id] = nil }
    private func set(_ c: Channel) { guard c != channel else { return }; channel = c; for l in channelListeners.values { l.yield(c) } }

    public func start() {
        guard streamTask == nil, pollTask == nil else { return }
        if source != nil { streamTask = Task { [weak self] in await self?.follow() } }
        startPolling()
    }
    public func stop() {
        streamTask?.cancel(); pollTask?.cancel(); streamTask = nil; pollTask = nil
        set(.off)
    }
    /// The head the engine already has (after its own pull), so that the next poll does not report it as news.
    public func noteHead(_ h: Int64) { lastHead = h }

    private func saw(_ h: Int64) async {
        guard h != lastHead else { return }
        lastHead = h
        await onChange(h)
    }
    private func startPolling() {
        guard pollTask == nil else { return }
        if channel != .stream { set(.polling) }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1e9))
                if Task.isCancelled { break }
                await self?.pollOnce()
            }
        }
    }
    private func stopPolling() { pollTask?.cancel(); pollTask = nil }
    private func pollOnce() async {
        guard channel != .stream else { return }
        polls += 1
        if let h = try? await head() { await saw(h) }
    }
    private func streamIsLive() { set(.stream); stopPolling() }
    private func streamDropped() { reconnects += 1; if channel == .stream { set(.polling) }; startPolling() }

    private func follow() async {
        guard let source else { return }
        var failures = 0
        while !Task.isCancelled {
            do {
                for try await event in source.connect() {
                    if Task.isCancelled { return }
                    switch event {
                    case .hello(let h): failures = 0; streamIsLive(); await saw(h)
                    case .change(let h): await saw(h)
                    case .notify(let kind): await onNotify?(kind)
                    }
                }
            } catch {}
            if Task.isCancelled { return }
            // the connection ended: poll while waiting, then try again a little later each time
            streamDropped(); failures += 1
            try? await Task.sleep(nanoseconds: UInt64(retry.delay(attempt: failures) * 1e9))
        }
    }
}
