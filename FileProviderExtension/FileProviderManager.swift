// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: FileProviderExtension/FileProviderManager.swift
// Description: The application's side of the Finder integration: registering and removing the SP Drive location, signalling changes, asking for downloads (offline pins), freeing local space, locating items in the Finder. Compiled into the application.
import AppKit
import FileProvider
import Foundation
import SPDriveCore

final class DriveDomain: Sendable {
    static let shared = DriveDomain()
    private var domain: NSFileProviderDomain { NSFileProviderDomain(identifier: AppEnvironment.domainIdentifier, displayName: AppEnvironment.variant.isEmpty ? "" : "Dev") }
    private var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    /// True when the SP Drive location exists in the Finder.
    func isRegistered() async -> Bool { ((try? await NSFileProviderManager.domains()) ?? []).contains { $0.identifier == AppEnvironment.domainIdentifier } }
    /// Whether the location exists, and whether the person has turned it on. macOS keeps a new location off until the
    /// person enables it in System Settings › General › Login Items & Extensions › File Providers: that consent is theirs alone.
    func state() async -> (registered: Bool, enabled: Bool) {
        guard let d = ((try? await NSFileProviderManager.domains()) ?? []).first(where: { $0.identifier == AppEnvironment.domainIdentifier }) else { return (false, false) }
        return (true, d.userEnabled)
    }
    /// Opens System Settings where File Provider locations are turned on.
    @MainActor func openSystemSettings() {
        for s in ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems", "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
    /// Adds the location to the Finder (idempotent).
    func register() async throws {
        if await isRegistered() { return }
        try await NSFileProviderManager.add(domain)
    }
    /// Removes the location. Files edited on this Mac and not yet sent are kept by the system in a folder the person can open: nothing unsynced is destroyed.
    @discardableResult func remove() async throws -> URL? {
        guard await isRegistered() else { return nil }
        return try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
    }
    /// The mirror changed: the system asks the extension for what is new.
    func signalChanges() {
        manager?.signalEnumerator(for: .workingSet) { error in if let error { AppEnvironment.log.info("signal: \(error.localizedDescription, privacy: .public)") } }
    }
    /// A condition that blocked syncing is over (signed in again, server reachable again): the system retries what it was holding.
    func signalResolved(_ code: NSFileProviderError.Code) {
        manager?.signalErrorResolved(NSFileProviderError(code)) { _ in }
    }
    /// Address of an item inside the Finder location (the file may still be a placeholder without content).
    func url(for item: DriveItem, rootID: String?) async -> URL? {
        guard let manager else { return nil }
        let id: NSFileProviderItemIdentifier = item.id == rootID ? .rootContainer : NSFileProviderItemIdentifier(item.id)
        return try? await manager.getUserVisibleURL(for: id)
    }
    func rootURL() async -> URL? { guard let manager else { return nil }; return try? await manager.getUserVisibleURL(for: .rootContainer) }
    /// Starts downloading an item now (it is also kept up to date when pinned).
    func requestDownload(_ id: String) async throws {
        guard let manager else { return }
        try await manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(id), requestedRange: NSRange(location: NSNotFound, length: 0))
    }
    /// Downloads a file now by reading it through the Finder location. `requestDownload` only queues the download in a
    /// system activity that macOS defers (on battery, under load); a coordinated read makes the system fetch at once.
    func materialize(_ id: String) async throws {
        guard let manager else { return }
        let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(id))
        try await Task.detached(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordination: NSError?, inner: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { actual in
                do { let h = try FileHandle(forReadingFrom: actual); _ = try h.read(upToCount: 1); try h.close() } catch { inner = error }
            }
            if let e = coordination ?? inner { throw e }
        }.value
    }
    /// Copies a file of the Finder location into the app's container (coordinated read; an APFS clone when possible) and
    /// checks it against the expected SHA-256 — a copy that does not match is removed and an error thrown.
    func copyOut(_ url: URL, to destination: URL, sha256: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordination: NSError?, inner: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordination) { actual in
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: actual, to: destination)
                } catch { inner = error }
            }
            if let e = coordination ?? inner { throw e }
            if !sha256.isEmpty, (try Hashing.sha256Hex(of: destination)).sha256 != sha256.lowercased() {
                try? FileManager.default.removeItem(at: destination)
                throw DriveError.integrity("la copie locale ne correspond pas à la version du serveur")
            }
        }.value
    }
    /// Removes the local copy of an item and keeps the item itself. The system refuses when the copy is pinned or holds changes not yet sent.
    func evict(_ id: String) async throws {
        guard let manager else { return }
        try await manager.evictItem(identifier: NSFileProviderItemIdentifier(id))
    }
    /// Waits until the system has nothing left to send or fetch for this location.
    func waitForStabilization() async throws { try await manager?.waitForStabilization() }
    @MainActor func openInFinder() async { if let u = await rootURL() { NSWorkspace.shared.open(u) } }
    @MainActor func reveal(_ item: DriveItem, rootID: String?) async -> Bool {
        guard let u = await url(for: item, rootID: rootID) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([u]); return true
    }
}
