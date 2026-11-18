// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/Notifier.swift
// Description: System notifications for what deserves attention — a batch of transfers finished, a conflict to settle, a sync error that persists, storage running out, a deposit received — never one per small operation. macOS notification preferences are respected.
import Foundation
import UserNotifications

@MainActor final class Notifier {
    private let center = UNUserNotificationCenter.current()
    private var asked = false
    func requestAuthorization() {
        guard !asked else { return }; asked = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    /// Posts a notification; `id` replaces an earlier one about the same thing instead of piling up.
    func post(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in }
    }
}
