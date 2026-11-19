// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/SPDriveApp.swift
// Description: Entry point of SP Drive: main windows (several can be open on the same account), the settings window and the menu bar Command Center, all on one model.
import CoreSpotlight
import SwiftUI

@main
struct SPDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(AppEnvironment.productName, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 540)
                .task { delegate.model = model; await model.bootstrap() }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.reveal(itemID: id) } // a Spotlight result of SP Drive
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model, bridge: model.menuBridge) }

        Settings { SettingsView().environment(model) }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarIcon }, set: { model.settings.showMenuBarIcon = $0 })) {
            MenuBarView().environment(model)
        } label: { MenuBarLabel().environment(model) }
        .menuBarExtraStyle(.window)
    }
}
