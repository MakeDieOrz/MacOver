//
//  AppDelegate.swift
//  PlayCover
//

import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showLowPowerModeAlertKey = "ShowLowPowerModeAlert"

    let dependencies: PlayCoverDependencies

    override convenience init() {
        self.init(dependencies: PlayCoverDependencies())
    }

    init(dependencies: PlayCoverDependencies) {
        self.dependencies = dependencies
        super.init()
    }

    var showLowPowerModeAlert: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.showLowPowerModeAlertKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.showLowPowerModeAlertKey)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        if let url = urls.first {
            dependencies.urlHandler.processURL(url: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.isRunningUnitTests else { return }

        UpdateScheme.checkForUpdate()

        UserDefaults.standard.register(
            defaults: ["NSApplicationCrashOnExceptions": true]
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            powerModal()
        }
        URLCache.iconCache.removeAllCachedResponses()

        let launchedBefore = UserDefaults.standard.bool(forKey: "launchedBefore")
        if !launchedBefore {
            UserDefaults.standard.set(true, forKey: "launchedBefore")

            // Initialize KeyCover with an automatically generated key
            let keyCoverPassword = dependencies.keyCoverPassword.generateVerySecurePassword()
            dependencies.keyCoverPassword.setKeyCoverPassword(keyCoverPassword)
            dependencies.keyCoverPreferences.keyCoverEnabled = .selfGeneratedPassword
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        for app in dependencies.appsVM.apps {
            app.settings.flush()
        }
    }

    @objc func powerStateChanged(_ notification: Notification) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            Task { @MainActor in
                self.powerModal()
            }
        }
    }

    func powerModal() {
        guard !ProcessInfo.isRunningUnitTests else { return }
        if showLowPowerModeAlert {
            let startupAlerts = dependencies.startupAlerts
            Task { @MainActor in
                startupAlerts.enqueue(.lowPowerMode)
            }
        }
    }
}
