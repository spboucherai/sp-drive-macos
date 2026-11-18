// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/Security/Hashing.swift
// Description: SHA-256 of data and of files read as a stream (never a whole file in memory), plus base64url coding.
import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    /// SHA-256 of a file (or of its first `length` bytes), read in 1 MiB blocks. Cancellable.
    public static func sha256Hex(of url: URL, length: Int64? = nil, into hasher: inout SHA256) throws -> Int64 {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            var want = 1 << 20
            if let length { want = Int(min(Int64(want), length - total)); if want <= 0 { break } }
            guard let block = try h.read(upToCount: want), !block.isEmpty else { break }
            hasher.update(data: block); total += Int64(block.count)
        }
        return total
    }
    public static func sha256Hex(of url: URL) throws -> (sha256: String, size: Int64) {
        var hasher = SHA256()
        let n = try sha256Hex(of: url, into: &hasher)
        return (hex(hasher.finalize()), n)
    }
}

extension Data {
    public init?(base64URL s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        self.init(base64Encoded: t)
    }
    public var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
