// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/AppDelegate.swift
// Description: Application lifecycle: SP Drive keeps syncing from the menu bar when its window is closed, resumes after sleep, and re-locks after a period away when the biometric lock is on.
import AppKit
import Quartz

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// Opens the main window (set by the views, which own SwiftUI's window actions).
    static var openMainWindow: (() -> Void)?
    private var hasMainWindow: Bool { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }
    /// Brings a main window forward, opening one when none is left.
    static func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }

    // The Quick Look panel looks for its controller along the responder chain, which ends here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { QuickLookCoordinator.shared.adopt(panel) } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { QuickLookCoordinator.shared.release(panel) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model?.engine?.transfers.kick(); await self?.model?.syncNow() } // back from sleep: look at the server now
        }
        // a launch by the person shows the window even when the system restored none; a launch at login stays in the menu bar
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in if self?.hasMainWindow == false { AppDelegate.openMainWindow?() } } }
    }
    /// Closing the window does not stop syncing: the menu bar item stays (unless the person hid it, then the app quits with its last window).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(model?.settings.showMenuBarIcon ?? true) }
    func applicationDidBecomeActive(_ notification: Notification) { model?.appBecameActive() }
    func applicationDidResignActive(_ notification: Notification) { model?.appResignedActive() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !hasMainWindow, let open = AppDelegate.openMainWindow { open(); return false }
        return true
    }
}
