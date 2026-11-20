//
//  UpdateSettings.swift
//  PlayCover
//

import Sparkle
import SwiftUI

struct UpdateSettings: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel
    @AppStorage("SUEnableAutomaticChecks") var autoUpdate = false

    var body: some View {
        Form {
            Section {
                Toggle("preferences.toggle.automaticUpdates", isOn: $autoUpdate)
                Button("preferences.button.checkForUpdates") {
                    updaterViewModel.checkForUpdates()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: autoUpdate) { _, value in
            updaterViewModel.automaticallyCheckForUpdates = value
        }
    }
}
