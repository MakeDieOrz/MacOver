//
//  UpdateSettings.swift
//  PlayCover
//

import Sparkle
import SwiftUI

struct UpdateSettings: View {
    var updaterViewModel: UpdaterViewModel

    var body: some View {
        @Bindable var updaterViewModel = updaterViewModel
        Form {
            Section {
                Toggle(
                    "preferences.toggle.automaticUpdates",
                    isOn: $updaterViewModel.automaticallyCheckForUpdates
                )
                .disabled(!updaterViewModel.isUpdateVerificationConfigured)

                Button("preferences.button.checkForUpdates") {
                    updaterViewModel.checkForUpdates()
                }
                .disabled(!updaterViewModel.canCheckForUpdates)

                if !updaterViewModel.isUpdateVerificationConfigured {
                    Label("preferences.updates.unsignedDisabledNote", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}
