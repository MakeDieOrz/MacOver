//
//  KeyCoverViews.swift
//  PlayCover
//
//  Created by Venti on 01/02/2023.
//

import SwiftUI

struct KeyCoverUnlockingPrompt: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(KeyCoverObservable.self) var keyCoverObserved

    @State private var password = ""
    @State private var passwordError = false
    @State private var isUnlocking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("keycover.unlockPrompt.title")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("keycover.masterPassword", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(isUnlocking)
                .onSubmit {
                    unlock()
                }

            if passwordError {
                Text("keycover.error.incorrectPassword")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(spacing: 10) {
                if isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("button.Cancel") {
                    keyCoverObserved.isKeyCoverUnlockingPromptShown = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isUnlocking)

                Button("button.Unlock") {
                    unlock()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isUnlocking)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    func unlock() {
        guard !isUnlocking else { return }
        passwordError = false
        let enteredPassword = password
        let passwordStore = dependencies.keyCoverPassword
        let keyCover = dependencies.keyCover
        Task { @MainActor in
            isUnlocking = true
            defer { isUnlocking = false }

            let valid = await Task.detached(priority: .userInitiated) {
                passwordStore.validatePassword(enteredPassword)
            }.value

            if valid {
                // if Smart Unlock is enabled, store the masterKey
                keyCover.keyCoverPlainTextKey = enteredPassword
                keyCoverObserved.isKeyCoverUnlockingPromptShown = false
            } else {
                passwordError = true
            }
        }
    }
}
