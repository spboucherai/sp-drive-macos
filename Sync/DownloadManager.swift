// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/DownloadManager.swift
// Description: Resumable, verified downloads: bytes are streamed to a partial file (never held in memory), resumed with Range/If-Range, hashed on the way, and placed atomically only when size and SHA-256 match.
import CryptoKit
import Foundation
import SPDriveCore

/// Streams HTTP bodies to handlers, one URLSession for all downloads of an engine.
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    final class Sink: @unchecked Sendable {
        var onResponse: (HTTPURLResponse) -> Bool = { _ in true }
        var onData: (Data) throws -> Void = { _ in }
        var continuation: CheckedContinuation<Void, Error>?
        var failure: Error?
        var errorBody = Data()
        var status = 0
    }
    private var session: URLSession!
    private let lock = NSLock()
    private var sinks: [Int: Sink] = [:]
    init(configuration: URLSessionConfiguration) {
        super.init()
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: q)
    }
    func invalidate() { session.invalidateAndCancel() }

    /// Runs the request; `onResponse` returns false to stop. Data blocks arrive in order on a serial queue.
    func run(_ request: URLRequest, sink: Sink, onStart: (URLSessionDataTask) -> Void = { _ in }) async throws {
        let task = session.dataTask(with: request)
        lock.withLock { sinks[task.taskIdentifier] = sink }
        onStart(task)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in sink.continuation = c; task.resume() }
        } onCancel: { task.cancel() }
    }
    private func sink(_ t: URLSessionTask) -> Sink? { lock.withLock { sinks[t.taskIdentifier] } }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let k = sink(dataTask), let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        k.status = http.statusCode
        if (200..<300).contains(http.statusCode) { completionHandler(k.onResponse(http) ? .allow : .cancel) } else { completionHandler(.allow) } // read the error body
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let k = sink(dataTask), k.failure == nil else { return }
        if !(200..<300).contains(k.status) { if k.errorBody.count < 65536 { k.errorBody.append(data) }; return }
        do { try k.onData(data) } catch { k.failure = error; dataTask.cancel() }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let k: Sink? = lock.withLock { sinks.removeValue(forKey: task.taskIdentifier) }
        guard let k, let c = k.continuation else { return }
        k.continuation = nil
        if let f = k.failure { c.resume(throwing: f) }
        else if let error { c.resume(throwing: DriveError.wrap(error)) }
        else if !(200..<300).contains(k.status), let r = task.response {
            do { try APIClient.check(k.errorBody, r); c.resume() } catch { c.resume(throwing: error) }
        } else { c.resume() }
    }
}

public final class DownloadEngine: Sendable {
    public let api: APIClient
    public let throttle: Throttle?
    private let stream: StreamingSession
    public init(api: APIClient, throttle: Throttle? = nil, configuration: URLSessionConfiguration? = nil) {
        self.api = api; self.throttle = throttle
        stream = StreamingSession(configuration: configuration ?? APIClient.defaultConfiguration())
    }
    deinit { stream.invalidate() }

