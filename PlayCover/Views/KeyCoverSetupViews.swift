//
//  KeyCoverViews.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import SwiftUI

struct KeyCoverInitialSetupView: View {
    @EnvironmentObject var dependencies: PlayCoverDependencies
    @Binding var isPresented: Bool

    @State private var keyCoverPassword = ""
    @State private var keyCoverPasswordConfirmed = ""
    @State private var isEncrypting = false

    @State private var keyCoverPasswordError = false
    @State private var keyCoverConfirmError = false

    @State private var keyOption = KeyCoverStatus.disabled

    var body: some View {
        Picker("keycover.setup.encryptionKey", selection: $keyOption) {
            Text("keycover.setup.useGeneratedKey")
                .tag(KeyCoverStatus.selfGeneratedPassword)
            Text("keycover.setup.useUserKey")
                .tag(KeyCoverStatus.userProvidedPassword)
        }
        .pickerStyle(RadioGroupPickerStyle())
        .padding()
        .onChange(of: keyOption) { _ in
            switch keyOption {
            case .selfGeneratedPassword:
                keyCoverPassword = dependencies.keyCoverPassword.generateVerySecurePassword()
                keyCoverPasswordConfirmed = keyCoverPassword
            case .userProvidedPassword:
                keyCoverPassword = ""
                keyCoverPasswordConfirmed = ""
            case .disabled:
                break
            }
        }

        VStack {
            Group {
                Text("keycover.setupPrompt.title")
                    .bold()
                SecureField("keycover.masterPassword", text: $keyCoverPassword)
                SecureField("keycover.confirmMasterPassword", text: $keyCoverPasswordConfirmed)
                if keyCoverPasswordError {
                    Text("keycover.error.blankPassword")
                        .foregroundColor(.red)
                }
                if keyCoverConfirmError {
                    Text("keycover.error.notMatch")
                        .foregroundColor(.red)
                }
            }
            .disabled(keyOption != .userProvidedPassword)
            Divider()
            HStack {
                // Spinner to indicate that data is being encrypted
                if isEncrypting {
                    ProgressView()
                        .padding()
                        .progressViewStyle(.linear)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.OK") {
                    keyCoverPasswordError = false
                    keyCoverConfirmError = false
                    if keyCoverPassword.isEmpty {
                        keyCoverPasswordError = true
                        return
                    }
                    if keyCoverPassword != keyCoverPasswordConfirmed {
                        keyCoverConfirmError = true
                        return
                    }

                    let selectedOption = keyOption
                    let newPassword = keyCoverPassword
                    let passwordStore = dependencies.keyCoverPassword
                    let preferences = dependencies.keyCoverPreferences
                    let log = dependencies.log
                    Task { @MainActor in
                        isEncrypting = true
                        defer { isEncrypting = false }

                        let succeeded = await Task.detached(priority: .userInitiated) {
                            passwordStore.setKeyCoverPassword(newPassword)
                        }.value

                        if succeeded {
                            switch selectedOption {
                            case .userProvidedPassword:
                                preferences.keyCoverEnabled = .userProvidedPassword
                            case .selfGeneratedPassword:
                                preferences.keyCoverEnabled = .selfGeneratedPassword
                            case .disabled:
                                break
                            }
                            isPresented = false
                        } else {
                            log.error("Failed to store KeyCover master password in Keychain.")
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isEncrypting)
        .padding()

    }
}

struct KeyCoverUpdatePasswordView: View {
    @EnvironmentObject var dependencies: PlayCoverDependencies
    @Binding var isPresented: Bool

    @State private var oldKeyCoverPassword = ""
    @State private var keyCoverPassword = ""
    @State private var keyCoverPasswordConfirm = ""
    @State private var isWorking = false

    @State private var oldKeyCoverPasswordError = false
    @State private var keyCoverPasswordError = false
    @State private var keyCoverPasswordConfirmError = false

    @State private var keyOption = KeyCoverStatus.userProvidedPassword

    var body: some View {
        VStack {
            Text("keycover.changePasswordPrompt.title")
                .bold()
            SecureField("keycover.oldMasterPassword", text: $oldKeyCoverPassword)
            .disabled(dependencies.keyCoverPreferences.keyCoverEnabled == .selfGeneratedPassword)

            Picker("keycover.setup.encryptionKey", selection: $keyOption) {
                Text("keycover.setup.useGeneratedKey")
                    .tag(KeyCoverStatus.selfGeneratedPassword)
                Text("keycover.setup.useUserKey")
                    .tag(KeyCoverStatus.userProvidedPassword)
            }
            .pickerStyle(RadioGroupPickerStyle())
            .padding()
            .onChange(of: keyOption) { _ in
                switch keyOption {
                case .selfGeneratedPassword:
                    keyCoverPassword = dependencies.keyCoverPassword.generateVerySecurePassword()
                    keyCoverPasswordConfirm = keyCoverPassword
                case .userProvidedPassword:
                    keyCoverPassword = ""
                    keyCoverPasswordConfirm = ""
                case .disabled:
                    break
                }
            }

            Group {
                SecureField("keycover.masterPassword", text: $keyCoverPassword)
                SecureField("keycover.confirmMasterPassword", text: $keyCoverPasswordConfirm)
                if oldKeyCoverPasswordError {
                    Text("keycover.error.incorrectPassword")
                        .foregroundColor(.red)
                        .padding()
                }
                if keyCoverPasswordError {
                    Text("keycover.error.blankPassword")
                        .foregroundColor(.red)
                        .padding()
                }
                if keyCoverPasswordConfirmError {
                    Text("keycover.error.notMatch")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .disabled(keyOption != .userProvidedPassword)
            Divider()
            HStack {
                if isWorking {
                    ProgressView()
                        .padding()
                        .progressViewStyle(.linear)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.OK") {
                    oldKeyCoverPasswordError = false
                    keyCoverPasswordError = false
                    keyCoverPasswordConfirmError = false

                    let oldPassword = oldKeyCoverPassword
                    let newPassword = keyCoverPassword
                    let confirmPassword = keyCoverPasswordConfirm
                    let selectedOption = keyOption
                    let passwordStore = dependencies.keyCoverPassword
                    let preferences = dependencies.keyCoverPreferences
                    let log = dependencies.log

                    Task { @MainActor in
                        isWorking = true
                        defer { isWorking = false }

                        let validOld = await Task.detached(priority: .userInitiated) {
                            passwordStore.validatePassword(oldPassword)
                        }.value
                        if !validOld {
                            oldKeyCoverPasswordError = true
                            return
                        }
                        if newPassword.isEmpty {
                            keyCoverPasswordError = true
                            return
                        }
                        if newPassword != confirmPassword {
                            keyCoverPasswordConfirmError = true
                            return
                        }

                        let succeeded = await Task.detached(priority: .userInitiated) {
                            passwordStore.setKeyCoverPassword(newPassword)
                        }.value

                        if succeeded {
                            switch selectedOption {
                            case .userProvidedPassword:
                                preferences.keyCoverEnabled = .userProvidedPassword
                            case .selfGeneratedPassword:
                                preferences.keyCoverEnabled = .selfGeneratedPassword
                            case .disabled:
                                break
                            }
                            isPresented = false
                        } else {
                            log.error("Failed to update KeyCover master password in Keychain.")
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isWorking)
        .padding()
        .onAppear {
            if dependencies.keyCoverPreferences.keyCoverEnabled == .selfGeneratedPassword {
                oldKeyCoverPassword = dependencies.keyCover.keyCoverPlainTextKey ?? ""
            }
        }
    }
}

struct KeyCoverRemovalView: View {
    @EnvironmentObject var dependencies: PlayCoverDependencies
    @Binding var isPresented: Bool

    @State private var keyCoverPassword = ""
    @State private var isWorking = false

    @State private var keyCoverPasswordError = false

    @State private var keyOption = KeyCoverStatus.disabled

    var body: some View {
        VStack {
            Text("keycover.removePrompt.title")
                .bold()
            SecureField("keycover.masterPassword", text: $keyCoverPassword)
            .disabled(keyOption == .selfGeneratedPassword)
            if keyCoverPasswordError {
                Text("keycover.error.incorrectPassword")
                    .foregroundColor(.red)
                    .padding()
            }
            Divider()
            HStack {
                if isWorking {
                    ProgressView()
                        .padding()
                        .progressViewStyle(.linear)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.OK") {
                    keyCoverPasswordError = false
                    let password = keyCoverPassword
                    let passwordStore = dependencies.keyCoverPassword
                    Task { @MainActor in
                        isWorking = true
                        defer { isWorking = false }

                        let valid = await Task.detached(priority: .userInitiated) {
                            passwordStore.validatePassword(password)
                        }.value
                        if !valid {
                            keyCoverPasswordError = true
                            return
                        }

                        await Task.detached(priority: .userInitiated) {
                            passwordStore.removeKeyCoverPassword()
                        }.value
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isWorking)
        .padding()
        .onAppear {
            keyOption = dependencies.keyCoverPreferences.keyCoverEnabled
            if keyOption == .selfGeneratedPassword {
                keyCoverPassword = dependencies.keyCover.keyCoverPlainTextKey ?? ""
            }
        }
    }
}
