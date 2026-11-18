// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/Settings.swift
// Description: The person's preferences (Finder integration, notifications, bandwidth limits, parallel transfers, biometric lock), kept in the shared defaults.
import Foundation
import Observation

@MainActor @Observable final class AppSettings {
    private let d = AppEnvironment.defaults
    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    /// SP Drive appears as a location in the Finder.
    var finderIntegration: Bool { didSet { d.set(finderIntegration, forKey: "finderIntegration") } }
    var notifyTransfers: Bool { didSet { d.set(notifyTransfers, forKey: "notifyTransfers") } }
    var notifyConflicts: Bool { didSet { d.set(notifyConflicts, forKey: "notifyConflicts") } }
    var notifyDeposits: Bool { didSet { d.set(notifyDeposits, forKey: "notifyDeposits") } }
    /// Kilobytes per second; 0 = no limit.
    var uploadLimitKB: Int { didSet { d.set(uploadLimitKB, forKey: "uploadLimitKB") } }
    var downloadLimitKB: Int { didSet { d.set(downloadLimitKB, forKey: "downloadLimitKB") } }
    /// 0 = adapt to the measured link.
    var parallelTransfers: Int { didSet { d.set(parallelTransfers, forKey: "parallelTransfers") } }
    /// Ask for Touch ID (or the Mac's password) to show the window.
    var biometricLock: Bool { didSet { d.set(biometricLock, forKey: "biometricLock") } }
    var syncPaused: Bool { didSet { d.set(syncPaused, forKey: "syncPaused") } }
    var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var gridView: Bool { didSet { d.set(gridView, forKey: "gridView") } }

    init() {
        let d = AppEnvironment.defaults
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        finderIntegration = b("finderIntegration", true); notifyTransfers = b("notifyTransfers", true); notifyConflicts = b("notifyConflicts", true); notifyDeposits = b("notifyDeposits", true)
        uploadLimitKB = d.integer(forKey: "uploadLimitKB"); downloadLimitKB = d.integer(forKey: "downloadLimitKB"); parallelTransfers = d.integer(forKey: "parallelTransfers")
        biometricLock = b("biometricLock", false); syncPaused = b("syncPaused", false); showMenuBarIcon = b("showMenuBarIcon", true); gridView = b("gridView", false)
    }
}
