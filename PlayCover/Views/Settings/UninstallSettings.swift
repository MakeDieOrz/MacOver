//
//  UninstallSettings.swift
//  PlayCover
//

import SwiftUI

struct UninstallSettings: View {
    @Environment(UninstallPreferences.self) var uninstallPreferences
    @Environment(AppsVM.self) var appsVM

    @State private var showPruneFileAlert = false

    var body: some View {
        @Bindable var uninstallPreferences = uninstallPreferences
        Form {
            Section("preferences.whenUninstalling") {
                Toggle("preferences.toggle.showUninstall", isOn: $uninstallPreferences.showUninstallPopup)
                Toggle("preferences.toggle.clearAppData", isOn: $uninstallPreferences.clearAppData)
                Toggle("preferences.toggle.removeKeymap", isOn: $uninstallPreferences.removeAppKeymap)
                Toggle("preferences.toggle.removeSetting", isOn: $uninstallPreferences.removeAppSettings)
                Toggle("preferences.toggle.removeNetworkRules", isOn: $uninstallPreferences.removeAppNetworkRules)
                Toggle("preferences.toggle.removeEntitlements", isOn: $uninstallPreferences.removeAppEntitlements)
                Toggle("preferences.toggle.removePlayChain", isOn: $uninstallPreferences.removePlayChain)
            }

            Section {
                Button("preferences.button.pruneFiles", role: .destructive) {
                    showPruneFileAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .alert("preferences.prune.alert", isPresented: $showPruneFileAlert) {
            Button("preferences.button.pruneFiles", role: .destructive) {
                Uninstaller.pruneFiles(appsVM: appsVM)
            }
            Button("button.Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("preferences.prune.message")
        }
    }
}
