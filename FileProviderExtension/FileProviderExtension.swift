// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: FileProviderExtension/FileProviderExtension.swift
// Description: SP Drive in the Finder: a replicated File Provider. The system keeps the local replica and calls this class to describe items, fetch contents, and push what was created, edited, renamed, moved, trashed or deleted on this Mac. Content pushed here is always derived from a named server version: a different current version becomes a conflict copy, never an overwrite.
import AppKit
import FileProvider
import Foundation
import OSLog
import SPDriveCore
import SPDriveSync
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, NSFileProviderCustomAction, @unchecked Sendable {
    let domain: NSFileProviderDomain
    let manager: NSFileProviderManager?
    private let lock = NSLock()
    private var cached: DriveServices?
    private let log = DriveServices.log

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        manager = NSFileProviderManager(for: domain)
        super.init()
    }
    func invalidate() {}

    /// Built on demand at each call until someone is signed in: the extension is started and stopped by the system at will and keeps no state of its own.
    private func services() throws -> DriveServices {
        try lock.withLock {
            if let c = cached { if (try? AppEnvironment.tokens.readToken()) != nil { return c }; cached = nil }
            let s = try DriveServices(); cached = s; return s
        }
    }
    /// Runs `body` as a task tied to the Progress returned to the system (cancelling one cancels the other).
    private func run(units: Int64 = 1, _ body: @escaping @Sendable (DriveServices, Progress) async throws -> Void, failure: @escaping @Sendable (NSError) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: max(units, 1))
        let task = Task {
            do {
                let s = try self.services()
                do { try await body(s, progress) } catch { self.log.error("operation failed: \(DriveError.wrap(error).code, privacy: .public)"); failure(s.fpError(error)) }
            } catch { failure(error as NSError) }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    private func done(_ s: DriveServices) { AppEnvironment.postChanged() }

    // MARK: Items
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let cb = SendableBox(completionHandler)
        return run({ s, _ in
            let root = try await s.requireRoot()
            if identifier == .trashContainer || identifier == .workingSet { throw NSFileProviderError(.noSuchItem) }
            let id = FileProviderItem.serverID(identifier, rootID: root)
            // the mirror answers at once; an unknown identifier is asked to the server
            let item: DriveItem
            if let known = try s.store.item(id) { item = known } else { item = try await s.fresh(id) }
            cb.value(s.fpItem(item), nil)
        }, failure: { cb.value(nil, $0) })
    }

    // MARK: Contents
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let cb = SendableBox(completionHandler)
        let size = (try? services().store.item(itemIdentifier.rawValue))??.size ?? 1
        return run(units: size, { s, progress in
            let item = try await s.fresh(itemIdentifier.rawValue, kind: .file)
            guard let tmp = try self.manager?.temporaryDirectoryURL() else { throw DriveError.local("dossier temporaire indisponible") }
            // a stable partial name per content version: an interrupted download resumes, even after the extension was restarted
            let partial = tmp.appendingPathComponent("\(item.id)-\(item.versionID ?? item.sha256).part")
            let dest = tmp.appendingPathComponent("\(UUID().uuidString)-\(item.id)")
            progress.totalUnitCount = max(item.size, 1)
            try await s.downloader.download(fileID: item.id, versionID: item.versionID, sha256: item.sha256, size: item.size, to: dest, partial: partial) { done, _ in progress.completedUnitCount = done }
            cb.value(dest, s.fpItem(item), nil)
        }, failure: { cb.value(nil, nil, $0) })
    }

    // MARK: Creation
    func createItem(basedOn template: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let cb = SendableBox(completionHandler)
        let name = template.filename, parentIdentifier = template.parentItemIdentifier, type = template.contentType ?? .data
        let reimport = options.contains(.mayAlreadyExist)
        if DriveServices.isExcluded(name) || type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
            // stays on this Mac only: hidden and temporary files, links (which mean nothing on another device)
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync)); return Progress()
        }
        let size = (url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber })?.int64Value ?? 1
        return run(units: size, { s, progress in
            let root = try await s.requireRoot()
            if parentIdentifier == .trashContainer { throw NSFileProviderError(.cannotSynchronize) } // nothing is created directly in the trash
            let parent = FileProviderItem.serverID(parentIdentifier, rootID: root)
            let created: DriveItem
            if type.conforms(to: .folder) || type.conforms(to: .directory) {
                // after a re-import the folder is already there under the same name: adopt it instead of making "name (2)"
                if reimport, let l = try? await s.api.listFolder(parent), let same = l.folders.first(where: { NameRules.key($0.name) == NameRules.key(NameRules.sanitize(name)) }) { created = same }
                else { created = try await s.api.createFolder(parent: parent, name: name, onConflict: .rename) }
            } else {
                let source: URL
                if let url { source = url } else {
                    // a file created without content: an empty one
                    guard let tmp = try self.manager?.temporaryDirectoryURL() else { throw DriveError.local("dossier temporaire indisponible") }
                    source = tmp.appendingPathComponent("empty-\(UUID().uuidString)"); FileManager.default.createFile(atPath: source.path, contents: nil)
                }
                if reimport, let l = try? await s.api.listFolder(parent), let same = l.files.first(where: { NameRules.key($0.name) == NameRules.key(NameRules.sanitize(name)) }),
                   same.sha256 == (try Hashing.sha256Hex(of: source)).sha256 { created = same } // identical file already on the server
                else {
                    progress.totalUnitCount = max(size, 1)
                    created = try await s.uploader.upload(file: source, to: .newFile(folderID: parent, name: name, onConflict: .rename)) { done, _ in progress.completedUnitCount = done }.item
                }
            }
            try s.store.upsert([created])
            self.done(s)
            cb.value(s.fpItem(created), [], false, nil)
        }, failure: { cb.value(nil, [], false, $0) })
    }

    // MARK: Modification
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let cb = SendableBox(completionHandler)
        let identifier = item.itemIdentifier, newName = item.filename, newParent = item.parentItemIdentifier, isFolder = item.contentType == .folder || (item.contentType?.conforms(to: .directory) ?? false)
        let base = serverVersionID(version)
        let size = (newContents.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber })?.int64Value ?? 1
        return run(units: size, { s, progress in
            let root = try await s.requireRoot()
            guard identifier != .rootContainer else { throw NSFileProviderError(.cannotSynchronize) }
            let id = identifier.rawValue, kind: ItemKind = isFolder ? .folder : .file
            let sel = isFolder ? Selection(folderIds: [id]) : Selection(fileIds: [id])
            var current = try await s.fresh(id, kind: kind)
            var refetch = false

            if changedFields.contains(.parentItemIdentifier) {
                if newParent == .trashContainer {
                    if !current.isTrashed { try await s.api.trash(sel) }
                } else {
                    let dest = FileProviderItem.serverID(newParent, rootID: root)
                    if current.isTrashed { try await s.api.restore(sel); current = try await s.fresh(id, kind: kind) } // out of the trash
                    if current.parentID != dest { try await s.api.move(sel, to: dest, onConflict: .rename) }
                }
                refetch = true
            }
            if changedFields.contains(.filename), NameRules.sanitize(newName) != current.name, !current.isTrashed || newParent != .trashContainer {
                do { _ = try await s.api.update(current, name: newName) }
                catch let e as DriveError where e.code == "name_conflict" {
                    // the name is taken on the server: tell the system which item holds it, it resolves the collision locally
                    let parent = (try await s.fresh(id, kind: kind)).parentID ?? root
                    if let l = try? await s.api.listFolder(parent), let other = l.children.first(where: { NameRules.key($0.name) == NameRules.key(NameRules.sanitize(newName)) }), let fp = s.fpItem(other) {
                        throw NSError.fileProviderErrorForCollision(with: fp)
                    }
                    throw e
                }
                refetch = true
            }
            var fetchContent = false
            if changedFields.contains(.contents), let newContents, !isFolder {
                progress.totalUnitCount = max(size, 1)
                // the edit was made from `base`; the server refuses to replace anything else
                let outcome = try await s.uploader.upload(file: newContents, to: .newVersion(fileID: id, folderID: current.parentID ?? root, name: current.name, baseVersionID: base ?? current.versionID)) { done, _ in progress.completedUnitCount = done }
                if case .conflictCopy(let copy, _) = outcome {
                    // both versions exist on the server now: this Mac's content under a conflict name, the other device's under the original name
                    try s.store.upsert([copy])
                    _ = try? s.conflicts.record(itemID: id, itemName: current.name, copy: copy, detail: "modifié dans le Finder pendant qu’un autre appareil modifiait le fichier")
                    self.log.notice("conflict: local edit kept as a copy")
                    fetchContent = true // the original on this Mac must take the server's content
                    self.manager?.signalEnumerator(for: .workingSet) { _ in }
                }
                refetch = true
            }
            let result = refetch ? try await s.fresh(id, kind: kind) : current
            self.done(s)
            cb.value(s.fpItem(result), [], fetchContent, nil)
        }, failure: { cb.value(nil, [], false, $0) })
    }

    // MARK: Deletion
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let cb = SendableBox(completionHandler)
        return run({ s, _ in
            let id = identifier.rawValue
            guard let item = try await s.api.items(Selection(fileIds: [id], folderIds: [id])).all.first else { try? s.store.remove([id]); cb.value(nil); return } // already gone
            let sel = Selection([item])
            if item.isTrashed {
                // deleted from the trash, by an explicit action of the person: gone for good
                if item.trashRoot { try await s.api.purge(sel); try s.store.remove(try s.store.subtreeIDs(of: id, includeTrashed: true)) }
            } else {
                // a deletion coming from this Mac is never a destruction: the item goes to the trash of SP Drive, where it can be restored
                try await s.api.trash(sel)
                _ = try? await s.fresh(id, kind: item.kind)
            }
            self.done(s)
            cb.value(nil)
        }, failure: { cb.value($0) })
    }

    // MARK: Enumeration
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let s = try services()
        switch containerItemIdentifier {
        case .workingSet: return FileProviderEnumerator(scope: .workingSet, services: s)
        case .trashContainer: return FileProviderEnumerator(scope: .trash, services: s)
        case .rootContainer:
            guard let root = s.rootID else { return FileProviderEnumerator(scope: .folder("root"), services: s) }
            return FileProviderEnumerator(scope: .folder(root), services: s)
        default: return FileProviderEnumerator(scope: .folder(containerItemIdentifier.rawValue), services: s)
        }
    }

    // MARK: What is on this Mac
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let s = try? services(), let e = manager?.enumeratorForMaterializedItems() else { completionHandler(); return }
        let done = SendableBox(completionHandler)
        Collector(e) { ids in
            try? s.store.replaceMaterialized(Set(ids.map(\.rawValue)))
            AppEnvironment.postChanged(); done.value()
        }.start()
    }
    func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let s = try? services(), let e = manager?.enumeratorForPendingItems() else { completionHandler(); return }
        let done = SendableBox(completionHandler)
        Collector(e) { ids in
            try? s.store.setMeta("fp_pending", String(ids.count))
            AppEnvironment.postChanged(); done.value()
        }.start()
    }

    // MARK: Context-menu actions (declared in Info.plist, `NSExtensionFileProviderActions`)
    enum Action: String {
        case copyLink, keepOffline, releaseOffline, showVersions
        static let prefix = "\(AppEnvironment.appBundleID).fileprovider.action."
        init?(_ id: NSFileProviderExtensionActionIdentifier) { guard id.rawValue.hasPrefix(Action.prefix) else { return nil }; self.init(rawValue: String(id.rawValue.dropFirst(Action.prefix.count))) }
    }
    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier], completionHandler: @escaping (Error?) -> Void) -> Progress {
        let cb = SendableBox(completionHandler)
        guard let action = Action(actionIdentifier) else { completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)); return Progress() }
        return run(units: Int64(max(itemIdentifiers.count, 1)), { s, progress in
            let root = try await s.requireRoot()
            let ids = itemIdentifiers.map { FileProviderItem.serverID($0, rootID: root) }
            switch action {
            case .copyLink:
                // a new link to this one item (read and download), its address put on the clipboard; managed afterwards in the app
                guard let id = ids.first else { break }
                let item = try await s.fresh(id)
                let made = try await s.api.createShare(for: item, settings: ShareSettings(label: "Créé depuis le Finder"))
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(made.url.absoluteString, forType: .string)
                let known = s.sharedIDs().union([id])
                try? s.store.setMeta("shared_ids", known.sorted().joined(separator: ",")); s.forgetSharedCache()
                try? s.store.touch([id])
                progress.completedUnitCount = 1
            case .keepOffline:
                for id in ids { try s.store.setPinned(id, true); try? s.store.touch([id]); progress.completedUnitCount += 1 } // the content policy then makes the system download and keep them
            case .releaseOffline:
                for id in ids {
                    try s.store.setPinned(id, false); try? s.store.touch([id])
                    try? await self.manager?.evictItem(identifier: NSFileProviderItemIdentifier(id)) // refused by the system for unsent edits: they stay
                    progress.completedUnitCount += 1
                }
            case .showVersions:
                guard let id = ids.first else { break }
                // the app shows it: a note in the shared database, a signal, and the app is opened if it was not running
                try s.store.setMeta("ui_request", "versions|\(id)|\(Date().timeIntervalSince1970)")
                let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                if app.pathExtension == "app" { let c = NSWorkspace.OpenConfiguration(); c.activates = true; _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: c) }
            }
            self.manager?.signalEnumerator(for: .workingSet) { _ in }
            self.done(s)
            self.log.notice("custom action \(action.rawValue, privacy: .public) on \(ids.count) item(s)")
            cb.value(nil)
        }, failure: { cb.value($0) })
    }

    // MARK: Thumbnails
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let per = SendableBox(perThumbnailCompletionHandler), all = SendableBox(completionHandler)
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let task = Task {
            guard let s = try? self.services() else { all.value(NSFileProviderError(.notAuthenticated)); return }
            for id in itemIdentifiers {
                if Task.isCancelled { break }
                guard (try? s.store.item(id.rawValue))??.hasThumbnail == true, let request = try? s.api.thumbnailRequest(fileID: id.rawValue), let (data, _) = try? await s.api.data(for: request) else { per.value(id, nil, nil); continue }
                per.value(id, data, nil); progress.completedUnitCount += 1
            }
            all.value(nil)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

/// Reads every page of a system enumerator (materialised or pending items) and hands the identifiers over once.
final class Collector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let enumerator: NSFileProviderEnumerator
    private var ids: [NSFileProviderItemIdentifier] = []
    private let finish: ([NSFileProviderItemIdentifier]) -> Void
    private var keep: Collector?
    init(_ e: NSFileProviderEnumerator, finish: @escaping ([NSFileProviderItemIdentifier]) -> Void) { enumerator = e; self.finish = finish }
    func start() { keep = self; enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)) }
    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) { ids.append(contentsOf: updatedItems.map(\.itemIdentifier)) }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage { enumerator.enumerateItems(for: self, startingAt: nextPage) } else { finish(ids); enumerator.invalidate(); keep = nil }
    }
    func finishEnumeratingWithError(_ error: Error) { finish(ids); enumerator.invalidate(); keep = nil }
}
