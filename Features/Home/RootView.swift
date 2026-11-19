// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/RootView.swift
// Description: Root of one window: its own navigator, then launching, sign-in, the main interface, and the lock screen above it when the biometric lock is on. Several windows can be open on the same account.
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var nav: Navigator?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ZStack {
            if let nav {
                switch model.phase {
                case .launching: ProgressView().controlSize(.large)
                case .signedOut: LoginView()
                case .signedIn: MainView().environment(nav).focusedSceneValue(\.spdNavigator, nav)
                }
                if model.locked, model.phase == .signedIn { LockedView().transition(.opacity) }
            }
        }
        .spdMotion(.reveal, value: model.phase)
        .spdMotion(.reveal, value: model.locked)
        .onAppear {
            if nav == nil { nav = model.claimNavigator() }; if model.activeNav == nil { model.activeNav = nav }
            AppDelegate.openAskWindow = { openWindow(id: "ask") }; AppDelegate.openSettings = { openSettings() }
        }
        .background(WindowReader { w in
            guard let w else { return }
            if w.isKeyWindow, let nav { model.activeNav = nav }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in MainActor.assumeIsolated { if let nav = self.nav { model.activeNav = nav } } }
        })
        .onDisappear { if let nav { model.releaseNavigator(nav) } }
    }
}
