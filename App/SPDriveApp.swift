// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/SPDriveApp.swift
// Description: Entry point of SP Drive: the main window, the settings window and the menu bar item, all on one model.
import SwiftUI

@main
struct SPDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window(AppEnvironment.productName, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 520)
                .task { delegate.model = model; await model.bootstrap() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        Settings { SettingsView().environment(model) }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarIcon }, set: { model.settings.showMenuBarIcon = $0 })) {
            MenuBarView().environment(model)
        } label: { MenuBarLabel().environment(model) }
        .menuBarExtraStyle(.window)
    }
}
