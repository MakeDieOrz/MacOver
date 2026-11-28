//
//  KeyCoverViews.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import SwiftUI

struct KeyCoverInitialSetupView: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Binding var isPresented: Bool

    @State private var keyCoverPassword = ""
    @State private var keyCoverPasswordConfirmed = ""
    @State private var isEncrypting = false

    @State private var keyCoverPasswordError = false
    @State private var keyCoverConfirmError = false
    @State private var saveFailedError = false

    @State private var keyOption = KeyCoverStatus.selfGeneratedPassword

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("keycover.setupPrompt.title")
                .font(.headline)

            Picker("keycover.setup.encryptionKey", selection: $keyOption) {
                Text("keycover.setup.useGeneratedKey")
                    .tag(KeyCoverStatus.selfGeneratedPassword)
                Text("keycover.setup.useUserKey")
                    .tag(KeyCoverStatus.userProvidedPassword)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: keyOption) { _, newValue in
                keyCoverPasswordError = false
                keyCoverConfirmError = false
                saveFailedError = false
                switch newValue {
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

            VStack(alignment: .leading, spacing: 8) {
                SecureField("keycover.masterPassword", text: $keyCoverPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("keycover.confirmMasterPassword", text: $keyCoverPasswordConfirmed)
                    .textFieldStyle(.roundedBorder)
                if keyCoverPasswordError {
                    Text("keycover.error.blankPassword")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if keyCoverConfirmError {
                    Text("keycover.error.notMatch")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .disabled(keyOption != .userProvidedPassword)

            if saveFailedError {
                Text("keycover.error.saveFailed")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                if isEncrypting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("button.OK") {
                    keyCoverPasswordError = false
                    keyCoverConfirmError = false
                    saveFailedError = false
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
                            passwordStore.setKeyCoverPassword(newPassword, mode: selectedOption)
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
                            dependencies.keyCoverObservable.update()
                            isPresented = false
                        } else {
                            saveFailedError = true
                            log.error("Failed to store KeyCover password configuration.")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isEncrypting)
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if keyOption == .selfGeneratedPassword && keyCoverPassword.isEmpty {
                keyCoverPassword = dependencies.keyCoverPassword.generateVerySecurePassword()
                keyCoverPasswordConfirmed = keyCoverPassword
            }
        }
    }
}

struct KeyCoverUpdatePasswordView: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Binding var isPresented: Bool

    @State private var oldKeyCoverPassword = ""
    @State private var keyCoverPassword = ""
    @State private var keyCoverPasswordConfirm = ""
    @State private var isWorking = false

    @State private var oldKeyCoverPasswordError = false
    @State private var keyCoverPasswordError = false
    @State private var keyCoverPasswordConfirmError = false
    @State private var saveFailedError = false

    @State private var keyOption = KeyCoverStatus.userProvidedPassword

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("keycover.changePasswordPrompt.title")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("keycover.oldMasterPassword", text: $oldKeyCoverPassword)
                .textFieldStyle(.roundedBorder)
                .disabled(dependencies.keyCoverPreferences.keyCoverEnabled == .selfGeneratedPassword)

            Picker("keycover.setup.encryptionKey", selection: $keyOption) {
                Text("keycover.setup.useGeneratedKey")
                    .tag(KeyCoverStatus.selfGeneratedPassword)
                Text("keycover.setup.useUserKey")
                    .tag(KeyCoverStatus.userProvidedPassword)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: keyOption) { _, newValue in
                keyCoverPasswordError = false
                keyCoverPasswordConfirmError = false
                saveFailedError = false
                switch newValue {
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

            VStack(alignment: .leading, spacing: 8) {
                SecureField("keycover.masterPassword", text: $keyCoverPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("keycover.confirmMasterPassword", text: $keyCoverPasswordConfirm)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(keyOption != .userProvidedPassword)

            if oldKeyCoverPasswordError {
                Text("keycover.error.incorrectPassword")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if keyCoverPasswordError {
                Text("keycover.error.blankPassword")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if keyCoverPasswordConfirmError {
                Text("keycover.error.notMatch")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if saveFailedError {
                Text("keycover.error.saveFailed")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
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
                    saveFailedError = false

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

                        let currentMode = preferences.keyCoverEnabled
                        let resolvedOld: String?
                        if currentMode == .selfGeneratedPassword {
                            resolvedOld = await Task.detached(priority: .userInitiated) {
                                oldPassword.isEmpty
                                    ? passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true)
                                    : oldPassword
                            }.value
                            let requiresOld = await Task.detached(priority: .userInitiated) {
                                passwordStore.hasLocalRecord()
                                    || passwordStore.hasEncryptedChains()
                            }.value
                            if requiresOld {
                                guard let resolvedOld, !resolvedOld.isEmpty else {
                                    oldKeyCoverPasswordError = true
                                    return
                                }
                                let validManaged = await Task.detached(priority: .userInitiated) {
                                    passwordStore.hasLocalRecord() ? passwordStore.validatePassword(resolvedOld) : true
                                }.value
                                if !validManaged {
                                    oldKeyCoverPasswordError = true
                                    return
                                }
                            }
                        } else {
                            let validOld = await Task.detached(priority: .userInitiated) {
                                passwordStore.validatePassword(oldPassword)
                            }.value
                            if !validOld {
                                oldKeyCoverPasswordError = true
                                return
                            }
                            resolvedOld = oldPassword
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
                            passwordStore.setKeyCoverPassword(
                                newPassword,
                                mode: selectedOption,
                                currentPassword: resolvedOld
                            )
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
                            dependencies.keyCoverObservable.update()
                            isPresented = false
                        } else {
                            saveFailedError = true
                            log.error("Failed to update KeyCover password configuration.")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isWorking)
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if dependencies.keyCoverPreferences.keyCoverEnabled == .selfGeneratedPassword {
                oldKeyCoverPassword = dependencies.keyCover.keyCoverPlainTextKey ?? ""
            }
        }
    }
}

struct KeyCoverRemovalView: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Binding var isPresented: Bool

    @State private var keyCoverPassword = ""
    @State private var isWorking = false

    @State private var keyCoverPasswordError = false

    @State private var keyOption = KeyCoverStatus.disabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("keycover.removePrompt.title")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("keycover.masterPassword", text: $keyCoverPassword)
                .textFieldStyle(.roundedBorder)
                .disabled(keyOption == .selfGeneratedPassword)

            if keyCoverPasswordError {
                Text("keycover.error.incorrectPassword")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("button.OK") {
                    keyCoverPasswordError = false
                    let password = keyCoverPassword
                    let currentOption = keyOption
                    let passwordStore = dependencies.keyCoverPassword
                    Task { @MainActor in
                        isWorking = true
                        defer { isWorking = false }

                        if currentOption == .selfGeneratedPassword {
                            let removed = await Task.detached(priority: .userInitiated) {
                                passwordStore.removeKeyCoverPassword(
                                    currentPassword: password.isEmpty ? nil : password
                                )
                            }.value
                            if removed {
                                isPresented = false
                            } else {
                                keyCoverPasswordError = true
                            }
                            return
                        }

                        let valid = await Task.detached(priority: .userInitiated) {
                            passwordStore.validatePassword(password)
                        }.value
                        if !valid {
                            keyCoverPasswordError = true
                            return
                        }

                        let removed = await Task.detached(priority: .userInitiated) {
                            passwordStore.removeKeyCoverPassword(currentPassword: password)
                        }.value
                        if removed {
                            isPresented = false
                        } else {
                            keyCoverPasswordError = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isWorking)
        .padding(20)
        .frame(width: 440)
        .onAppear {
            keyOption = dependencies.keyCoverPreferences.keyCoverEnabled
            if keyOption == .selfGeneratedPassword {
                keyCoverPassword = dependencies.keyCover.keyCoverPlainTextKey ?? ""
            }
        }
    }
}
