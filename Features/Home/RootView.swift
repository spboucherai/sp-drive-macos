// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Features/Home/RootView.swift
// Description: Root of the window: launching, sign-in, the main interface, and the lock screen above it when the biometric lock is on.
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            switch model.phase {
            case .launching: ProgressView().controlSize(.large)
            case .signedOut: LoginView()
            case .signedIn: MainView()
            }
            if model.locked, model.phase == .signedIn { LockedView().transition(.opacity) }
        }
        .animation(.default, value: model.phase)
        .animation(.default, value: model.locked)
    }
}
