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
                Spacer()
                Button("button.Cancel") {
                    keyCoverObserved.isKeyCoverUnlockingPromptShown = false
                }
                .keyboardShortcut(.cancelAction)

                Button("button.Unlock") {
                    unlock()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    func unlock() {
        if dependencies.keyCoverPassword.validatePassword(password) {
            // if Smart Unlock is enabled, store the masterKey
            dependencies.keyCover.keyCoverPlainTextKey = password
        } else {
            passwordError = true
            return
        }
        keyCoverObserved.isKeyCoverUnlockingPromptShown = false
    }
}
