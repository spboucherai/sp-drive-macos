// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Components/Thumbnails.swift
// Description: Real thumbnails for the browser: the server's preview image when it has one, a Quick Look thumbnail of the verified local copy otherwise, the system icon as the placeholder and the fallback. Memory cache + disk cache keyed by content version, so a thumbnail is fetched once per version.
import AppKit
import QuickLookThumbnailing
import SPDriveCore
import SwiftUI

@MainActor final class ThumbnailStore {
    private let memory = NSCache<NSString, NSImage>()
    private var api: APIClient?
    private var directory: URL?
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    /// Versions the server had no picture of when asked, and when: asked again a little later (a new upload gets its
    /// thumbnail from the server's worker a few seconds after it lands, and the change feed does not announce it).
    private var missing: [String: Date] = [:]
    static let retryAfter: TimeInterval = 20
    /// Kinds the server makes thumbnails of.
    static func mayHaveThumbnail(_ item: DriveItem) -> Bool { !item.isFolder && (item.hasThumbnail || ["image", "pdf", "video", "heic", "office"].contains(item.previewKind)) }
    private(set) var fetched = 0

    init() { memory.countLimit = 600 }
    func configure(api: APIClient, directory: URL) { self.api = api; self.directory = directory; try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func reset() { memory.removeAllObjects(); inflight.values.forEach { $0.cancel() }; inflight.removeAll(); missing.removeAll(); api = nil }

    /// One thumbnail per content version.
    static func key(_ item: DriveItem) -> String { "\(item.id)-\(item.versionID ?? String(item.sha256.prefix(16)))" }
    func cached(_ item: DriveItem) -> NSImage? { memory.object(forKey: ThumbnailStore.key(item) as NSString) }

    /// The server's thumbnail of a file (nil when it has none, or when it cannot be reached and none is cached).
    func image(for item: DriveItem) async -> NSImage? {
        let key = ThumbnailStore.key(item)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let asked = missing[key], Date().timeIntervalSince(asked) < ThumbnailStore.retryAfter { return nil }
        guard ThumbnailStore.mayHaveThumbnail(item), let api, let directory else { return nil }
        if let running = inflight[key] { return await running.value }
        let file = directory.appendingPathComponent(key + ".img")
        let task = Task<NSImage?, Never> {
            if let data = try? Data(contentsOf: file), let img = NSImage(data: data) { return img }
            guard let request = try? api.thumbnailRequest(fileID: item.id), let (data, _) = try? await api.data(for: request), let img = NSImage(data: data), img.size.width > 0 else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString); fetched += 1 } else if !Task.isCancelled { missing[key] = Date() }
        return img
    }
    /// A Quick Look thumbnail of a file that is on this Mac (used when the server has no picture of it).
    func local(_ item: DriveItem, url: URL, side: CGFloat) async -> NSImage? {
        let key = ThumbnailStore.key(item) + "-ql"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let img = rep.nsImage
        memory.setObject(img, forKey: key as NSString)
        return img
    }
}

/// The picture of an item: its real thumbnail when there is one, the icon the Finder would show otherwise.
struct ItemThumbnail: View {
    let model: AppModel   // explicit: used inside table cells and menus
    let item: DriveItem
    var side: CGFloat = 96
    @State private var image: NSImage?
    @State private var loadedKey = ""

    var body: some View {
        let key = ThumbnailStore.key(item)
        ZStack {
            if let image, loadedKey == key {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: max(3, side * 0.05), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: max(3, side * 0.05), style: .continuous).strokeBorder(SPDTheme.hairline, lineWidth: 0.5))
                    .spdElevation(.e1)
                    .transition(.opacity)
            } else {
                ItemIcon(item: item, size: side * (side > 40 ? 0.74 : 1))
            }
        }
        .frame(width: side, height: side)
        .spdMotion(.hover, value: loadedKey)
        .task(id: key) {
            if let hit = model.thumbnails.cached(item) { image = hit; loadedKey = key; return }
            guard !item.isFolder else { return }
            if ThumbnailStore.mayHaveThumbnail(item) {
                if let img = await model.thumbnails.image(for: item) { image = img; loadedKey = key; return }
                if !item.hasThumbnail, side > 40 {
                    // just uploaded: the server's worker may still be drawing it — look once more shortly
                    try? await Task.sleep(nanoseconds: UInt64((ThumbnailStore.retryAfter + 1) * 1e9))
                    if !Task.isCancelled, let img = await model.thumbnails.image(for: item) { image = img; loadedKey = key; return }
                }
            }
            // no picture on the server: draw one from the copy on this Mac, when there is one (never downloads for a thumbnail)
            if side > 40, let url = model.existingLocalCopy(of: item), let img = await model.thumbnails.local(item, url: url, side: side) { image = img; loadedKey = key }
        }
        .accessibilityHidden(true)
    }
}
