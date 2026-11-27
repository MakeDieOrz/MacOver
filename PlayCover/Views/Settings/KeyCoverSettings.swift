//
//  KeyCoverSettings.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import SwiftUI

struct KeyCoverSettings: View {
    @State private var keyCoverInitialSetupShown = false
    @State private var keyCoverUpdatePasswordShown = false
    @State private var keyCoverRemovalViewShown = false
    @State private var showForceResetAlert = false

    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(KeyCoverPreferences.self) var keyCoverPreferences
    @Environment(KeyCoverObservable.self) var keyCoverObserved

    private var statusTextKey: LocalizedStringKey {
        guard keyCoverObserved.keyCoverEnabled else { return "state.disabled" }
        return keyCoverPreferences.keyCoverEnabled == .selfGeneratedPassword
            ? "keycover.status.managedPassword"
            : "keycover.status.userPassword"
    }

    var body: some View {
        @Bindable var keyCoverPreferences = keyCoverPreferences
        Form {
            Section {
                LabeledContent("keycover.status.title") {
                    HStack(spacing: 10) {
                        Text(statusTextKey)
                            .fontWeight(.medium)
                            .foregroundStyle(keyCoverObserved.keyCoverEnabled ? .green : .secondary)

                        if keyCoverObserved.keyCoverEnabled {
                            Button("button.Reset") {
                                keyCoverRemovalViewShown = true
                            }
                        } else {
                            Button("button.Enable") {
                                keyCoverInitialSetupShown = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                LabeledContent("keycover.status.chainCount") {
                    HStack(spacing: 10) {
                        Text(String(
                            format: NSLocalizedString("keycover.status.unlockedCount %@ %@", comment: ""),
                            "\(keyCoverObserved.unlockedCount)",
                            "\(keyCoverObserved.keychains.count)"
                        ))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                        Button("keycover.button.lockAll") {
                            dependencies.keyCover.lockAllChainsAsync()
                        }
                        .disabled(!keyCoverObserved.keyCoverEnabled)
                    }
                }
            }

            Section {
                Toggle("keycover.toggle.startupPrompt", isOn: $keyCoverPreferences.promptForKeyCoverPasswordAtLaunch)
                    .help("keycover.toggle.startupPrompt.help")

                Button("keycover.button.changePassword") {
                    keyCoverUpdatePasswordShown = true
                }
                .disabled(!keyCoverObserved.keyCoverEnabled)
            }

            if keyCoverObserved.keyCoverEnabled {
                Section {
                    Button("keycover.forceReset.confirm", role: .destructive) {
                        showForceResetAlert = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $keyCoverInitialSetupShown) {
            KeyCoverInitialSetupView(isPresented: $keyCoverInitialSetupShown)
                .environment(dependencies)
        }
        .sheet(isPresented: $keyCoverUpdatePasswordShown) {
            KeyCoverUpdatePasswordView(isPresented: $keyCoverUpdatePasswordShown)
                .environment(dependencies)
        }
        .sheet(isPresented: $keyCoverRemovalViewShown) {
            KeyCoverRemovalView(isPresented: $keyCoverRemovalViewShown)
                .environment(dependencies)
        }
        .alert("keycover.forceReset.title", isPresented: $showForceResetAlert) {
            Button("keycover.forceReset.confirm", role: .destructive) {
                dependencies.keyCoverPassword.forceResetKeyCoverPassword()
            }
            Button("button.Cancel", role: .cancel) {}
        } message: {
            Text("keycover.forceReset.message")
        }
    }
}

struct KeyCoverSettings_Previews: PreviewProvider {
    static var previews: some View {
        KeyCoverSettings()
    }
}
