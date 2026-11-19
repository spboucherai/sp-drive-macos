// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Next/Transport.swift
// Description: SPDriveNext — the SP Drive 2.0 API (docs/next/API-NEXT.md of sp-drive.git) for the native clients. This file: the small transport protocol an app implements (base URL, bearer token, URLSession, client header), the client built on it, errors, loose JSON, and the Server-Sent Events reader. The package depends on nothing but Foundation, so macOS and iOS link the same code.
import Foundation

/// What SPDriveNext needs from the app: where the server is, how to authenticate, which URLSession to use.
public protocol NextTransport: Sendable {
    /// Origin of the server, e.g. https://drive.spboucher.ai (the client appends `/api/v1`).
    var baseURL: URL { get }
    var session: URLSession { get }
    /// `X-SPD-Client` value: `<platform>/<app version> (<os version>)`, platform ∈ macos | ios | ipados. nil = not sent.
    var clientHeader: String? { get }
    /// The device session token, or nil when nobody is signed in (authenticated calls then throw `.unauthenticated`).
    func bearerToken() async throws -> String?
}

/// A ready-made transport for apps that have nothing special to do.
public struct BasicNextTransport: NextTransport {
    public let baseURL: URL
    public let session: URLSession
    public let clientHeader: String?
    private let token: @Sendable () async throws -> String?
    public init(baseURL: URL, session: URLSession = BasicNextTransport.defaultSession(), clientHeader: String?, token: @escaping @Sendable () async throws -> String?) {
        self.baseURL = baseURL; self.session = session; self.clientHeader = clientHeader; self.token = token
    }
    public func bearerToken() async throws -> String? { try await token() }
    /// Ephemeral, no cookies, no cache; long resource timeout for event streams.
    public static func defaultSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 24 * 3600; c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }
    /// Builds the header value: `macos/2.0.0 (27.0)`.
    public static func clientHeader(platform: String, appVersion: String, osVersion: String) -> String { "\(platform)/\(appVersion) (\(osVersion))" }
}

public enum NextError: Error, Sendable, Equatable, LocalizedError {
    /// No network, or the server did not answer.
    case offline(String)
    case unauthenticated
    /// The server refused; `code` is its stable code (`not_found`, `forbidden`, `ai_unavailable`…).
    case server(status: Int, code: String, message: String, extra: [String: NextJSON])
    case invalidResponse(String)
    case cancelled

    public var code: String {
        switch self { case .offline: "offline"; case .unauthenticated: "unauthenticated"; case .server(_, let c, _, _): c; case .invalidResponse: "invalid_response"; case .cancelled: "cancelled" }
    }
    public var status: Int? { if case .server(let s, _, _, _) = self { return s }; return nil }
    public var extra: [String: NextJSON] { if case .server(_, _, _, let e) = self { return e }; return [:] }
    public var isNotFound: Bool { status == 404 }
    /// A live grant whose role is too weak for the action (API-NEXT D1): grey the action out, the folder still exists.
    public var isForbidden: Bool { status == 403 }
    /// Seconds the server asks to wait (`retryAfterS` of `rate_limited`, `busy`…), when it says.
    public var retryAfterSeconds: Double? { extra["retryAfterS"]?.double }
    /// The server is momentarily at capacity for this call (`503 busy`, `503 too_many_streams`, `429`): try again later, nothing is wrong with the request.
    public var isBusy: Bool { status == 503 || status == 429 }
    public var errorDescription: String? {
        switch self {
        case .offline(let m): return m
        case .unauthenticated: return "unauthenticated"
        case .server(_, let code, let message, _): return message.isEmpty ? code : message
        case .invalidResponse(let m): return m
        case .cancelled: return "cancelled"
        }
    }
    public static func wrap(_ error: Error) -> NextError {
        if let e = error as? NextError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return ns.code == NSURLErrorCancelled ? .cancelled : .offline(ns.localizedDescription) }
        return .invalidResponse(ns.localizedDescription)
    }
}

