// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/NextEventSource.swift
// Description: The real pushed stream of SP Drive 2.0 (`GET /sync/events`, read by SPDriveNext) as a `RemoteEventSource` for the engine's `EventListener`. One connection per `connect()`; reconnection, back-off and the polling fallback stay in the listener.
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
