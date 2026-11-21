// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Components/AppKitBridges.swift
// Description      : The AppKit pieces under the SwiftUI interface: the Quick
//                    Look panel (QLPreviewPanel) with its zoom from the item,
//                    on-screen anchors of items, a per-window key-down catcher
//                    (Space, Return, arrows, type-select), an inline rename
//                    field, and access to the window's search field.
// Module           : Components
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-19
// Last Modified    : 2026-11-19
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : None specified (no license file in this repository)
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

import AppKit
import ApplicationServices
import Quartz
import SwiftUI

// MARK: Anchors (where an item is on screen)
/// Views register here under the identifier of the item they show; Quick Look asks for the frame to zoom from.
@MainActor final class AnchorRegistry {
    static let shared = AnchorRegistry()
    private final class Weak { weak var view: NSView?; init(_ v: NSView) { view = v } }
    private var views: [String: Weak] = [:]
    func register(_ view: NSView, for id: String) { views[id] = Weak(view); if views.count > 4000 { views = views.filter { $0.value.view != nil } } }
    func unregister(_ view: NSView, for id: String) { if views[id]?.view === view { views[id] = nil } }
    /// Frame of the item's picture in screen coordinates, when it is visible in a window.
    func screenFrame(_ id: String) -> NSRect? {
        guard let v = views[id]?.view, let w = v.window, !v.isHiddenOrHasHiddenAncestor else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        return w.frame.intersects(r) ? r : nil
    }
    func snapshot(_ id: String) -> NSImage? {
        guard let v = views[id]?.view?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep); return img
    }
}
struct FrameAnchor: NSViewRepresentable {
    let id: String
    final class V: NSView { var id = "" }
    func makeNSView(context: Context) -> V { let v = V(); v.id = id; AnchorRegistry.shared.register(v, for: id); return v }
    func updateNSView(_ v: V, context: Context) {
        if v.id != id { AnchorRegistry.shared.unregister(v, for: v.id); v.id = id }
        AnchorRegistry.shared.register(v, for: id)
    }
    static func dismantleNSView(_ v: V, coordinator: ()) { AnchorRegistry.shared.unregister(v, for: v.id) }
}

// MARK: Quick Look
/// Drives the system Quick Look panel for one item at a time; the browser moves the selection and hands over the next item.
@MainActor final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    private var url: URL?
    private(set) var itemID: String?
    /// Key presses the panel does not use itself (arrows) go back to the browser that opened it.
    var onKey: ((NSEvent) -> Bool)?
    private(set) var presentations = 0

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    func show(url: URL, itemID: String) {
        self.url = url; self.itemID = itemID; presentations += 1
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { adopt(panel); panel.reloadData() }
        else { panel.makeKeyAndOrderFront(nil); if panel.dataSource == nil { adopt(panel); panel.reloadData() } }
    }
    func close() { if isVisible { QLPreviewPanel.shared().orderOut(nil) } }
    func adopt(_ panel: QLPreviewPanel) { panel.dataSource = self; panel.delegate = self }
    func release(_ panel: QLPreviewPanel) { panel.dataSource = nil; panel.delegate = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return onKey?(event) ?? false
    }
    /// The panel grows out of the item's picture and shrinks back into it.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let id = itemID, let r = AnchorRegistry.shared.screenFrame(id) else { return .zero }
        return r
    }
    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        itemID.flatMap { AnchorRegistry.shared.snapshot($0) }
    }
}

// MARK: Keys
/// Catches key-down events of the window it lives in before the focused control sees them. The handler returns true when it used the key.
struct KeyCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    @MainActor final class V: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let w = self.window, event.window === w, w.attachedSheet == nil else { return event }
                return self.handler?(event) == true ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.handler = handler; return v }
    func updateNSView(_ v: V, context: Context) { v.handler = handler }
    static func dismantleNSView(_ v: V, coordinator: ()) { v.stop() }
}
extension NSEvent {
    /// True while the person is typing in a text field or a text view of this window.
    @MainActor var isInTextInput: Bool { window?.firstResponder is NSText }
    @MainActor var firstResponderIsTable: Bool { window?.firstResponder is NSTableView }
    var plainModifiers: NSEvent.ModifierFlags { modifierFlags.intersection([.command, .control, .option, .shift]) }
}
enum Key { static let space: UInt16 = 49, `return`: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126, tab: UInt16 = 48, delete: UInt16 = 51 }

