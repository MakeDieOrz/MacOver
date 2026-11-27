//
//  AppDelegate.swift
//  PlayCover
//

import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showLowPowerModeAlertKey = "ShowLowPowerModeAlert"
    private static let showMenuBarExtraKey = "showMenuBarExtra"

    let dependencies: PlayCoverDependencies

    override convenience init() {
        let defaults: UserDefaults
        if ProcessInfo.isRunningUnitTests {
            defaults = UserDefaults(suiteName: "app.makedie.MacOver.UnitTests.\(UUID().uuidString)") ?? .standard
        } else {
            defaults = .standard
        }
        self.init(dependencies: PlayCoverDependencies(userDefaults: defaults))
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

    private var isMenuBarExtraEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.showMenuBarExtraKey) as? Bool ?? true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        if let url = urls.first {
            dependencies.urlHandler.processURL(url: url)
            bringMainWindowToFront(in: application)
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
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !ProcessInfo.isRunningUnitTests else { return false }
        if !flag, bringMainWindowToFront(in: sender) {
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isMenuBarExtraEnabled
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let apps = dependencies.appsVM.apps
        dependencies.mitmCoordinator.prepareForHostTermination(apps: apps)
        for app in apps {
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

    @discardableResult
    private func bringMainWindowToFront(in application: NSApplication) -> Bool {
        guard let mainWindow = application.windows.first(where: { window in
            window.canBecomeMain && !(window is NSPanel)
        }) else {
            return false
        }
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        application.activate()
        return true
    }
}