    /// Downloads a file's content (or one of its versions) to `destination`.
    /// - Parameters:
    ///   - partial: where the bytes accumulate; an existing partial file is resumed when the content is still the same.
    ///   - sha256: expected SHA-256; when empty, the server's ETag (the SHA-256 of the content) is used.
    ///   - progress: bytes on disk so far and total, called at most a few times per second.
    /// - Returns: the SHA-256 of what was stored.
    @discardableResult
    public func download(fileID: String, versionID: String? = nil, sha256 expected: String = "", size expectedSize: Int64? = nil, to destination: URL, partial: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        var have = (try fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        // a partial file belongs to one content: bytes of another version are never continued
        if have > 0, PartialTag.read(partial) != expected.lowercased() { try Data().write(to: partial); have = 0 }
        if !expected.isEmpty { PartialTag.write(partial, expected.lowercased()) }
        // without a known hash there is nothing to tie a partial file to: start again
        if have > 0, expected.isEmpty { try Data().write(to: partial); have = 0 }
        if let expectedSize, have > expectedSize { try Data().write(to: partial); have = 0 }

        let state = DownloadState(partial: partial, have: have, expectedSHA: expected.lowercased())
        if have > 0 { try state.rehash() }
        // a complete partial file (interrupted just before placement): verify and place without asking for a byte
        if let expectedSize, have == expectedSize, have > 0, state.currentHash() == expected.lowercased() {
            try IntegrityVerifier.placeAtomically(partial, at: destination); progress(have, have); return expected.lowercased()
        }
        let request = try api.contentRequest(fileID: fileID, versionID: versionID, from: have, etag: expected.isEmpty ? nil : expected.lowercased())
        let sink = StreamingSession.Sink()
        let throttle = self.throttle
        let taskBox = TaskBox()
        sink.onResponse = { http in
            do { try state.begin(http) } catch { sink.failure = error; return false }
            return true
        }
        sink.onData = { data in
            try state.write(data)
            progress(state.written, state.total)
            if let throttle, let task = taskBox.task {
                // pace the stream: hold the task while the bucket refills
                task.suspend()
                Task { try? await throttle.consume(data.count); task.resume() }
            }
        }
        do { try await stream.run(request, sink: sink) { taskBox.task = $0 } } catch {
            state.close()
            let e = DriveError.wrap(error)
            if e.code == "content_changed" { try? fm.removeItem(at: partial) } // what was on disk belongs to a version that is no longer current
            // 416: the partial file is already as long as the content — handled by the verification below
            if e.status != 416 { throw e }
        }
        state.close()
        let final = state.finish()
        let want = expected.isEmpty ? state.etag : expected.lowercased()
        let total = expectedSize ?? (state.total > 0 ? state.total : state.written)
        guard state.written == total else { throw DriveError.offline("téléchargement interrompu à \(state.written) sur \(total) octets") } // resumable: keep the partial
        guard want.isEmpty || final == want else {
            try? fm.removeItem(at: partial) // damaged bytes are never kept nor shown
            throw DriveError.integrity("le contenu reçu ne correspond pas à son empreinte SHA-256")
        }
        try IntegrityVerifier.placeAtomically(partial, at: destination)
        progress(total, total)
        return final
    }
}
final class TaskBox: @unchecked Sendable { var task: URLSessionDataTask? }

/// The SHA-256 a partial file is a prefix of, kept in an extended attribute of the file itself.
enum PartialTag {
    static let name = "ai.spboucher.spdrive.sha256"
    static func read(_ url: URL) -> String {
        var buffer = [UInt8](repeating: 0, count: 80)
        let n = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
    }
    static func write(_ url: URL, _ sha: String) { let b = Array(sha.utf8); _ = setxattr(url.path, name, b, b.count, 0, 0) }
}

/// File handle, running hash and counters of one download (touched only from the session's serial delegate queue, or before/after the task).
final class DownloadState: @unchecked Sendable {
    let partial: URL
    private var handle: FileHandle?
    private var hasher = SHA256()
    private(set) var written: Int64
    private(set) var total: Int64 = 0
    private(set) var etag = ""
    private let expectedSHA: String
    private var lastReport = Date.distantPast
    init(partial: URL, have: Int64, expectedSHA: String) { self.partial = partial; written = have; self.expectedSHA = expectedSHA }
    func rehash() throws { hasher = SHA256(); _ = try Hashing.sha256Hex(of: partial, into: &hasher) }
    func currentHash() -> String { var copy = hasher; return Hashing.hex(copy.finalize()) }
    func begin(_ http: HTTPURLResponse) throws {
        etag = (http.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        if !expectedSHA.isEmpty, !etag.isEmpty, etag != expectedSHA { throw DriveError.server(status: 409, code: "content_changed", message: "le fichier a changé sur le serveur pendant le téléchargement", extra: [:]) }
        let h = try FileHandle(forWritingTo: partial)
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/"), let all = Int64(range[range.index(after: slash)...]) {
            // "bytes N-M/total": the server continues where the partial file ends
            let startText = range.dropFirst("bytes ".count).prefix { $0 != "-" }
            guard Int64(startText) == written else { try h.close(); throw DriveError.invalidResponse("reprise à un mauvais décalage") }
            total = all; try h.seekToEnd()
        } else {
            // 200: the whole content comes again (no partial, or the content changed): start from zero
            try h.truncate(atOffset: 0); written = 0; hasher = SHA256()
            total = http.expectedContentLength > 0 ? http.expectedContentLength : 0
        }
        handle = h
    }
    func write(_ data: Data) throws {
        guard let handle else { throw DriveError.local("fichier partiel fermé") }
        try handle.write(contentsOf: data)
        hasher.update(data: data); written += Int64(data.count)
    }
    func close() { try? handle?.synchronize(); try? handle?.close(); handle = nil }
    func finish() -> String { Hashing.hex(hasher.finalize()) }
}