// MARK: Window helpers
@MainActor enum WindowTools {
    /// Puts the insertion point in the window's toolbar search field (⌘F).
    static func focusSearch(in window: NSWindow?) {
        guard let window else { return }
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first { item.beginSearchInteraction(); return }
        if let field = find(NSSearchField.self, in: window.contentView?.superview) { window.makeFirstResponder(field) }
    }
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }
    static var keyBrowserWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }
}
/// Gives SwiftUI code the NSWindow it is in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    final class V: NSView { var onWindow: ((NSWindow?) -> Void)?; override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) } }
    func makeNSView(context: Context) -> V { let v = V(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: V, context: Context) { v.onWindow = onWindow }
}

// MARK: Inline rename
/// A text field that takes the focus as soon as it appears, with the name selected up to its extension — the Finder's rename.
struct RenameField: NSViewRepresentable {
    let initial: String
    let isFolder: Bool
    var alignment: NSTextAlignment = .left
    let commit: (String) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> C { C(self) }
    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: initial)
        f.delegate = context.coordinator; f.isBordered = true; f.bezelStyle = .roundedBezel; f.font = .systemFont(ofSize: NSFont.systemFontSize); f.alignment = alignment
        f.lineBreakMode = .byTruncatingMiddle; f.usesSingleLineMode = true; f.focusRingType = .default
        f.setAccessibilityIdentifier("inline-rename")
        DispatchQueue.main.async { [weak f] in
            guard let f, let w = f.window else { return }
            w.makeFirstResponder(f)
            let stem = isFolder ? (initial as NSString).length : ((initial as NSString).deletingPathExtension as NSString).length
            f.currentEditor()?.selectedRange = NSRange(location: 0, length: stem > 0 ? stem : (initial as NSString).length)
        }
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) { context.coordinator.parent = self }
    @MainActor final class C: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        private var finished = false
        init(_ p: RenameField) { parent = p }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { finished = true; parent.cancel(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) { finished = true; parent.commit(control.stringValue); return true }
            return false
        }
        func controlTextDidEndEditing(_ note: Notification) {
            guard !finished, let f = note.object as? NSTextField else { return }
            finished = true; parent.commit(f.stringValue) // clicking elsewhere keeps what was typed, as in the Finder
        }
    }
}

#if SPD_DEV
// MARK: Driving the interface from inside the app (development checks)
/// Finds controls of this app's own windows through the system accessibility API addressed to its own process, and
/// presses them — what a person's click does, without a pointer and without touching any other app. (SwiftUI only
/// builds its accessibility tree for a client of that API; asking the views directly returns nothing.)
@MainActor enum AX {
    private static let app = AXUIElementCreateApplication(getpid())
    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func identifier(_ e: AXUIElement) -> String { (attr(e, kAXIdentifierAttribute) as? String) ?? "" }
    static func label(_ e: AXUIElement) -> String { (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "" }
    /// Windows of the app, the small ones first (sheets, settings, panels): what a check presses is usually there, and the
    /// main window can hold thousands of cells.
    private static var windows: [AXUIElement] {
        let all = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return all.sorted { (attr($0, kAXMainAttribute) as? Bool ?? false ? 1 : 0) < (attr($1, kAXMainAttribute) as? Bool ?? false ? 1 : 0) }
    }
    /// Breadth-first, each element once, and never more than `budget` elements: an accessibility tree may contain
    /// cross-references, and a walk without these limits was seen spinning for minutes.
    private static func walk(_ root: AXUIElement, budget: Int = 6000, _ visit: (AXUIElement) -> Bool) -> Bool {
        var queue = [root], seen: Set<AXUIElement> = [root], index = 0
        while index < queue.count, index < budget {
            let e = queue[index]; index += 1
            if visit(e) { return true }
            for c in children(e) where seen.insert(c).inserted { queue.append(c) }
        }
        return false
    }
    static func find(where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var hit: AXUIElement?
        for w in windows { if walk(w, { if match($0) { hit = $0; return true }; return false }) { break } }
        return hit
    }
    static func element(id: String) -> AXUIElement? { find { identifier($0) == id } }
    static func element(labelPrefix: String) -> AXUIElement? { find { label($0).hasPrefix(labelPrefix) } }
    static func count(id: String) -> Int { var n = 0; for w in windows { _ = walk(w, { if identifier($0) == id { n += 1 }; return false }) }; return n }
    /// True when the API answers for this process at all (it needs no permission for one's own process, but a sandbox could refuse it).
    static var available: Bool { !windows.isEmpty }
    @discardableResult static func press(_ e: AXUIElement?) -> Bool { guard let e else { return false }; return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
}
#endif
