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

    @EnvironmentObject var dependencies: PlayCoverDependencies
    @EnvironmentObject var keyCoverPreferences: KeyCoverPreferences
    @EnvironmentObject var keyCoverObserved: KeyCoverObservable
    @EnvironmentObject var modifierKeyObserver: ModifierKeyObserver

    var body: some View {
        VStack {
            HStack {
                HStack {
                    Text("keycover.status.title")
                    Text(keyCoverObserved.keyCoverEnabled ?
                             keyCoverPreferences.keyCoverEnabled == .selfGeneratedPassword ?
                             "keycover.status.managedPassword" : "keycover.status.userPassword"
                         : "state.disabled")
                        .foregroundColor(keyCoverObserved.keyCoverEnabled ? .green : .none)
                    Spacer()
                }
                Spacer()
                Button(keyCoverObserved.keyCoverEnabled ? "button.Reset" : "button.Enable") {
                    if keyCoverObserved.keyCoverEnabled {
                        if modifierKeyObserver.isOptionKeyPressed {
                            dependencies.keyCoverPassword.forceResetKeyCoverPassword()
                        } else {
                            keyCoverRemovalViewShown = true
                        }
                    } else {
                        keyCoverInitialSetupShown = true
                    }
                }
                .foregroundColor((keyCoverObserved.keyCoverEnabled
                                 && modifierKeyObserver.isOptionKeyPressed)
                                    ? .red : .none)
            }
            .padding()
            Spacer()
            HStack {
                VStack(alignment: .leading) {
                    Text("keycover.status.chainCount")
                    Text(String(format: NSLocalizedString("keycover.status.unlockedCount %@ %@", comment: ""),
                                "\(keyCoverObserved.unlockedCount)",
                                "\(keyCoverObserved.keychains.count)"))
                }
                Spacer()
                Button("keycover.button.lockAll") {
                    dependencies.keyCover.lockAllChainsAsync()
                }
                .disabled(!keyCoverObserved.keyCoverEnabled)
            }
            .padding()
            HStack {
                Spacer()
                Button("keycover.button.changePassword") {
                    keyCoverUpdatePasswordShown = true
                }
                .disabled(!keyCoverObserved.keyCoverEnabled)
                Spacer()
            }
            .padding()
            VStack(alignment: .leading) {
                Toggle("keycover.toggle.startupPrompt", isOn: $keyCoverPreferences.promptForKeyCoverPasswordAtLaunch)
                    .help("keycover.toggle.startupPrompt.help")
                Spacer()
            }
            .padding()
        }
        .frame(width: 600, height: 300)
        .sheet(isPresented: $keyCoverInitialSetupShown) {
            KeyCoverInitialSetupView(isPresented: $keyCoverInitialSetupShown)
                .environmentObject(dependencies)
        }
        .sheet(isPresented: $keyCoverUpdatePasswordShown) {
            KeyCoverUpdatePasswordView(isPresented: $keyCoverUpdatePasswordShown)
                .environmentObject(dependencies)
        }
        .sheet(isPresented: $keyCoverRemovalViewShown) {
            KeyCoverRemovalView(isPresented: $keyCoverRemovalViewShown)
                .environmentObject(dependencies)
        }
    }
}

struct KeyCoverSettings_Previews: PreviewProvider {
    static var previews: some View {
        KeyCoverSettings()
    }
}
