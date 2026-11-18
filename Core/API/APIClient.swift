// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/API/APIClient.swift
// Description: HTTPS client of the SP Drive API: bearer device session, JSON coding, error mapping, bounded retries of idempotent calls. Everything is injected (base URL, token store, session configuration).
import Foundation

/// Where the device session token lives. The app and its extensions share one store (a keychain access group).
public protocol TokenStore: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
}
/// Token kept in memory only (tests, tools).
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock(); private var token: String?
    public init(_ token: String? = nil) { self.token = token }
    public func readToken() -> String? { lock.withLock { token } }
    public func writeToken(_ t: String) { lock.withLock { token = t } }
    public func deleteToken() { lock.withLock { token = nil } }
}

public final class APIClient: Sendable {
    public let baseURL: URL
    public let tokens: TokenStore
    public let session: URLSession
    public let userAgent: String

    /// - Parameters:
    ///   - baseURL: origin of the server, e.g. https://drive.spboucher.ai. Plain HTTP is refused except for a loopback address.
    ///   - configuration: defaults to an ephemeral configuration without cookies and without cache.
    public init(baseURL: URL, tokens: TokenStore, userAgent: String, configuration: URLSessionConfiguration? = nil) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host else { throw DriveError.local("adresse de serveur invalide") }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { throw DriveError.local("le serveur doit être joint en HTTPS") }
        self.baseURL = baseURL; self.tokens = tokens
        self.userAgent = String(String.UnicodeScalarView(userAgent.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }))
        let c = configuration ?? APIClient.defaultConfiguration()
        self.session = URLSession(configuration: c)
    }
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 8
        return c
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let v = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return v }
            if let v = try? Date(s, strategy: .iso8601) { return v }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "date: \(s)"))
        }
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in var c = enc.singleValueContainer(); try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) }
        return e
    }()

    // MARK: Requests

    /// A request for `/api/v1` + path, carrying the bearer token when `authenticated`.
    public func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil, contentType: String = "application/json",
                        headers: [String: String] = [:], authenticated: Bool = true) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1" + path), resolvingAgainstBaseURL: false) else { throw DriveError.local("adresse invalide") }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { comps.queryItems = items; comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") }
        guard let url = comps.url else { throw DriveError.local("adresse invalide") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        // the server asks every state-changing call without a bearer (sign-in, device linking) for this header; harmless on the others
        r.setValue("1", forHTTPHeaderField: "X-SPD-CSRF")
        if authenticated {
            guard let token = try tokens.readToken(), !token.isEmpty else { throw DriveError.unauthenticated }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { r.httpBody = body; r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Runs a request and returns its body for a 2xx answer; maps every failure to a `DriveError`.
    public func data(for request: URLRequest, retries: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        // only calls that change nothing are repeated blindly; uploads have their own resynchronisation
        let idempotent = ["GET", "HEAD"].contains(request.httpMethod ?? "GET")
        var left = retries ?? (idempotent ? 2 : 0), delay: UInt64 = 400_000_000
        while true {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                return (try APIClient.check(data, response), response as! HTTPURLResponse)
            } catch {
                let e = DriveError.wrap(error)
                guard left > 0, e.isTransient else { throw e }
                left -= 1
                var wait = delay
                if let s = e.extra["retryAfterS"]?.int { wait = UInt64(min(max(s, 1), 30)) * 1_000_000_000 }
                try await Task.sleep(nanoseconds: wait); delay *= 3
            }
        }
    }
    /// Checks the status of an answer; throws the server's own error code when it gave one.
    @discardableResult public static func check(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw DriveError.invalidResponse("pas de réponse HTTP") }
        if (200..<300).contains(http.statusCode) { return data }
        struct Body: Decodable { var error: String?; var message: String? }
        let body = try? decoder.decode(Body.self, from: data)
        var extra = (try? decoder.decode([String: JSONValue].self, from: data)) ?? [:]
        extra["error"] = nil; extra["message"] = nil
        let code = body?.error ?? (http.statusCode == 404 ? "not_found" : "http_\(http.statusCode)")
        if http.statusCode == 401, code == "unauthenticated" { throw DriveError.unauthenticated }
        // gateways (502/503/504) answer HTML: the application behind them is restarting or unreachable
        if body?.error == nil, [502, 503, 504].contains(http.statusCode) { throw DriveError.offline("passerelle \(http.statusCode)") }
        throw DriveError.server(status: http.statusCode, code: code, message: body?.message ?? "HTTP \(http.statusCode)", extra: extra)
    }

    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:], authenticated: Bool = true) async throws -> T {
        try decode(try await data(for: request("GET", path, query: query, authenticated: authenticated)).0)
    }
    public func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: B, authenticated: Bool = true) async throws -> T {
        try decode(try await data(for: request(method, path, query: query, body: APIClient.encoder.encode(body), authenticated: authenticated)).0)
    }
    public func send<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], authenticated: Bool = true) async throws -> T {
        try decode(try await data(for: request(method, path, query: query, body: Data("{}".utf8), authenticated: authenticated)).0)
    }
    func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try APIClient.decoder.decode(T.self, from: data) } catch { throw DriveError.invalidResponse(String(describing: error).prefix(200).description) }
    }
}
public struct OK: Decodable, Sendable { public var ok: Bool? }
