//
//  MenuBarView.swift
//  PlayCover
//

import AppKit
import Combine
import DataCache
import SwiftUI

struct PlayCoverMenuView: Commands {
    @ObservedObject var navState: AppNavigationState
    let dependencies: PlayCoverDependencies

    var body: some Commands {
        CommandGroup(after: .systemServices) {
            Button("menubar.log.copy", systemImage: "document.on.document.fill") {
                dependencies.log.logdata.copyToClipBoard()
            }
            .keyboardShortcut("L", modifiers: [.command, .option])

            Button("menubar.configSigning", systemImage: "signature") {
                navState.isSigningSetupShown = true
            }
        }
    }
}

struct PlayCoverHelpMenuView: Commands {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updaterViewModel: updaterViewModel)
        }

        CommandGroup(replacing: .help) {
            Button("menubar.documentation", systemImage: "document.fill") {
                if let url = URL(string: "https://docs.playcover.io") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("menubar.website", systemImage: "network") {
                if let url = URL(string: "https://playcover.io") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("menubar.github", systemImage: "arrow.up.right") {
                if let url = URL(string: "https://github.com/PlayCover/PlayCover/") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("menubar.discord", systemImage: "arrow.up.right") {
                if let url = URL(string: "https://discord.com/invite/playcover-871829896492642387") {
                    NSWorkspace.shared.open(url)
                }
            }
            #if DEBUG
            Divider()
            Button("[DEBUG] Crash app", systemImage: "xmark.circle.fill") {
                fatalError("Crash was triggered")
            }
            #endif
        }
    }
}

struct PlayCoverViewMenuView: Commands {
    @ObservedObject var navState: AppNavigationState
    let dependencies: PlayCoverDependencies

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .importExport) {
            Button("ui51.menubar.importIPA", systemImage: "plus.app") {
                navState.pendingImportIPATrigger = UUID()
            }
            .keyboardShortcut("O", modifiers: .command)

            Button("menubar.exportToSideloady", systemImage: "square.and.arrow.up.fill") {
                exportToSideloadly()
            }
        }
        CommandGroup(after: .sidebar) {
            Button("ui51.inspector.toggle", systemImage: "sidebar.right") {
                navState.showInspector.toggle()
            }
            .keyboardShortcut("I", modifiers: .command)

            if navState.configTargetID != nil {
                Button("ui51.sidebar.backToLibrary", systemImage: "chevron.left") {
                    navState.closeConfiguration()
                }
                .keyboardShortcut("[", modifiers: .command)
            }
        }
        CommandGroup(before: .sidebar) {
            Button("menubar.clearCache", systemImage: "eraser.fill") {
                DataCache.instance.cleanAll()
                dependencies.cacher.removeImageCache()

                if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                   let bundleID = Bundle.main.bundleIdentifier {
                    FileManager.default.delete(at: cacheDir.appendingPathComponent(bundleID)
                        .appendingPathComponent("Image Cache"))
                }
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])
            Divider()
        }
    }

    private func exportToSideloadly() {
        Task {
            if dependencies.installVM.inProgress {
                dependencies.log.error(PlayCoverError.waitInstallation)
            } else if dependencies.downloadVM.inProgress {
                dependencies.log.error(PlayCoverError.waitDownload)
            } else {
                await MainActor.run {
                    NSOpenPanel.selectIPA { result in
                        if case .success(let url) = result {
                            installAndOpenWithSideloadly(ipaUrl: url)
                        }
                    }
                }
            }
        }
    }

    private func installAndOpenWithSideloadly(ipaUrl: URL) {
        Task {
            Installer.install(
                ipaUrl: ipaUrl,
                export: true,
                dependencies: dependencies,
                returnCompletion: { ipa in
                    Task { @MainActor in
                        if let ipa {
                            ipa.showInFinder()
                            let config = NSWorkspace.OpenConfiguration()
                            config.promptsUserIfNeeded = true
                            let sideloadlyURL = NSWorkspace.shared
                                .urlForApplication(withBundleIdentifier: "io.sideloadly.sideloadly")
                            if let sideloadlyURL {
                                _ = try? await NSWorkspace.shared.open(
                                    [ipa],
                                    withApplicationAt: sideloadlyURL,
                                    configuration: config
                                )
                            } else {
                                dependencies.log.error("Could not find Sideloadly!")
                            }
                        } else {
                            dependencies.log.error("Could not find file!")
                        }
                    }
                }
            )
        }
    }
}

struct PlayCoverMenuBarExtraContent: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var appsVM: AppsVM

    @State private var refreshToken = 0

    private var runningApps: [PlayApp] {
        _ = refreshToken
        return appsVM.apps.filter(\.isRunning)
    }

    var body: some View {
        Button("ui51.menubar.openWindow") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        if !runningApps.isEmpty {
            Divider()
            Section("ui51.sidebar.section.running") {
                ForEach(runningApps) { app in
                    Button("\(app.name) — \(NSLocalizedString("ui51.action.quit", comment: ""))") {
                        Task { await app.terminate() }
                    }
                }
            }
        }

        if !appsVM.apps.isEmpty {
            Divider()
            ForEach(appsVM.apps.prefix(8)) { app in
                Menu(app.name) {
                    Button(app.isRunning ? "ui51.action.quit" : "ui51.action.launch") {
                        Task {
                            if app.isRunning {
                                await app.terminate()
                            } else if !app.isStarting {
                                await app.launch()
                            }
                        }
                    }
                    Button("ui51.action.launchSafeMode") {
                        Task {
                            if app.isRunning {
                                await app.restart(safeModeOneShot: true)
                            } else if !app.isStarting {
                                await app.launch(safeModeOneShot: true)
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Button("button.Quit") {
            NSApp.terminate(nil)
        }
        .onReceive(Publishers.MergeMany(appsVM.apps.map(\.objectWillChange))) { _ in
            refreshToken &+= 1
        }
    }
}
