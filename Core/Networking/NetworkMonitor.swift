// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/Networking/NetworkMonitor.swift
// Description: Network path observation (Network.framework): online or not, expensive or constrained link, and a stream of changes used to resume work after sleep or a change of network.
import Foundation
import Network

public struct NetworkStatus: Sendable, Equatable {
    public var online: Bool
    /// Cellular or personal hotspot.
    public var expensive: Bool
    /// Low Data Mode.
    public var constrained: Bool
    public static let unknown = NetworkStatus(online: true, expensive: false, constrained: false)
}

public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = NetworkStatus.unknown
    private var listeners: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let s = NetworkStatus(online: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained)
            let targets: [AsyncStream<NetworkStatus>.Continuation] = self.lock.withLock { let changed = s != self.current; self.current = s; return changed ? Array(self.listeners.values) : [] }
            for t in targets { t.yield(s) }
        }
        monitor.start(queue: DispatchQueue(label: "ai.spboucher.spdrive.network", qos: .utility))
    }
    deinit { monitor.cancel() }
    public var status: NetworkStatus { lock.withLock { current } }
    /// Every change of the network path, starting with the current state.
    public func changes() -> AsyncStream<NetworkStatus> {
        AsyncStream { c in
            let id = UUID()
            lock.withLock { listeners[id] = c }
            c.yield(status)
            c.onTermination = { [weak self] _ in self?.lock.withLock { self?.listeners[id] = nil } }
        }
    }
}
