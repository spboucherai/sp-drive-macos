// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Tests/NextTests/NextTests.swift
// Description: Tests of SPDriveNext against the real local SP Drive 2.0 backend (Scripts/backend-dev.sh start): real HTTP, two real accounts, the content index and the event stream of the server. The AI provider of the testbed is a FAKE OpenAI-compatible server (Scripts/fake-ai.mjs): these tests prove the wire protocol, not a model.
import CryptoKit
import Foundation
import Network
import XCTest
@testable import SPDriveNext

enum Bed {
    static let env: [String: String] = {
        guard let text = try? String(contentsOfFile: "/tmp/spdrive-backend-dev/env", encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") { let kv = line.dropFirst("export ".count).split(separator: "=", maxSplits: 1); if kv.count == 2 { out[String(kv[0])] = String(kv[1]) } }
        return out
    }()
    static let header = BasicNextTransport.clientHeader(platform: "macos", appVersion: "2.0.0", osVersion: "27.0")
    static func client(_ key: String = "SPDRIVE_TEST_TOKEN", header: String? = Bed.header) throws -> NextClient {
        guard let u = env["SPDRIVE_TEST_URL"].flatMap(URL.init(string:)), let t = env[key], !t.isEmpty else { XCTFail("backend de test absent : lancer Scripts/backend-dev.sh start"); throw NextError.offline("no backend") }
        return NextClient(BasicNextTransport(baseURL: u, clientHeader: header) { t })
    }
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

/// Owner-side set-up through the 1.0 routes (SPDriveNext itself only covers what 2.0 adds).
extension NextClient {
    struct Listing: Decodable { var folder: NextFolder; var folders: [NextFolder]; var files: [NextFile] }
    func rootID() async throws -> String { struct C: Decodable { var rootId: String }; let c: C = try await get("/sync/cursor"); return c.rootId }
    func head() async throws -> Int64 { struct C: Decodable { var head: Int64 }; let c: C = try await get("/sync/cursor"); return c.head }
    func list(_ id: String) async throws -> Listing { try await get("/folders/\(id)") }
    func makeFolder(_ name: String, in parent: String) async throws -> NextFolder {
        struct B: Encodable { var parentId: String; var name: String; var onConflict = "rename" }
        return try await send("POST", "/folders", body: B(parentId: parent, name: name))
    }
    func put(_ name: String, _ data: Data, in folder: String, replacing fileID: String? = nil) async throws -> NextFile {
        struct B: Encodable { var folderId: String; var name: String; var size: Int64; var onConflict = "rename"; var fileId: String? }
        let up: NextUpload = try await send("POST", "/uploads", body: B(folderId: folder, name: name, size: Int64(data.count), fileId: fileID))
        if !data.isEmpty { _ = try await self.data(for: try await request("PATCH", "/uploads/\(up.id)", query: ["offset": "0"], body: data, contentType: "application/octet-stream")) }
        struct C: Encodable { var sha256: String }
        let done: NextUploadResult = try await send("POST", "/uploads/\(up.id)/complete", body: C(sha256: Bed.sha(data)))
        return done.file
    }
    func put(_ name: String, _ text: String, in folder: String) async throws -> NextFile { try await put(name, Data(text.utf8), in: folder) }
    func rename(file id: String, to name: String) async throws { struct B: Encodable { var name: String }; let _: NextFile = try await send("PATCH", "/files/\(id)", body: B(name: name)) }
    func bytes(of fileID: String) async throws -> Data { var r = try await request("GET", "/files/\(fileID)/content"); r.setValue("*/*", forHTTPHeaderField: "Accept"); return try await data(for: r).0 }
}

class NextCase: XCTestCase {
    var owner: NextClient!, member: NextClient!
    var folder: NextFolder!
    var dir: URL!
    override func setUp() async throws {
        owner = try Bed.client(); member = try Bed.client("SPDRIVE_TEST_TOKEN2")
        folder = try await owner.makeFolder("next-\(UUID().uuidString.prefix(8))", in: try await owner.rootID())
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("spdnext-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }
    func until(_ seconds: Double = 30, _ what: String = "condition", file: StaticString = #filePath, line: UInt = #line, _ cond: @escaping @Sendable () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await cond() { return }; try await Task.sleep(nanoseconds: 150_000_000) }
        XCTFail("timeout: \(what)", file: file, line: line); throw NextError.invalidResponse("timeout")
    }
    /// Waits until the server has extracted the text of these files.
    func indexed(_ files: [NextFile]) async throws {
        let c = owner!
        for f in files { try await until(45, "text of \(f.name) indexed") { ((try? await c.fileText(f.id).status) ?? "") == "ready" } }
    }
    func expect(_ code: String, status: Int? = nil, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(code)", file: file, line: line) }
        catch let e as NextError { XCTAssertEqual(e.code, code, file: file, line: line); if let status { XCTAssertEqual(e.status, status, file: file, line: line) } }
        catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }
}
final class Collected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}

final class WireTests: XCTestCase {
    func testSSEParserHandlesEventsCommentsAndMultilineData() {
        var p = SSEParser(), out: [SSEMessage] = []
        for l in ["event: hello", "data: {\"head\":27}", "", ": ping", "", "data: a", "data: b", "", "event: change", "data:{\"head\":29}", "ignored: x", ""] { if let m = p.feed(line: l) { out.append(m) } }
        XCTAssertEqual(out, [SSEMessage(event: "hello", data: "{\"head\":27}"), SSEMessage(event: "message", data: "a\nb"), SSEMessage(event: "change", data: "{\"head\":29}")])
    }
    func testSnippetRunsAndRuleEncoding() throws {
        let m = SearchMatch(where: "content", snippet: "Le ⟦budget⟧ de la ⟦coopérative⟧ est adopté.", page: nil)
        XCTAssertEqual(m.snippetRuns.map(\.text), ["Le ", "budget", " de la ", "coopérative", " est adopté."]); XCTAssertEqual(m.snippetRuns.map(\.matched), [false, true, false, true, false])
        let rule = CollectionRule(match: "all", conditions: [RuleCondition(field: "modified", op: "within", value: .number(30)), RuleCondition(field: "starred", op: "is", value: .bool(true)), RuleCondition(field: "name", op: "contains", value: .string("plan"))], sort: .init(by: "updated", dir: "desc"))
        let json = String(decoding: try NextClient.encoder.encode(rule), as: UTF8.self)
        XCTAssertTrue(json.contains("\"value\":30")); XCTAssertTrue(json.contains("\"value\":true")); XCTAssertTrue(json.contains("\"value\":\"plan\""))
        XCTAssertEqual(try NextClient.decoder.decode(CollectionRule.self, from: Data(json.utf8)), rule)
        XCTAssertNotNil(NextClient.parseDate("2026-11-19T18:44:54.900Z")); XCTAssertNotNil(NextClient.parseDate("2026-11-19T18:44:54Z")); XCTAssertNotNil(NextClient.parseDate("2026-11-19"))
        let scope = String(decoding: try NextClient.encoder.encode(AIAskRequest(scope: .folder("root"), question: "q")), as: UTF8.self)
        XCTAssertTrue(scope.contains("\"scope\":{\"folderId\":\"root\"}"))
    }
}

/// A server that says hello and then goes silent without closing the connection (what a hung or half-dead server looks like).
final class SilentStreamTests: XCTestCase {
    func testAStreamThatGoesSilentIsDeclaredDeadByTheIdleTimeout() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let kept = Collected<NWConnection>()
        listener.newConnectionHandler = { c in
            kept.add(c); c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\nevent: hello\ndata: {\"head\":7}\n\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        let ready = Collected<Bool>()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.add(true) } }
        listener.start(queue: .global())
        defer { listener.cancel(); kept.all.forEach { $0.cancel() } }
        for _ in 0..<100 where ready.all.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let port = try XCTUnwrap(listener.port)
        let client = NextClient(BasicNextTransport(baseURL: URL(string: "http://127.0.0.1:\(port.rawValue)")!, clientHeader: nil) { "t" })
        var seen: [SyncEvent] = []
        let t0 = Date()
        do { for try await e in client.syncEvents(idleTimeout: 1.5) { seen.append(e) }; XCTFail("a silent stream must not end quietly") }
        catch { XCTAssertEqual((error as? NextError)?.code, "offline") }
        XCTAssertEqual(seen, [.hello(head: 7)])
        let waited = Date().timeIntervalSince(t0); XCTAssertGreaterThan(waited, 1.4); XCTAssertLessThan(waited, 4)
    }
}

final class MetaAndEventsTests: NextCase {
    func testMetaSessionsCarryTheClientHeaderAndAccountSwitch() async throws {
        let meta = try await owner.meta()
        XCTAssertEqual(meta.api, 2); XCTAssertTrue(meta.has(.events)); XCTAssertTrue(meta.has(.collab)); XCTAssertTrue(meta.has(.collections)); XCTAssertTrue(meta.has(.storage))
        let sessions = try await owner.sessions()
        let mine = try XCTUnwrap(sessions.first(where: \.current))
        XCTAssertEqual(mine.client, ClientInfo(platform: "macos", version: "2.0.0", os: "27.0")) // stored from X-SPD-Client
        try await owner.setExternalAI(true)
        let on = try await owner.aiProviders(); XCTAssertEqual(on.external?.account, true); XCTAssertFalse(on.externalAllowed) // the server switch is off on the testbed
        try await owner.setExternalAI(false)
        let off = try await owner.aiProviders(); XCTAssertEqual(off.external?.account, false)
    }
    func testEventStreamSaysHelloThenAnnouncesAChangeMadeByAnotherClient() async throws {
        let seen = Collected<SyncEvent>()
        let stream = owner.syncEvents()
        let reader = Task { do { for try await e in stream { seen.add(e) } } catch {} }
        defer { reader.cancel() }
        try await until(10, "hello") { !seen.all.isEmpty }
        let head = try await owner.head()
        XCTAssertEqual(seen.all.first, .hello(head: head))
        let other = try Bed.client(header: nil) // another client of the same account
        let t0 = Date()
        _ = try await other.makeFolder("créé ailleurs", in: folder.id)
        try await until(5, "change event") { seen.all.contains { if case .change(let h) = $0 { return h > head }; return false } }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        reader.cancel()
    }
    func testEventStreamRefusesABadTokenBeforeItStarts() async throws {
        let bad = NextClient(BasicNextTransport(baseURL: owner.transport.baseURL, clientHeader: nil) { "not-a-token" })
        do { for try await _ in bad.syncEvents() { XCTFail("no event expected") }; XCTFail("should throw") }
        catch { XCTAssertEqual(error as? NextError, .unauthenticated) }
    }
}

final class SearchTests: NextCase {
    func testContentSearchSnippetsScopesTextStatusAndSemantic() async throws {
        let tag = "zq\(UUID().uuidString.prefix(6).lowercased())"
        let notes = try await owner.put("Notes de réunion.txt", "Ordre du jour\nLe \(tag) de la coopérative Hirondelle est adopté à l'unanimité.", in: folder.id)
        let byName = try await owner.put("\(tag) annuel.csv", "poste;montant\nloyer;1200\n", in: folder.id)
        let photo = try await owner.put("sans texte.bin", Data([0, 1, 2, 3, 255]), in: folder.id)
        try await indexed([notes])
        let all = try await owner.search(tag)
        let n = try XCTUnwrap(all.files.first { $0.id == notes.id }), b = try XCTUnwrap(all.files.first { $0.id == byName.id })
        XCTAssertEqual(n.match?.where, "content"); XCTAssertEqual(b.match?.where, "name")
        XCTAssertTrue(n.match?.snippet?.contains("⟦") ?? false)
        XCTAssertEqual(n.match?.snippetRuns.filter(\.matched).map { $0.text.lowercased() }, [tag]) // the highlighted run is the word searched
        let names = try await owner.search(tag, in: .name); XCTAssertEqual(names.files.map(\.id), [byName.id])
        let content = try await owner.search(tag, in: .content); XCTAssertEqual(content.files.map(\.id), [notes.id])
        let text = try await owner.fileText(notes.id)
        XCTAssertEqual(text.status, "ready"); XCTAssertEqual(text.source, "text"); XCTAssertTrue(text.excerpt?.contains("Hirondelle") ?? false)
        let none = try await owner.fileText(photo.id); XCTAssertTrue(["unsupported", "empty", "pending"].contains(none.status), none.status)
        let status = try await owner.indexStatus(); XCTAssertGreaterThanOrEqual(status.content.ready, 1)
        let semantic = try await owner.semanticSearch("réunion de la coopérative", limit: 5)
        XCTAssertEqual(semantic.available, status.semantic.available)
        if semantic.available { XCTAssertFalse(semantic.hits.isEmpty); XCTAssertFalse(semantic.hits[0].passage.text.isEmpty) }
        print("MEASURE semantic available: \(semantic.available), model \(status.semantic.model ?? "-"), hits \(semantic.hits.count)")
        await expect("not_found", status: 404) { _ = try await self.member.fileText(notes.id) } // another account's file
    }
}

final class AITests: NextCase {
    func testProvidersAndAStreamedAnswerWithSourcesAgainstTheFakeProvider() async throws {
        let p = try await owner.aiProviders()
        XCTAssertTrue(p.enabled); XCTAssertEqual(p.default?.provider, "maclustr")
        let local = try XCTUnwrap(p.providers.first { $0.id == "maclustr" })
        XCTAssertTrue(local.local); XCTAssertEqual(local.usable, true); XCTAssertEqual(local.models.first?.creator, "Alibaba") // the creator is not the provider
        XCTAssertEqual(p.providers.first { $0.id == "anthropic" }?.usable, false)
        let contract = try await owner.put("Contrat chalet.md", "# Contrat de location\n\nLe locataire verse un dépôt de 500 dollars avant le 1er juin.", in: folder.id)
        let binary = try await owner.put("film.bin", Data([9, 9, 9]), in: folder.id)
        try await indexed([contract])
        var sources: [AISource] = [], text = "", done: AIDone?, notice: [AIUnindexed] = [], order: [String] = []
        for try await e in owner.aiAsk(AIAskRequest(scope: .files([contract.id, binary.id]), question: "Quel est le montant du dépôt ?")) {
            switch e {
            case .notice(let u): notice = u; order.append("notice")
            case .sources(let s): sources = s; order.append("sources")
            case .delta(let t): text += t; if order.last != "delta" { order.append("delta") }
            case .done(let d): done = d; order.append("done")
            case .error(let code, let message): XCTFail("\(code) \(message)")
            }
        }
        XCTAssertEqual(order.filter { $0 != "notice" }, ["sources", "delta", "done"])
        XCTAssertEqual(sources.first?.n, 1); XCTAssertEqual(sources.first?.fileId, contract.id); XCTAssertTrue(sources.first?.text.contains("500 dollars") ?? false)
        XCTAssertTrue(text.contains("[1]")); XCTAssertTrue(text.contains("aucun vrai modèle")) // the scripted answer of the fake provider, streamed word by word
        XCTAssertEqual(done?.provider, "maclustr"); XCTAssertEqual(done?.model, "fake-qwen"); XCTAssertNotNil(done?.usage?.outputTokens); XCTAssertNil(done?.empty)
        if !notice.isEmpty { XCTAssertEqual(notice.first?.fileId, binary.id) }
        // nothing in the Drive matches: no model call, `done` says empty
        var empty: AIDone?, deltas = 0
        for try await e in owner.aiAsk(AIAskRequest(scope: .folder(folder.id), question: "xyzzyqqplugh wobblefrotz")) { if case .done(let d) = e { empty = d }; if case .delta = e { deltas += 1 } }
        XCTAssertEqual(empty?.empty, true); XCTAssertEqual(deltas, 0)
        // errors before the stream are thrown
        do { for try await _ in owner.aiAsk(AIAskRequest(scope: .all, question: "q", provider: "nope")) {}; XCTFail("should throw") } catch { XCTAssertEqual((error as? NextError)?.code, "provider_unknown") }
        do { for try await _ in owner.aiAsk(AIAskRequest(scope: .all, question: "q", provider: "anthropic", model: "claude-opus-5-5")) {}; XCTFail("should throw") }
        catch { XCTAssertTrue(["ai_external_disabled", "provider_not_configured"].contains((error as? NextError)?.code ?? ""), "\(error)") }
        do { for try await _ in owner.aiAsk(AIAskRequest(scope: .files([contract.id]), question: "q")) { }; } catch { XCTFail("\(error)") }
        do { for try await _ in member.aiAsk(AIAskRequest(scope: .files([contract.id]), question: "q")) {}; XCTFail("a foreign file must be refused") } catch { XCTAssertEqual((error as? NextError)?.status, 404) }
        // suggestions: the fake provider answers an empty list (or something the server rejects as a bad answer); the call and its decoding are what is checked
        do { let s = try await owner.aiSuggest(fileIDs: [contract.id]); XCTAssertEqual(s.provider, "maclustr"); XCTAssertTrue(s.suggestions.allSatisfy { $0.fileId == contract.id }) }
        catch let e as NextError { XCTAssertEqual(e.code, "ai_bad_answer") }
    }
}

final class CollabTests: NextCase {
    func testOwnerSharesAFolderAndTheMemberWorksInItByRole() async throws {
        let email = try XCTUnwrap(Bed.env["SPDRIVE_TEST_EMAIL2"])
        let charter = try await owner.put("Charte.txt", "Charte de l'équipe", in: folder.id)
        let sub = try await owner.makeFolder("Sous-dossier", in: folder.id)
        let outside = try await owner.put("privé.txt", "hors du partage", in: try await owner.rootID())
        // owner side
        let who = try await owner.resolveUser(email: email); XCTAssertFalse(who.userId.isEmpty)
        await expect("not_found", status: 404) { _ = try await self.owner.resolveUser(email: "personne@example.test") }
        let added = try await owner.addMember(to: folder.id, userID: who.userId, role: .viewer, workspaceName: "Équipe Projet")
        XCTAssertEqual(added.role, .viewer)
        await expect("already_member", status: 409) { _ = try await self.owner.addMember(to: self.folder.id, email: email, role: .editor) }
        let listed = try await owner.members(of: folder.id)
        XCTAssertEqual(listed.members.map(\.userId), [who.userId]); XCTAssertEqual(listed.folder.workspaceName, "Équipe Projet")
        let out = try await owner.outgoingShares(); XCTAssertEqual(out.first { $0.folder.id == folder.id }?.members, 1)
        // member side: viewer
        let grants = try await member.sharedWithMe()
        let g = try XCTUnwrap(grants.first { $0.folder.id == folder.id })
        XCTAssertEqual(g.role, .viewer); XCTAssertEqual(g.displayName, "Équipe Projet"); XCTAssertEqual(g.grantId, added.grantId)
        let root = try await member.sharedChildren(grant: g.grantId)
        XCTAssertEqual(root.folder.isGrantRoot, true); XCTAssertNil(root.folder.parentId) // nothing above the grant is shown
        XCTAssertEqual(root.files.map(\.name), ["Charte.txt"]); XCTAssertEqual(root.folders.map(\.name), ["Sous-dossier"]); XCTAssertEqual(root.breadcrumbs.count, 1)
        let details = try await member.sharedFile(grant: g.grantId, fileID: charter.id); XCTAssertEqual(details.file.sha256, charter.sha256)
        let dest = dir.appendingPathComponent("Charte.txt")
        let sha = try await member.downloadShared(grant: g.grantId, fileID: charter.id, to: dest)
        XCTAssertEqual(sha, charter.sha256); XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "Charte de l'équipe")
        await expect("not_found", status: 404) { _ = try await self.member.sharedFile(grant: g.grantId, fileID: outside.id) } // outside the subtree
        let local = dir.appendingPathComponent("apport.bin"); let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }); try payload.write(to: local)
        do { _ = try await member.uploadShared(grant: g.grantId, file: local); XCTFail("a viewer cannot upload") } catch let e as NextError { XCTAssertTrue(e.isForbidden, "\(e)") } // D1: 403, the grant still exists
        do { _ = try await member.sharedCreateFolder(grant: g.grantId, name: "x"); XCTFail("a viewer cannot create") } catch let e as NextError { XCTAssertTrue(e.isForbidden) }
        // editor
        let ed = try await owner.updateMember(of: folder.id, userID: who.userId, role: .editor); XCTAssertEqual(ed.role, .editor)
        let made = try await member.sharedCreateFolder(grant: g.grantId, name: "Apports")
        let progress = Collected<Int64>()
        let sent = try await member.uploadShared(grant: g.grantId, file: local, folderID: made.id, chunkSize: 128 * 1024) { done, _ in progress.add(done) }
        XCTAssertEqual(sent.file.sha256, Bed.sha(payload)); XCTAssertEqual(progress.all.last, 300_000); XCTAssertGreaterThanOrEqual(progress.all.count, 3) // several blocks
        // resume an upload opened earlier: only the missing blocks travel
        let opened = try await member.sharedCreateUpload(grant: g.grantId, folderID: made.id, name: "repris.bin", size: Int64(payload.count))
        let first = try await member.sharedAppend(grant: g.grantId, id: opened.id, offset: 0, chunk: payload.prefix(128 * 1024)); XCTAssertEqual(first.received, 128 * 1024)
        let offsets = Collected<Int64>()
        let resumed = try await member.uploadShared(grant: g.grantId, file: local, resume: opened.id, chunkSize: 128 * 1024) { done, _ in offsets.add(done) }
        XCTAssertEqual(resumed.id, opened.id); XCTAssertEqual(offsets.all.first, 128 * 1024); XCTAssertEqual(resumed.file.sha256, Bed.sha(payload)); XCTAssertEqual(resumed.file.name, "repris.bin")
        if case .file(let renamed) = try await member.sharedUpdateItem(grant: g.grantId, itemID: charter.id, name: "Charte v2.txt") { XCTAssertEqual(renamed.name, "Charte v2.txt") } else { XCTFail("a file was expected") }
        if case .folder(let moved) = try await member.sharedUpdateItem(grant: g.grantId, itemID: sub.id, parentID: made.id) { XCTAssertEqual(moved.parentId, made.id) } else { XCTFail("a folder was expected") }
        let ownerSees = try await owner.list(made.id); XCTAssertEqual(Set(ownerSees.files.map(\.name)), ["apport.bin", "repris.bin"]) // it all landed in the owner's tree
        try await member.sharedTrash(grant: g.grantId, fileIDs: [sent.file.id])
        let after = try await member.sharedChildren(grant: g.grantId, folderID: made.id); XCTAssertEqual(after.files.map(\.name), ["repris.bin"])
        let feed = try await member.sharedActivity(grant: g.grantId); XCTAssertFalse(feed.events.isEmpty)
        let ownerFeed = try await owner.folderActivity(folder.id)
        XCTAssertTrue(ownerFeed.events.contains { $0.viaGrant && $0.actor.me == false }); XCTAssertTrue(ownerFeed.events.contains { $0.action == "collab.member_added" })
        // uploader: sends files in, lists nothing
        _ = try await owner.updateMember(of: folder.id, userID: who.userId, role: .uploader)
        do { _ = try await member.sharedChildren(grant: g.grantId); XCTFail("an uploader lists nothing") } catch let e as NextError { XCTAssertTrue(e.isForbidden) }
        let blind = try await member.uploadShared(grant: g.grantId, file: local, name: "dépôt.bin"); XCTAssertEqual(blind.file.name, "dépôt.bin"); XCTAssertEqual(blind.file.size, 300_000)
        let history = try await member.uploadHistory(); XCTAssertTrue(history.contains { $0.grantId == g.grantId && $0.status == "done" })
        // workspace name and revocation
        let unnamed = try await owner.setWorkspaceName(of: folder.id, nil); XCTAssertNil(unnamed.workspaceName)
        try await owner.removeMember(of: folder.id, userID: who.userId)
        await expect("not_found", status: 404) { _ = try await self.member.sharedChildren(grant: g.grantId) } // the grant is dead for good
        let gone = try await member.sharedWithMe(); XCTAssertNil(gone.first { $0.grantId == g.grantId })
        await expect("not_found", status: 404) { _ = try await self.member.members(of: self.folder.id) } // owner routes are the owner's
    }
}

final class InsightTests: NextCase {
    func testCollectionsLifecyclePreviewAndValidation() async throws {
        let tag = "col\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await owner.put("\(tag) un.txt", "a", in: folder.id); _ = try await owner.put("\(tag) deux.md", "bb", in: folder.id); _ = try await owner.put("autre.txt", "c", in: folder.id)
        let rule = CollectionRule(conditions: [RuleCondition(field: "name", op: "contains", value: .string(tag)), RuleCondition(field: "folder", op: "is", value: .string(folder.id))], sort: .init(by: "name", dir: "asc"))
        let preview = try await owner.previewCollection(rule); XCTAssertEqual(preview.total, 2); XCTAssertEqual(preview.files.count, 2)
        let made = try await owner.createCollection(CollectionDraft(name: "Test \(tag)", icon: "doc.text", color: "violet", rule: rule))
        XCTAssertEqual(made.rule, rule); XCTAssertEqual(made.color, "violet")
        let list = try await owner.collections(); XCTAssertEqual(list.first { $0.id == made.id }?.count, 2)
        let items = try await owner.collectionItems(made.id); XCTAssertEqual(items.total, 2); XCTAssertEqual(items.files.map(\.name), ["\(tag) deux.md", "\(tag) un.txt"])
        var narrower = rule; narrower.conditions.append(RuleCondition(field: "ext", op: "is", value: .string("md")))
        let updated = try await owner.updateCollection(made.id, CollectionDraft(name: "Renommée \(tag)", rule: narrower)); XCTAssertEqual(updated.name, "Renommée \(tag)")
        let fewer = try await owner.collectionItems(made.id); XCTAssertEqual(fewer.files.map(\.name), ["\(tag) deux.md"])
        await expect("invalid_request", status: 400) { _ = try await self.owner.previewCollection(CollectionRule(conditions: [RuleCondition(field: "colour", op: "is", value: .string("red"))])) }
        await expect("not_found", status: 404) { _ = try await self.member.collectionItems(made.id) }
        try await owner.deleteCollection(made.id)
        let gone = try await owner.collections(); XCTAssertNil(gone.first { $0.id == made.id })
    }
    func testActivityOfAFileAndOfTheAccountWithPaging() async throws {
        let f = try await owner.put("journal.txt", "un", in: folder.id)
        try await owner.rename(file: f.id, to: "journal renommé.txt")
        let feed = try await owner.fileActivity(f.id)
        XCTAssertEqual(feed.events.map(\.action), ["file.renamed", "file.uploaded"]) // newest first
        XCTAssertEqual(feed.events[0].meta?["from"]?.string, "journal.txt"); XCTAssertEqual(feed.events[0].actor.me, true); XCTAssertEqual(feed.events[1].target?.id, f.id)
        let page1 = try await owner.accountActivity(limit: 1); XCTAssertEqual(page1.events.count, 1); XCTAssertTrue(page1.more)
        let page2 = try await owner.accountActivity(before: page1.events[0].id, limit: 1); XCTAssertNotEqual(page2.events.first?.id, page1.events[0].id)
        await expect("not_found", status: 404) { _ = try await self.member.fileActivity(f.id) }
    }
    func testStorageOverviewDrillDownAndDuplicates() async throws {
        let same = Data("contenu identique \(UUID().uuidString)".utf8)
        let a = try await owner.put("original.txt", same, in: folder.id), b = try await owner.put("copie sous un autre nom.txt", same, in: folder.id)
        _ = try await owner.put("gros.bin", Data(count: 200_000), in: folder.id)
        let o = try await owner.storageOverview()
        XCTAssertGreaterThan(o.quota.limit, 0); XCTAssertGreaterThan(o.liveBytes, 200_000); XCTAssertFalse(o.byKind.isEmpty); XCTAssertFalse(o.largest.isEmpty); XCTAssertFalse(o.growth.isEmpty)
        XCTAssertTrue(o.byFolder.contains { $0.folder.id == folder.id && $0.bytes >= 200_000 }); XCTAssertGreaterThanOrEqual(o.duplicates.groups, 1); XCTAssertEqual(o.duplicates.reclaimableBytes, 0)
        let rootView = try await owner.storageFolder(); XCTAssertTrue(rootView.children.contains { $0.folder.id == folder.id })
        let inside = try await owner.storageFolder(folder.id)
        XCTAssertEqual(inside.direct.files, 3); XCTAssertEqual(inside.files.first?.name, "gros.bin"); XCTAssertEqual(inside.breadcrumbs.last?.id, folder.id)
        let dup = try await owner.duplicates()
        let group = try XCTUnwrap(dup.groups.first { $0.sha256 == a.sha256 }); XCTAssertEqual(Set(group.files.map(\.id)), [a.id, b.id]); XCTAssertEqual(group.distinctNames, true)
        let similar = try await owner.duplicates(.similarImages, distance: 4); XCTAssertEqual(similar.mode, "similar-images"); XCTAssertEqual(similar.distance, 4)
        let stillThere = try await owner.list(folder.id); XCTAssertEqual(stillThere.files.count, 3) // looking for duplicates deletes nothing
    }
    func testVersionsListContentRestoreAndUploadHistory() async throws {
        let v1 = try await owner.put("contrat.txt", "première version", in: folder.id)
        let v2 = try await owner.put("contrat.txt", Data("deuxième version, plus longue".utf8), in: folder.id, replacing: v1.id)
        XCTAssertEqual(v2.id, v1.id); XCTAssertEqual(v2.versionSeq, 2)
        let list = try await owner.versions(of: v1.id)
        XCTAssertEqual(list.versions.map(\.seq), [2, 1]); XCTAssertEqual(list.currentVersionId, list.versions[0].id); XCTAssertEqual(list.versions[0].createdBy?.me, true); XCTAssertTrue(list.versions[0].current)
        let old = list.versions[1]
        let dest = dir.appendingPathComponent("v1.txt")
        let sha = try await owner.downloadVersion(fileID: v1.id, versionID: old.id, to: dest)
        XCTAssertEqual(sha, old.sha256); XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "première version")
        let restored = try await owner.restoreVersion(fileID: v1.id, versionID: old.id)
        XCTAssertEqual(restored.versionSeq, 3); XCTAssertEqual(restored.sha256, old.sha256)
        let after = try await owner.versions(of: v1.id); XCTAssertEqual(after.versions.map(\.seq), [3, 2, 1]) // history only grows
        let now = try await owner.bytes(of: v1.id); XCTAssertEqual(String(decoding: now, as: UTF8.self), "première version")
        let history = try await owner.uploadHistory(limit: 20)
        XCTAssertTrue(history.contains { $0.fileId == v1.id && $0.status == "done" && $0.fileExists == true })
        let active = try await owner.uploadHistory(state: "active"); XCTAssertTrue(active.allSatisfy { ["active", "completing"].contains($0.status) })
    }
    func testAdministrationViewIsForAdministratorsOnly() async throws {
        let sys = try await owner.adminSystem()
        XCTAssertEqual(sys.version, "2.0.0"); XCTAssertTrue(sys.features.contains("events")); XCTAssertNotNil(sys.raw["index"]); XCTAssertNotNil(sys.raw["backup"])
        await expect("not_found", status: 404) { _ = try await self.member.adminSystem() }
    }
}
