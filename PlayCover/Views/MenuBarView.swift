//
//  MenuBarView.swift
//  PlayCover
//

import AppKit
import SwiftUI

struct PlayCoverMenuView: Commands {
    var navState: AppNavigationState
    let dependencies: PlayCoverDependencies

    var body: some Commands {
        CommandGroup(after: .systemServices) {
            Button("menubar.log.copy", systemImage: "document.on.document.fill") {
                dependencies.log.logdata.copyToClipBoard()
                dependencies.toastVM.showToast(
                    toastType: .notice,
                    toastDetails: NSLocalizedString("toast.logsCopied", comment: "")
                )
            }
            .keyboardShortcut("L", modifiers: [.command, .option])

            Button("menubar.configSigning", systemImage: "signature") {
                navState.isSigningSetupShown = true
            }
        }
    }
}

struct PlayCoverHelpMenuView: Commands {
    var updaterViewModel: UpdaterViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updaterViewModel: updaterViewModel)
        }

        CommandGroup(replacing: .help) {
            Button("menubar.documentation", systemImage: "document.fill") {
                if let url = URL(string: "https://github.com/MakeDieOrz/MacOver#readme") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("menubar.website", systemImage: "arrow.down.circle") {
                if let url = URL(string: "https://github.com/MakeDieOrz/MacOver/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("menubar.github", systemImage: "arrow.up.right") {
                if let url = URL(string: "https://github.com/MakeDieOrz/MacOver") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("menubar.discord", systemImage: "exclamationmark.bubble") {
                if let url = URL(string: "https://github.com/MakeDieOrz/MacOver/issues") {
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
    @Environment(\.openWindow) private var openWindow
    var navState: AppNavigationState
    let dependencies: PlayCoverDependencies

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .windowList) {
            Button("menubar.mainWindow", systemImage: "macwindow") {
                NSApp.activate()
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
        CommandGroup(replacing: .importExport) {
            Button("menubar.importIPA", systemImage: "plus.app") {
                navState.pendingImportIPATrigger = UUID()
            }
            .keyboardShortcut("O", modifiers: .command)

            Button("menubar.exportToSideloady", systemImage: "square.and.arrow.up.fill") {
                exportToSideloadly()
            }
        }
        CommandGroup(after: .sidebar) {
            Button("inspector.toggle", systemImage: "sidebar.right") {
                navState.showInspector.toggle()
            }
            .keyboardShortcut("I", modifiers: .command)

            if navState.configTargetID != nil {
                Button("sidebar.backToLibrary", systemImage: "chevron.left") {
                    if let targetID = navState.configTargetID,
                       let app = dependencies.appsVM.apps.first(where: { $0.id == targetID }) {
                        app.settings.flush()
                    }
                    navState.closeConfiguration()
                }
                .keyboardShortcut("[", modifiers: .command)
            }
        }
        CommandGroup(before: .sidebar) {
            Button("menubar.clearCache", systemImage: "eraser.fill") {
                LocalDataCache.shared.cleanAll()
                dependencies.cacher.removeImageCache()

                if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                   let bundleID = Bundle.main.bundleIdentifier {
                    FileManager.default.delete(at: cacheDir.appendingPathComponent(bundleID)
                        .appendingPathComponent("Image Cache"))
                }
                dependencies.toastVM.showToast(
                    toastType: .notice,
                    toastDetails: NSLocalizedString("toast.cacheCleared", comment: "")
                )
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
    @Environment(AppsVM.self) var appsVM

    private var runningApps: [PlayApp] {
        appsVM.apps.filter(\.isRunning)
    }

    var body: some View {
        Button("menubar.openWindow") {
            NSApp.activate()
            openWindow(id: "main")
        }

        if !runningApps.isEmpty {
            Divider()
            Section("sidebar.section.running") {
                ForEach(runningApps) { app in
                    Menu(app.name) {
                        Button("action.bringToFront") {
                            _ = app.activateRunningApplication()
                        }
                        Button("action.quit") {
                            Task {
                                guard app.isRunning, !app.isBusy else { return }
                                await app.terminate()
                            }
                        }
                        .disabled(!app.isRunning || app.isBusy)
                    }
                }
            }
        }

        if !appsVM.apps.isEmpty {
            Divider()
            ForEach(appsVM.apps.prefix(8)) { app in
                Menu(app.name) {
                    Button(app.isRunning ? "action.quit" : "action.launch") {
                        Task {
                            if app.isRunning {
                                await app.terminate()
                            } else if !app.isBusy {
                                await app.launch()
                            }
                        }
                    }
                    .disabled(app.isBusy)
                    Button("action.launchSafeMode") {
                        Task {
                            if app.isRunning {
                                await app.restart(safeModeOneShot: true)
                            } else if !app.isBusy {
                                await app.launch(safeModeOneShot: true)
                            }
                        }
                    }
                    .disabled(app.isBusy)
                }
            }
        }
        Divider()
        Button("button.Quit") {
            NSApp.terminate(nil)
        }
    }
}