/// Loosely typed JSON (activity metadata, error details, administration blobs).
public enum NextJSON: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([NextJSON]), object([String: NextJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([NextJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: NextJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil(); case .bool(let b): try c.encode(b); case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s); case .array(let a): try c.encode(a); case .object(let o): try c.encode(o)
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [NextJSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: NextJSON]? { if case .object(let o) = self { return o }; return nil }
    public subscript(key: String) -> NextJSON? { object?[key] }
    public var isNull: Bool { self == .null }
}

/// One Server-Sent Event as it came off the wire.
public struct SSEMessage: Sendable, Equatable { public var event: String; public var data: String }

/// Incremental parser of the `text/event-stream` format (events, multi-line data, comments).
public struct SSEParser: Sendable {
    private var event = "", data: [String] = []
    public init() {}
    /// Feeds one line (without its line break). Returns a message when the line completed one (a blank line).
    public mutating func feed(line: String) -> SSEMessage? {
        if line.isEmpty {
            defer { event = ""; data = [] }
            return data.isEmpty && event.isEmpty ? nil : SSEMessage(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil } // a comment (": ping")
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") { field = line[..<colon]; var v = line[line.index(after: colon)...]; if v.hasPrefix(" ") { v = v.dropFirst() }; value = v }
        else { field = Substring(line); value = "" }
        switch field { case "event": event = String(value); case "data": data.append(String(value)); default: break }
        return nil
    }
}

/// The 2.0 client. A value type: cheap to create and to pass around.
public struct NextClient: Sendable {
    public let transport: NextTransport
    public init(_ transport: NextTransport) { self.transport = transport }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = NextClient.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "date: \(s)"))
        }
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in var c = enc.singleValueContainer(); try c.encode(NextClient.isoString(date)) }
        return e
    }()
    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
    public static func isoString(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }

    // MARK: Requests
    /// A request for `/api/v1` + path, carrying the bearer token (when `authenticated`) and the client header.
    public func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil, contentType: String = "application/json",
                        headers: [String: String] = [:], authenticated: Bool = true) async throws -> URLRequest {
        guard var comps = URLComponents(url: transport.baseURL.appendingPathComponent("api/v1" + path), resolvingAgainstBaseURL: false) else { throw NextError.invalidResponse("bad URL") }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { comps.queryItems = items; comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") }
        guard let url = comps.url else { throw NextError.invalidResponse("bad URL") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let c = transport.clientHeader { r.setValue(c, forHTTPHeaderField: "X-SPD-Client") }
        if authenticated {
            guard let token = try await transport.bearerToken(), !token.isEmpty else { throw NextError.unauthenticated }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { r.httpBody = body; r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
    /// Throws the server's error for a non-2xx answer.
    @discardableResult public static func check(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw NextError.invalidResponse("no HTTP response") }
        if (200..<300).contains(http.statusCode) { return data }
        let body = (try? JSONDecoder().decode([String: NextJSON].self, from: data)) ?? [:]
        let code = body["error"]?.string ?? "http_\(http.statusCode)"
        if http.statusCode == 401 { throw NextError.unauthenticated }
        throw NextError.server(status: http.statusCode, code: code, message: body["message"]?.string ?? "", extra: body.filter { $0.key != "error" && $0.key != "message" })
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (d, r) = try await transport.session.data(for: request)
            try NextClient.check(d, r)
            return (d, r as! HTTPURLResponse)
        } catch { throw NextError.wrap(error) }
    }
    func decode<T: Decodable>(_ type: T.Type = T.self, _ data: Data) throws -> T {
        do { return try NextClient.decoder.decode(T.self, from: data) } catch { throw NextError.invalidResponse("\(T.self): \(error)") }
    }
    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:], authenticated: Bool = true) async throws -> T {
        try decode(T.self, try await data(for: try await request("GET", path, query: query, authenticated: authenticated)).0)
    }
    public func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: B) async throws -> T {
        try decode(T.self, try await data(for: try await request(method, path, query: query, body: try NextClient.encoder.encode(body))).0)
    }
    public func send<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:]) async throws -> T {
        try decode(T.self, try await data(for: try await request(method, path, query: query, body: method == "GET" || method == "DELETE" ? nil : Data("{}".utf8))).0)
    }
    struct OK: Decodable { var ok: Bool? }

    // MARK: Server-Sent Events
    /// Opens an event stream and yields its messages until the connection ends (then the stream finishes) or fails
    /// (then it throws). An error answered before the stream starts (401, 429 `too_many_streams`, 4xx of `ai/ask`) is
    /// thrown as `NextError`. Reconnection is the caller's decision.
    /// - Parameter idleTimeout: seconds without a single byte (events or `: ping` comments) after which the stream is
    ///   declared dead and throws `.offline`. A server that stops without closing the connection is only noticed this
    ///   way. nil = wait for ever (answers that are not kept alive by pings, e.g. `ai/ask`, rely on the session's timeouts).
    public func events(_ request: URLRequest, idleTimeout: Double? = nil) -> AsyncThrowingStream<SSEMessage, Error> {
        let session = transport.session
        return AsyncThrowingStream { continuation in
            let lastByte = LastActivity()
            let task = Task {
                do {
                    var req = request; req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw NextError.invalidResponse("no HTTP response") }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data(); for try await b in bytes { body.append(b); if body.count > 65536 { break } }
                        try NextClient.check(body, response)
                    }
                    var parser = SSEParser(), line = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            lastByte.touch()
                            if line.last == 0x0D { line.removeLast() }
                            if let m = parser.feed(line: String(decoding: line, as: UTF8.self)) { continuation.yield(m) }
                            line.removeAll(keepingCapacity: true)
                        } else { line.append(byte) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: lastByte.expired ? NextError.offline("event stream silent") : NextError.wrap(error)) }
            }
            let watchdog = idleTimeout.map { limit in
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: UInt64(min(limit / 4, 5) * 1e9))
                        if lastByte.idle > limit { lastByte.expire(); task.cancel(); return }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel(); watchdog?.cancel() }
        }
    }
}
/// When the last line of a stream arrived (shared between the reader and its watchdog).
final class LastActivity: @unchecked Sendable {
    private let lock = NSLock(); private var at = Date(); private var dead = false
    func touch() { lock.withLock { at = Date() } }
    var idle: TimeInterval { lock.withLock { Date().timeIntervalSince(at) } }
    func expire() { lock.withLock { dead = true } }
    var expired: Bool { lock.withLock { dead } }
}
