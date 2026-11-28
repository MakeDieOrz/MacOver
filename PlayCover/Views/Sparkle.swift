//
//  Sparkle.swift
//  PlayCover
//
//  Created by Andrew Glaze on 7/17/22.
//  Copied from https://sparkle-project.org/documentation/programmatic-setup/
//

import Observation
import Sparkle
import SwiftUI

// This view model class manages Sparkle's updater and publishes when new updates are allowed to be checked
@MainActor
@Observable
final class UpdaterViewModel {
    @ObservationIgnored private let updaterController: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckForUpdatesObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticallyChecksObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticallyCheckStorage = false

    let isUpdateVerificationConfigured: Bool
    var canCheckForUpdates = false

    var automaticallyCheckForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyCheckForUpdates)
            return isUpdateVerificationConfigured ? automaticallyCheckStorage : false
        }
        set(newValue) {
            guard isUpdateVerificationConfigured else { return }
            withMutation(keyPath: \.automaticallyCheckForUpdates) {
                automaticallyCheckStorage = newValue
            }
            if updaterController.updater.automaticallyChecksForUpdates != newValue {
                updaterController.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    static func hasConfiguredPublicEDKey(in infoDictionary: [String: Any]?) -> Bool {
        guard let rawKey = infoDictionary?["SUPublicEDKey"] as? String else {
            return false
        }
        return !rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        startUpdater: Bool = !ProcessInfo.isRunningUnitTests,
        bundle: Bundle = .main
    ) {
        let hasPublicEDKey = Self.hasConfiguredPublicEDKey(in: bundle.infoDictionary)
        self.isUpdateVerificationConfigured = hasPublicEDKey
        let effectiveStartUpdater = startUpdater && hasPublicEDKey && !ProcessInfo.isRunningUnitTests

        // Keep Sparkle inactive on ad-hoc builds without SUPublicEDKey so remote feeds
        // cannot be checked or applied without EdDSA signature verification.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: effectiveStartUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        if effectiveStartUpdater {
            automaticallyCheckStorage = updaterController.updater.automaticallyChecksForUpdates
            canCheckForUpdatesObservation = updaterController.updater.observe(
                \.canCheckForUpdates,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let canCheck = change.newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.canCheckForUpdates = self.isUpdateVerificationConfigured && canCheck
                }
            }

            automaticallyChecksObservation = updaterController.updater.observe(
                \.automaticallyChecksForUpdates,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let autoCheck = change.newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.automaticallyCheckStorage != autoCheck else { return }
                    self.withMutation(keyPath: \.automaticallyCheckForUpdates) {
                        self.automaticallyCheckStorage = autoCheck
                    }
                }
            }

            if automaticallyCheckForUpdates {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.isUpdateVerificationConfigured, self.canCheckForUpdates else { return }
                    self.updaterController.updater.checkForUpdatesInBackground()
                }
            }
        } else {
            canCheckForUpdates = false
            automaticallyCheckStorage = false
            if !ProcessInfo.isRunningUnitTests && updaterController.updater.automaticallyChecksForUpdates {
                updaterController.updater.automaticallyChecksForUpdates = false
            }
        }
    }

    func checkForUpdates() {
        guard !ProcessInfo.isRunningUnitTests, isUpdateVerificationConfigured, canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }
}

// This additional view is needed for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more information
struct CheckForUpdatesView: View {
    var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button(NSLocalizedString("menubar.checkForUpdates", comment: ""),
               systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
               action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
