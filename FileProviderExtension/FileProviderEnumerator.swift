// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: FileProviderExtension/FileProviderEnumerator.swift
// Description: Enumeration for the system: the children of a folder, the trash, and the working set with incremental changes. Anchors are positions in the local mirror's change counter; the mirror is refreshed from the server's change feed first whenever the server is reachable.
import FileProvider
import Foundation
import SPDriveCore
import SPDriveSync

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    enum Scope { case folder(String), workingSet, trash }
    private let scope: Scope
    private let services: DriveServices
    private static let pageSize = 500
    init(scope: Scope, services: DriveServices) { self.scope = scope; self.services = services }
    func invalidate() {}

    private func anchor(_ seq: Int64) -> NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(Data("\(services.store.generation):\(seq)".utf8)) }
    /// Position of an anchor in this mirror; nil when it belongs to another generation of the mirror.
    private func position(_ a: NSFileProviderSyncAnchor) -> Int64? {
        let parts = String(decoding: a.rawValue, as: UTF8.self).split(separator: ":")
        guard parts.count == 2, parts[0] == services.store.generation, let n = Int64(parts[1]) else { return nil }
        return n
    }
    private func visible(_ items: [DriveItem]) -> [FileProviderItem] {
        items.filter { !OperationJournal.isLocal($0.id) && !$0.isRoot && !($0.parentID.map(OperationJournal.isLocal) ?? false) }.compactMap { services.fpItem($0) }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let obs = SendableBox(observer), offset = Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
        Task {
            do {
                var rows: [DriveItem]
                switch scope {
                case .folder(let given):
                    // "root" stands for the root folder until its identifier is known
                    var id = given == "root" ? (services.store.rootID ?? given) : given
                    if offset == 0 {
                        // the live listing when the server answers; the mirror otherwise (offline browsing)
                        do { let l = try await services.api.listFolder(id); try services.store.upsert([l.folder] + l.children); id = l.folder.id }
                        catch { let e = DriveError.wrap(error); let known = (try? services.store.item(id)) ?? nil; if !e.isTransient || known == nil { throw e } }
                    }
                    rows = try services.store.children(of: id, limit: FileProviderEnumerator.pageSize, offset: offset)
                case .trash:
                    if offset == 0 { await services.pull() }
                    rows = Array(try services.store.trashRoots().dropFirst(offset).prefix(FileProviderEnumerator.pageSize))
                case .workingSet:
                    if offset == 0 { await services.pull() }
                    rows = try services.store.allItems(limit: FileProviderEnumerator.pageSize, offset: offset)
                }
                obs.value.didEnumerate(visible(rows))
                if rows.count == FileProviderEnumerator.pageSize { obs.value.finishEnumerating(upTo: NSFileProviderPage(Data("\(offset + rows.count)".utf8))) }
                else { obs.value.finishEnumerating(upTo: nil) }
            } catch { obs.value.finishEnumeratingWithError(services.fpError(error)) }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let obs = SendableBox(observer)
        Task {
            guard let since = position(anchor) else { obs.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired)); return }
            await services.pull()
            do {
                let c = try services.store.changes(since: since, limit: FileProviderEnumerator.pageSize)
                var items = c.items
                if case .folder(let given) = scope { let id = given == "root" ? (services.store.rootID ?? given) : given; items = items.filter { $0.parentID == id } }
                if case .trash = scope { items = items.filter(\.trashRoot) }
                let updated = visible(items)
                if !updated.isEmpty { obs.value.didUpdate(updated) }
                let gone = c.deleted.filter { !OperationJournal.isLocal($0) }.map { NSFileProviderItemIdentifier($0) }
                if !gone.isEmpty { obs.value.didDeleteItems(withIdentifiers: gone) }
                obs.value.finishEnumeratingChanges(upTo: self.anchor(c.seq), moreComing: c.more)
            } catch { obs.value.finishEnumeratingWithError(services.fpError(error)) }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(anchor(services.store.seq)) }
}
/// Carries a non-Sendable system object into a task that uses it from one place only.
final class SendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
