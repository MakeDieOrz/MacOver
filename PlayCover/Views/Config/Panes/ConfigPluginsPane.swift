//
//  ConfigPluginsPane.swift
//  PlayCover
//

import SwiftUI

struct ConfigPluginsPane: View {
    @EnvironmentObject var appsVM: AppsVM

    @ObservedObject var app: PlayApp
    @Binding var hasPlayTools: Bool
    @Binding var blockingTask: ConfigBlockingTask

    @AppStorage("settings.customPluginsWarningShown") private var hasShownCustomPluginWarning = false
    @State private var userDylibs: [URL] = []
    @State private var showCustomPluginWarning = false

    var body: some View {
        Form {
            Section("settings.customPlugins.title") {
                HStack {
                    Text("settings.customPlugins.title")
                        .font(.headline)
                    Spacer()
                    Button {
                        if hasShownCustomPluginWarning {
                            selectAndAddDylib()
                        } else {
                            showCustomPluginWarning = true
                        }
                    } label: {
                        Label("settings.customPlugins.add", systemImage: "plus")
                    }
                    .disabled(!hasPlayTools)
                }

                if userDylibs.isEmpty {
                    Text("settings.customPlugins.empty")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(userDylibs, id: \.self) { dylib in
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                                .foregroundStyle(.secondary)
                            Text(dylib.lastPathComponent)
                            Spacer()
                            Button(role: .destructive) {
                                removeDylib(dylib)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("action.launchSafeMode") {
                Text("plugins.safeModeDesc")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        if app.isRunning {
                            await app.restart(safeModeOneShot: true)
                        } else if !app.isStarting {
                            await app.launch(safeModeOneShot: true)
                        }
                    }
                } label: {
                    Label("action.launchSafeMode", systemImage: "shield.lefthalf.filled")
                }
            }

            Section("PlayTools") {
                HStack {
                    LabeledContent("settings.info.playTools") {
                        Text(hasPlayTools ? "button.Yes" : "button.No")
                            .foregroundStyle(hasPlayTools ? .green : .orange)
                    }
                    Spacer()
                    Button(role: hasPlayTools ? .destructive : nil) {
                        togglePlayTools()
                    } label: {
                        if blockingTask == .playTools {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(hasPlayTools ? "settings.removePlayTools" : "alert.install.injectPlayTools")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(hasPlayTools ? .red : .accentColor)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task(id: app.url) {
            reloadUserDylibs()
        }
        .alert("settings.customPlugins.warningTitle", isPresented: $showCustomPluginWarning) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.customPlugins.warningConfirm", role: .destructive) {
                hasShownCustomPluginWarning = true
                selectAndAddDylib()
            }
        } message: {
            Text("settings.customPlugins.warningMessage")
        }
    }

    private func reloadUserDylibs() {
        userDylibs = PlayTools.userDylibs(bundleIdentifier: app.info.bundleIdentifier)
    }

    private func selectAndAddDylib() {
        NSOpenPanel.selectDylib { result in
            guard case .success(let url) = result else { return }
            let bundleID = app.info.bundleIdentifier
            let executable = app.executable
            Task(priority: .userInitiated) {
                do {
                    try PlayTools.addUserDylib(at: url, bundleIdentifier: bundleID, appExecutable: executable)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
                await MainActor.run {
                    reloadUserDylibs()
                }
            }
        }
    }

    private func removeDylib(_ url: URL) {
        let name = url.lastPathComponent
        let bundleID = app.info.bundleIdentifier
        let executable = app.executable
        Task(priority: .userInitiated) {
            do {
                try PlayTools.removeUserDylib(
                    named: name,
                    bundleIdentifier: bundleID,
                    appExecutable: executable
                )
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
            await MainActor.run {
                reloadUserDylibs()
            }
        }
    }

    private func togglePlayTools() {
        blockingTask = .playTools
        let executable = app.executable
        let currentlyInstalled = hasPlayTools
        Task(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    blockingTask = .none
                }
            }
            if currentlyInstalled {
                await PlayTools.removeFromApp(executable)
            } else {
                do {
                    try await PlayTools.installInIPA(executable)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }
            let updated = (try? PlayTools.installedInExec(atURL: executable)) ?? currentlyInstalled
            await MainActor.run {
                hasPlayTools = updated
                appsVM.fetchApps()
            }
        }
    }
}
