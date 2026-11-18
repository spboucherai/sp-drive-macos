// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Sync/IntegrityVerifier.swift
// Description: Integrity checks of content on disk (size and SHA-256 read as a stream) and atomic placement of a verified file at its destination.
import CryptoKit
import Foundation
import SPDriveCore

public enum IntegrityVerifier {
    /// Throws `.integrity` unless the file has exactly this size and this SHA-256 (an empty `sha256` checks the size only).
    public static func verify(_ url: URL, sha256: String, size: Int64?) throws {
        let (sha, n) = try Hashing.sha256Hex(of: url)
        if let size, n != size { throw DriveError.integrity("taille \(n) au lieu de \(size)") }
        if !sha256.isEmpty, sha != sha256.lowercased() { throw DriveError.integrity("empreinte SHA-256 différente") }
    }
    /// Flushes `source` to disk and renames it over `destination` (same volume): a reader sees the old file or the new one, never a mix.
    public static func placeAtomically(_ source: URL, at destination: URL) throws {
        let fd = open(source.path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(source.path, destination.path) == 0 else {
            // different volumes: copy next to the destination first, then rename
            let tmp = destination.deletingLastPathComponent().appendingPathComponent(".spdrive-\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: source, to: tmp)
            guard rename(tmp.path, destination.path) == 0 else { try? FileManager.default.removeItem(at: tmp); throw DriveError.local("écriture impossible : \(String(cString: strerror(errno)))") }
            try? FileManager.default.removeItem(at: source)
            return
        }
    }
}

/// Byte-rate limiter shared by the transfers of one direction (token bucket). A limit of 0 means unlimited.
public actor Throttle {
    private var limit: Int64
    private var allowance: Double
    private var last = ContinuousClock.now
    public init(bytesPerSecond: Int64 = 0) { limit = bytesPerSecond; allowance = Double(bytesPerSecond) }
    public func setLimit(_ bytesPerSecond: Int64) { limit = max(0, bytesPerSecond); allowance = min(allowance, Double(limit)) }
    public var bytesPerSecond: Int64 { limit }
    /// Largest block worth sending at once under the current limit (about one second of traffic).
    public func preferredBlock(_ wanted: Int) -> Int { limit > 0 ? max(16 * 1024, min(wanted, Int(limit))) : wanted }
    /// Waits until `bytes` may be sent or received.
    public func consume(_ bytes: Int) async throws {
        guard limit > 0 else { return }
        let now = ContinuousClock.now
        let elapsed = Double((now - last).components.seconds) + Double((now - last).components.attoseconds) / 1e18
        last = now
        allowance = min(Double(limit), allowance + elapsed * Double(limit)) - Double(bytes)
        if allowance < 0 { try await Task.sleep(nanoseconds: UInt64(-allowance / Double(limit) * 1e9)) }
    }
}
