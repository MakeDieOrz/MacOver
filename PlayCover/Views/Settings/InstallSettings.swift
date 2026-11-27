//
//  InstallSettings.swift
//  PlayCover
//

import SwiftUI

struct InstallSettings: View {
    @Environment(InstallPreferences.self) var installPreferences

    var body: some View {
        @Bindable var installPreferences = installPreferences
        Form {
            Section {
                Picker("settings.applicationCategoryType", selection: $installPreferences.defaultAppType) {
                    ForEach(LSApplicationCategoryType.allCases, id: \.rawValue) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                Toggle("preferences.toggle.showAppStorePopup", isOn: $installPreferences.showAppStorePopup)
            }

            Section {
                Toggle("preferences.toggle.showInstallPopup", isOn: $installPreferences.showInstallPopup)
                Toggle("preferences.toggle.alwaysInstallPlayTools", isOn: $installPreferences.alwaysInstallPlayTools)
                    .disabled(installPreferences.showInstallPopup)
            }
        }
        .formStyle(.grouped)
    }
}
