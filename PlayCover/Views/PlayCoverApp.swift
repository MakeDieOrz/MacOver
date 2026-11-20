//
//  PlayCoverApp.swift
//  PlayCover
//

import SwiftUI

@main
struct PlayCoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var updaterViewModel = UpdaterViewModel()
    @StateObject private var navState = AppNavigationState()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    private var deps: PlayCoverDependencies { appDelegate.dependencies }

    var body: some Scene {
        WindowGroup(id: "main") {
            if ProcessInfo.isRunningUnitTests {
                EmptyView()
            } else {
                RootSplitView()
                    .environmentObject(deps)
                    .environmentObject(deps.installVM)
                    .environmentObject(deps.downloadVM)
                    .environmentObject(deps.appsVM)
                    .environmentObject(deps.storeVM)
                    .environmentObject(deps.toastVM)
                    .environmentObject(deps.appIntegrity)
                    .environmentObject(deps.alertPresenter)
                    .environmentObject(deps.startupAlerts)
                    .environmentObject(deps.keyCoverObservable)
                    .environmentObject(deps.keyCoverPreferences)
                    .environmentObject(deps.installPreferences)
                    .environmentObject(deps.uninstallPreferences)
                    .environmentObject(deps.urlObservable)
                    .environmentObject(deps.modifierKeyObserver)
                    .environmentObject(navState)
                    .onAppear {
                        NSWindow.allowsAutomaticWindowTabbing = false
                        deps.soundDeviceService.prepareSoundDevice()
                        deps.notifyService.allowNotify()
                    }
            }
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["{same path of URL?}"])
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
                    .environmentObject(deps)
                    .environmentObject(deps.appsVM)
                    .environmentObject(deps.storeVM)
                    .environmentObject(deps.keyCoverObservable)
                    .environmentObject(deps.keyCoverPreferences)
                    .environmentObject(deps.installPreferences)
                    .environmentObject(deps.uninstallPreferences)
                    .environmentObject(deps.urlObservable)
                    .environmentObject(deps.modifierKeyObserver)
                    .environmentObject(navState)
            }
        }

        MenuBarExtra(
            "MacOver",
            systemImage: "ipad.landscape",
            isInserted: ProcessInfo.isRunningUnitTests ? .constant(false) : $showMenuBarExtra
        ) {
            PlayCoverMenuBarExtraContent()
                .environmentObject(deps.appsVM)
        }
    }
}
