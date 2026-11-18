// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/DevSelfTest.swift
// Description: Development variant only: the signed, sandboxed application exercises its own actions against the test backend — journal, transfer queue, downloads into the Downloads folder, versions, trash, share links, keychain — and writes a report. Nothing is simulated: every check reads the server or the disk.
#if SPD_DEV
import CryptoKit
import Foundation
import SPDriveCore
import SPDriveSync

@MainActor
enum DevSelfTest {
    struct Check: Codable { var name: String; var ok: Bool; var detail: String }
    static func run(_ model: AppModel) async {
        var checks: [Check] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks.append(Check(name: name, ok: ok, detail: detail)) }
        func wait(_ seconds: Double = 20, _ cond: @MainActor () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 150_000_000) }
            return false
        }
        let out = AppEnvironment.containerURL.appendingPathComponent("selftest.json")
        try? FileManager.default.removeItem(at: out)
        defer { try? JSONEncoder().encode(checks).write(to: out) }
        guard let api = model.api, let store = model.store, await wait(20, { model.rootID != nil && model.status.lastSync != nil }), let root = model.rootID else { check("first sync", false, "no root"); return }
        check("first sync", true, "root known, \((try? store.counts().files) ?? 0) files mirrored")
        // the token really is in the shared keychain group (what the File Provider extension will read)
        check("keychain: device token readable", ((try? AppEnvironment.tokens.readToken()) ?? nil)?.isEmpty == false)
        let state = try? await api.authState()
        check("session is a device session", state?.kind == "device", state?.user?.email ?? "")

        // --- folder, rename, star through the journal ---
        let name = "Autotest \(Int(Date().timeIntervalSince1970))"
        let local = model.createFolder(in: root, name: name)
        check("create folder: appears at once in the mirror", local != nil && model.children(of: root).contains { $0.name == name })
        let created = await wait(20) { (try? await api.listFolder(root).folders.contains { $0.name == name }) ?? false }
        check("create folder: confirmed by the server", created)
        guard await wait(20, { model.children(of: root).contains { $0.name == name && !model.isPending($0.id) } }), let folder = model.children(of: root).first(where: { $0.name == name }) else { check("folder id resolved", false); return }
        model.rename(folder, to: name + " renommé"); model.setStarred([folder], true)
        let renamed = await wait(20) { let i = (try? await api.item(folder.id, kind: .folder)) ?? nil; return i?.name == name + " renommé" && i?.starred == true }
        check("rename + favourite: confirmed by the server", renamed)

        // --- upload through the queue (file created inside the sandbox), verified by hash ---
        let work = AppEnvironment.containerURL.appendingPathComponent("selftest-src", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let src = work.appendingPathComponent("données.bin")
        var bytes = Data(count: 3 * 1024 * 1024 + 17); bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try? bytes.write(to: src)
        let sha = Hashing.sha256Hex(bytes)
        await model.upload([src], to: folder.id)
        let uploaded = await wait(40) { (try? await api.listFolder(folder.id).files.first { $0.name == "données.bin" }?.sha256) == sha }
        check("upload: on the server with the same SHA-256", uploaded)
        guard let file = try? await api.listFolder(folder.id).files.first(where: { $0.name == "données.bin" }) else { check("uploaded file listed", false); return }
        _ = await wait(20) { model.item(file.id) != nil }
        check("upload: the mirror learnt the file", model.item(file.id)?.sha256 == sha)

        // --- download into ~/Downloads (sandbox entitlement), verified ---
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: model.downloadsFolder.path)) ?? [])
        await model.download([file])
        let done = await wait(40) { model.transfers.contains { $0.direction == .download && $0.itemID == file.id && $0.state == .done } }
        let dest = model.transfers.first { $0.direction == .download && $0.itemID == file.id }.map { URL(fileURLWithPath: $0.localPath) }
        let same = dest.flatMap { try? Hashing.sha256Hex(of: $0).sha256 } == sha
        check("download: file in Downloads with the same SHA-256", done && same, dest?.lastPathComponent ?? "")
        if let dest, !before.contains(dest.lastPathComponent) { try? FileManager.default.removeItem(at: dest) }

        // --- preview cache copy ---
        let copy = try? await model.localCopy(of: file)
        check("preview copy: verified local copy", copy.flatMap { try? Hashing.sha256Hex(of: $0).sha256 } == sha)

        // --- new version, history, restore ---
        try? Data("version deux".utf8).write(to: src)
        await model.uploadNewVersion(of: file, from: src)
        let v2 = await wait(30) { ((try? await api.item(file.id, kind: .file)) ?? nil)?.versionSeq == 2 }
        check("new version: version 2 on the server", v2)
        if let d = try? await api.fileDetails(file.id), let first = d.versions.last {
            _ = try? await api.restoreVersion(fileID: file.id, versionID: first.id)
            let restored = (try? await api.item(file.id, kind: .file)) ?? nil
            check("restore version: creates version 3 with the first content", restored?.versionSeq == 3 && restored?.sha256 == sha)
        } else { check("version history readable", false) }

        // --- share link, public access, revocation ---
        if let made = try? await api.createShare(for: file, settings: ShareSettings(label: "autotest", password: .some("autotest-1"))) {
            await model.refreshShares()
            check("share: listed and badge set", model.sharedIDs.contains(file.id))
            try? await api.revokeShare(made.share.id); await model.refreshShares()
            check("share: revoked", !model.sharedIDs.contains(file.id))
        } else { check("share: created", false) }

        // --- duplicate, move, trash, restore ---
        model.duplicate([file])
        let dup = await wait(20) { ((try? await api.listFolder(folder.id).files.count) ?? 0) == 2 }
        check("duplicate: a second file on the server", dup)
        if let current = model.item(file.id) { model.trash([current]) }
        let trashed = await wait(20) { ((try? await api.item(file.id, kind: .file)) ?? nil)?.trashedAt != nil }
        check("delete: in the trash on the server (not destroyed)", trashed && model.trash().contains { $0.id == file.id })
        if let t = model.trash().first(where: { $0.id == file.id }) { model.restore([t]) }
        let back = await wait(20) { let i = (try? await api.item(file.id, kind: .file)) ?? nil; return i != nil && i?.trashedAt == nil }
        check("restore from trash: live again on the server", back)

        // --- offline pin needs the Finder location; without it the app says so instead of pretending ---
        if !model.finderReady {
            await model.setPinned([file], true)
            check("offline pin without Finder location: refused with an explanation", !model.isPinned(file.id) && model.banner != nil)
        } else {
            await model.setPinned([file], true)
            let local = await wait(40) { model.isLocal(file.id) }
            check("offline pin: file materialised by the Finder location", local && model.isPinned(file.id))
        }
        // --- clean up: everything this run created goes to the trash ---
        if let f = model.item(folder.id) { model.trash([f]) }
        _ = await wait(20) { ((try? await api.item(folder.id, kind: .folder)) ?? nil)?.trashedAt != nil }
        try? FileManager.default.removeItem(at: work)
        check("journal empty at the end", (try? model.engine?.journal.pendingCount()) == 0, "\(model.status.pendingOperations) pending")
    }
}
#endif
