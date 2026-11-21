// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Core/Networking/NetworkMonitor.swift
// Description      : Network path observation (Network.framework): online or
//                    not, expensive or constrained link, and a stream of
//                    changes used to resume work after sleep or a change of
//                    network.
// Module           : Core
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
