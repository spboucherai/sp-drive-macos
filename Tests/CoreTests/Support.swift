// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Tests/CoreTests/Support.swift
// Description: Test support: access to the real local SP Drive backend started by Scripts/backend-dev.sh, temporary folders, random files.
import CryptoKit
import Foundation
import XCTest
@testable import SPDriveCore
@testable import SPDriveSync

enum Backend {
    static let env: [String: String] = {
        guard let text = try? String(contentsOfFile: "/tmp/spdrive-backend-dev/env", encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") { let kv = line.dropFirst("export ".count).split(separator: "=", maxSplits: 1); if kv.count == 2 { out[String(kv[0])] = String(kv[1]) } }
        return out
    }()
    /// The integration tests need the real backend: without it they fail (they are never silently skipped).
    static func require(file: StaticString = #filePath, line: UInt = #line) throws -> (url: URL, token: String) {
        guard let u = env["SPDRIVE_TEST_URL"].flatMap(URL.init(string:)), let t = env["SPDRIVE_TEST_TOKEN"] else {
            XCTFail("backend de test absent : lancer Scripts/backend-dev.sh start", file: file, line: line); throw DriveError.local("no backend")
        }
        return (u, t)
    }
    static func api(token: String? = nil) throws -> APIClient {
        let b = try require()
        return try APIClient(baseURL: b.url, tokens: MemoryTokenStore(token ?? b.token), userAgent: "SPDriveTests/1.0")
    }
    /// Runs Scripts/backend-dev.sh with arguments and returns its output.
    @discardableResult static func script(_ args: String...) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [env["SPDRIVE_TEST_SCRIPT"] ?? ""] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw DriveError.local("script \(args): \(out)") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func serverDown() throws { try script("web-stop") }
    static func serverUp() throws { try script("web-start") }
}

class TempCase: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("spdrive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }
    func store(_ name: String = "meta.sqlite") throws -> MetadataStore { try MetadataStore(url: dir.appendingPathComponent(name)) }
    /// A file of pseudo-random (incompressible) bytes; returns its SHA-256.
    @discardableResult func randomFile(_ name: String, bytes: Int, seed: UInt64 = .random(in: 0 ... .max)) throws -> (url: URL, sha: String) {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
        var hasher = SHA256(), left = bytes, state = seed | 1
        while left > 0 {
            let n = min(left, 1 << 20)
            var block = Data(count: n)
            block.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt64.self)
                for i in 0..<p.count { state ^= state << 13; state ^= state >> 7; state ^= state << 17; p[i] = state }
            }
            try h.write(contentsOf: block); hasher.update(data: block); left -= n
        }
        return (url, Hashing.hex(hasher.finalize()))
    }
    func text(_ name: String, _ content: String) throws -> URL { let u = dir.appendingPathComponent(name); try Data(content.utf8).write(to: u); return u }
}

/// Thread-safe box for values collected from progress callbacks.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
func item(_ id: String, _ name: String, parent: String?, kind: ItemKind = .file, rev: Int64, size: Int64 = 0, starred: Bool = false, trashed: Bool = false, updated: Date = Date()) -> DriveItem {
    DriveItem(id: id, kind: kind, name: name, parentID: parent, size: size, sha256: "", versionID: kind == .file ? "v-\(id)-\(rev)" : nil, updatedAt: updated, starred: starred, trashedAt: trashed ? Date() : nil, trashRoot: trashed, rev: rev)
}
