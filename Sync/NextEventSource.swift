// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Sync/NextEventSource.swift
// Description      : The real pushed stream of SP Drive 2.0 (`GET
//                    /sync/events`, read by SPDriveNext) as a
//                    `RemoteEventSource` for the engine's `EventListener`. One
//                    connection per `connect()`; reconnection, back-off and the
//                    polling fallback stay in the listener.
// Module           : Sync
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-19
// Last Modified    : 2026-11-19
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
import SPDriveCore
import SPDriveNext

/// What SPDriveNext needs, taken from the engine's API client: same server, same token store.
public struct APIClientTransport: NextTransport {
    public let baseURL: URL
    public let session: URLSession
    public let clientHeader: String?
    private let tokens: TokenStore
    public init(api: APIClient, session: URLSession = BasicNextTransport.defaultSession()) { baseURL = api.baseURL; tokens = api.tokens; clientHeader = api.clientHeader; self.session = session }
    public func bearerToken() async throws -> String? { try tokens.readToken() }
}

public struct NextEventSource: RemoteEventSource {
    public let client: NextClient
    /// Seconds of silence after which a connection is considered dead (the server pings every 25 s).
    public let idleTimeout: Double
    public init(client: NextClient, idleTimeout: Double = 60) { self.client = client; self.idleTimeout = idleTimeout }
    public init(api: APIClient, idleTimeout: Double = 60) { client = NextClient(APIClientTransport(api: api)); self.idleTimeout = idleTimeout }
    public func connect() -> AsyncThrowingStream<RemoteEvent, Error> {
        let stream = client.syncEvents(idleTimeout: idleTimeout)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await e in stream {
                        switch e {
                        case .hello(let h): continuation.yield(.hello(head: h))
                        case .change(let h): continuation.yield(.change(head: h))
                        case .notify(let k): continuation.yield(.notify(kind: k))
                        }
                    }
                    continuation.finish(throwing: DriveError.offline("event stream closed")) // a stream that ends is a stream to reconnect
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
