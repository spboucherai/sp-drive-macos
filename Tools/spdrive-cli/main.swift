// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Tools/spdrive-cli/main.swift
// Description: Small command-line client of SP Drive built on the same engine as the app — used by the test scripts to act as "another device".
import Foundation
import SPDriveCore
import SPDriveSync

// Usage: SPDRIVE_URL=… SPDRIVE_TOKEN=… spdrive-cli <ls [folder] | changes [since] | mkdir <parent> <name> | put <file> <parent> [name] | putversion <file> <fileId> | get <fileId> <dest>
//        | cat <fileId> | rename <file|folder> <id> <name> | trash <file|folder> <id> | restore <file|folder> <id> | find <parent> <name> | link <name>>
let env = ProcessInfo.processInfo.environment
guard let base = env["SPDRIVE_URL"].flatMap(URL.init(string:)) else { FileHandle.standardError.write(Data("SPDRIVE_URL manquant\n".utf8)); exit(2) }
let api = try APIClient(baseURL: base, tokens: MemoryTokenStore(env["SPDRIVE_TOKEN"]), userAgent: "spdrive-cli/1.0")
let args = Array(CommandLine.arguments.dropFirst())
func out(_ s: String) { print(s) }
func line(_ i: DriveItem) -> String { "\(i.kind.rawValue)\t\(i.id)\t\(i.size)\t\(i.versionSeq)\t\(i.sha256.prefix(12))\t\(i.trashedAt == nil ? "live" : "trashed")\t\(i.name)" }
func sel(_ kind: String, _ id: String) -> Selection { kind == "folder" ? Selection(folderIds: [id]) : Selection(fileIds: [id]) }
do {
    switch args.first {
    case "ls": for i in try await api.listFolder(args.count > 1 ? args[1] : "root").children { out(line(i)) }
    case "changes":
        let p = try await api.changes(since: Int64(args.count > 1 ? args[1] : "0") ?? 0)
        for i in p.items { out(line(i)) }; for d in p.deleted { out("deleted\t\(d.id)") }; out("cursor\t\(p.cursor)")
    case "mkdir": out(line(try await api.createFolder(parent: args[1], name: args[2], onConflict: .rename)))
    case "put":
        let url = URL(fileURLWithPath: args[1])
        let r = try await UploadEngine(api: api, store: nil, deviceName: "cli").upload(file: url, to: .newFile(folderID: args[2], name: args.count > 3 ? args[3] : url.lastPathComponent, onConflict: .rename))
        out(line(r.item))
    case "putversion":
        guard let cur = try await api.item(args[2], kind: .file) else { throw DriveError.local("fichier inconnu") }
        let r = try await UploadEngine(api: api, store: nil, deviceName: "cli").upload(file: URL(fileURLWithPath: args[1]), to: .newVersion(fileID: cur.id, folderID: cur.parentID ?? "root", name: cur.name, baseVersionID: nil))
        out(line(r.item))
    case "get":
        guard let cur = try await api.item(args[1], kind: .file) else { throw DriveError.local("fichier inconnu") }
        let dest = URL(fileURLWithPath: args[2])
        try await DownloadEngine(api: api).download(fileID: cur.id, sha256: cur.sha256, size: cur.size, to: dest, partial: dest.appendingPathExtension("part"))
        out(line(cur))
    case "cat":
        let (d, _) = try await api.data(for: api.contentRequest(fileID: args[1]))
        FileHandle.standardOutput.write(d)
    case "rename": out(line(args[1] == "folder" ? try await api.updateFolder(args[2], name: args[3]) : try await api.updateFile(args[2], name: args[3])))
    case "trash": try await api.trash(sel(args[1], args[2])); out("ok")
    case "restore": try await api.restore(sel(args[1], args[2])); out("ok")
    case "find":
        guard let hit = try await api.listFolder(args[1]).children.first(where: { $0.name == args[2] }) else { exit(1) }
        out(line(hit))
    case "link":
        let l = try await api.startDeviceLink(deviceName: args.count > 1 ? args[1] : "cli")
        out("code\t\(l.userCode)\t\(l.verifyUrl)")
        while true {
            try await Task.sleep(nanoseconds: UInt64(l.intervalS) * 1_000_000_000)
            let s = try await api.pollDeviceLink(l.deviceCode)
            if s == .approved { out("token\t\(try api.tokens.readToken() ?? "")"); break }
            if s != .pending { out("status\t\(s)"); exit(1) }
        }
    case "queue-put", "queue-get":
        // a real transfer queue in its own process (the tests kill it mid-transfer): queue-put <db> <workdir> <file> <parent> <bytes/s> | queue-get <db> <workdir> <fileId> <dest> <bytes/s>
        let store = try MetadataStore(url: URL(fileURLWithPath: args[1]))
        let q = TransferQueue(api: api, store: store, workDirectory: URL(fileURLWithPath: args[2]), deviceName: "cli")
        let rate = Int64(args[5]) ?? 0
        await q.setLimits(uploadBytesPerSecond: rate, downloadBytesPerSecond: rate)
        let t: Transfer
        if args[0] == "queue-put" { t = try await q.enqueueUpload(file: URL(fileURLWithPath: args[3]), parent: args[4], priority: TransferPriority.userInitiated) }
        else {
            guard let cur = try await api.item(args[3], kind: .file) else { throw DriveError.local("fichier inconnu") }
            t = try await q.enqueueDownload(cur, to: URL(fileURLWithPath: args[4]), priority: TransferPriority.userInitiated)
        }
        await q.start(); out("queued\t\(t.id)"); fflush(stdout)
        while await q.get(t.id)?.state != .done { try await Task.sleep(nanoseconds: 100_000_000) }
        out("done\t\(t.id)")
    default: FileHandle.standardError.write(Data("commande inconnue\n".utf8)); exit(2)
    }
} catch { FileHandle.standardError.write(Data("erreur: \((error as? DriveError)?.code ?? "?") \(error.localizedDescription)\n".utf8)); exit(1) }
