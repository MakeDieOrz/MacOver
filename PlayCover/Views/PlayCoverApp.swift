//
//  PlayCoverApp.swift
//  PlayCover
//

import SwiftUI

@main
struct PlayCoverApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State var updaterViewModel: UpdaterViewModel
    @State private var navState: AppNavigationState
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        if !ProcessInfo.isRunningUnitTests {
            PlayApp.clearDebugAffectingEnvironmentOnMainActor()
            UpdateScheme.checkForUpdate()
        }
        _updaterViewModel = State(initialValue: UpdaterViewModel())
        _navState = State(initialValue: AppNavigationState())
        _appDelegate = NSApplicationDelegateAdaptor(AppDelegate.self)
    }

    private var deps: PlayCoverDependencies { appDelegate.dependencies }

    var body: some Scene {
        Window("MacOver", id: "main") {
            if ProcessInfo.isRunningUnitTests {
                EmptyView()
            } else {
                RootSplitView()
                    .environment(deps)
                    .environment(deps.installVM)
                    .environment(deps.downloadVM)
                    .environment(deps.appsVM)
                    .environment(deps.storeVM)
                    .environment(deps.toastVM)
                    .environment(deps.appIntegrity)
                    .environment(deps.alertPresenter)
                    .environment(deps.startupAlerts)
                    .environment(deps.keyCoverObservable)
                    .environment(deps.keyCoverPreferences)
                    .environment(deps.installPreferences)
                    .environment(deps.uninstallPreferences)
                    .environment(deps.urlObservable)
                    .environment(deps.modifierKeyObserver)
                    .environment(deps.mitmCoordinator)
                    .environment(deps.mcpCoordinator)
                    .environment(deps.mcpPreferences)
                    .environment(navState)
                    .onAppear {
                        NSWindow.allowsAutomaticWindowTabbing = false
                    }
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            if !ProcessInfo.isRunningUnitTests {
                SidebarCommands()
                PlayCoverMenuView(navState: navState, dependencies: deps)
                PlayCoverHelpMenuView(updaterViewModel: updaterViewModel)
                PlayCoverViewMenuView(navState: navState, dependencies: deps)
            }
        }

        Settings {
            if ProcessInfo.isRunningUnitTests {
                EmptyView()
            } else {
                PlayCoverSettingsView(updaterViewModel: updaterViewModel)
                    .environment(deps)
                    .environment(deps.appsVM)
                    .environment(deps.storeVM)
                    .environment(deps.keyCoverObservable)
                    .environment(deps.keyCoverPreferences)
                    .environment(deps.installPreferences)
                    .environment(deps.uninstallPreferences)
                    .environment(deps.urlObservable)
                    .environment(deps.modifierKeyObserver)
                    .environment(deps.mitmCoordinator)
                    .environment(deps.mcpCoordinator)
                    .environment(deps.mcpPreferences)
                    .environment(navState)
            }
        }

        MenuBarExtra(
            "MacOver",
            systemImage: "ipad.landscape",
            isInserted: ProcessInfo.isRunningUnitTests ? .constant(false) : $showMenuBarExtra
        ) {
            PlayCoverMenuBarExtraContent()
                .environment(deps.appsVM)
        }

        WindowGroup("mitm.monitor.windowTitle", id: "mitm-monitor", for: String.self) { $bundleID in
            if let bundleID, !bundleID.isEmpty, !ProcessInfo.isRunningUnitTests {
                MITMTrafficMonitorView(bundleID: bundleID)
                    .environment(deps.mitmCoordinator)
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 900, height: 580)
    }
}
