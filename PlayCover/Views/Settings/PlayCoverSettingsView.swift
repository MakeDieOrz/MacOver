//
//  PlayCoverSettingsView.swift
//  PlayCover
//

import PlayCoverSandbox
import Sparkle
import SwiftUI

struct PlayCoverSettingsView: View {
    var updaterViewModel: UpdaterViewModel
    @Environment(StoreVM.self) var storeVM

    var body: some View {
        TabView {
            Tab("settings.tab.general", systemImage: "gearshape") {
                GeneralSettingsTab()
            }

            Tab("settings.tab.signing", systemImage: "lock.shield") {
                SigningSettingsTab()
            }

            Tab("preferences.tab.updates", systemImage: "square.and.arrow.down") {
                UpdateSettings(updaterViewModel: updaterViewModel)
            }

            Tab("preferences.tab.ipasource", systemImage: "list.bullet") {
                IPASourceSettings()
                    .environment(storeVM)
            }

            Tab("KeyCover", systemImage: "key.fill") {
                KeyCoverSettings()
            }

            Tab("preferences.tab.install", systemImage: "arrow.down.app") {
                InstallSettings()
            }

            Tab("preferences.tab.uninstall", systemImage: "trash.square") {
                UninstallSettings()
            }
        }
        .frame(minWidth: 580, minHeight: 340)
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        Form {
            Section("settings.general.appearance") {
                Text("settings.general.glassNote")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("settings.general.menuBarExtra", isOn: $showMenuBarExtra)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SigningSettingsTab: View {
    @State private var status: PrivilegePreFlightStatus?
    @State private var showGuide = false

    var body: some View {
        Form {
            Section("signing.guide.title") {
                LabeledContent("configSigning.info.SIPHeader") {
                    if let status {
                        Text(status.sipDisabled ? "state.disabled" : "state.enabled")
                            .foregroundStyle(status.sipDisabled ? .orange : .green)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("configSigning.info.AMFIHeader") {
                    if let status {
                        Text(status.amfiDisabledInRunningOS
                             ? "state.disabled"
                             : (status.amfiDisabledInNVRAM ? "state.pendingReboot" : "state.enabled"))
                            .foregroundStyle(status.amfiDisabledInRunningOS ? .blue : .secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Button("menubar.configSigning") {
                    showGuide = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .task(id: showGuide) {
            let refreshed = await Task.detached(priority: .utility) {
                SystemConfig.preFlightStatus()
            }.value
            status = refreshed
        }
        .sheet(isPresented: $showGuide) {
            SigningGuideView(isSigningSetupShown: $showGuide)
        }
    }
}
