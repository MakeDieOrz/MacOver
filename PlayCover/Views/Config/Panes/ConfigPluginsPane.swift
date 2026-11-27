//
//  ConfigPluginsPane.swift
//  PlayCover
//

import SwiftUI

struct ConfigPluginsPane: View {
    @Environment(AppsVM.self) var appsVM
    @Environment(\.locale) private var locale

    var app: PlayApp
    @Binding var hasPlayTools: Bool
    @Binding var blockingTask: ConfigBlockingTask

    @AppStorage("settings.customPluginsWarningShown") private var hasShownCustomPluginWarning = false
    @State private var userDylibs: [URL] = []
    @State private var showCustomPluginWarning = false
    @State private var showRemovePlayToolsConfirm = false

    var body: some View {
        Form {
            Section {
                if userDylibs.isEmpty {
                    Text("settings.customPlugins.empty")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(userDylibs, id: \.self) { dylib in
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(dylib.lastPathComponent)
                            Spacer()
                            Button(role: .destructive) {
                                removeDylib(dylib)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(dylib.lastPathComponent)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("settings.customPlugins.title")
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
                    .controlSize(.small)
                    .disabled(!hasPlayTools)
                }
            }

            Section("action.launchSafeMode") {
                Text("plugins.safeModeDesc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                .disabled(!app.isRunning && app.isStarting)
            }

            Section("PlayTools") {
                let isBusy = blockingTask == .playTools
                LabeledContent(ConfigLabelFormatter.clean("settings.info.playTools", locale: locale)) {
                    HStack(spacing: 12) {
                        Text(hasPlayTools ? "button.Yes" : "button.No")
                            .foregroundStyle(hasPlayTools ? .green : .orange)

                        Button(role: hasPlayTools ? .destructive : nil) {
                            if hasPlayTools {
                                showRemovePlayToolsConfirm = true
                            } else {
                                togglePlayTools()
                            }
                        } label: {
                            ZStack {
                                Text(hasPlayTools ? "settings.removePlayTools" : "alert.install.injectPlayTools")
                                    .opacity(isBusy ? 0 : 1)
                                if isBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(hasPlayTools ? .red : .accentColor)
                        .disabled(isBusy)
                    }
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
        .alert("confirm.removePlayTools.title", isPresented: $showRemovePlayToolsConfirm) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.removePlayTools", role: .destructive) {
                togglePlayTools()
            }
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
            Task.detached(priority: .userInitiated) {
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
        Task.detached(priority: .userInitiated) {
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
        let bundleURL = app.url
        let bundleID = app.info.bundleIdentifier
        let svcManifestURL = bundleID.isEmpty ? nil : app.svcPatchManifestURL
        let currentlyInstalled = hasPlayTools
        Task.detached(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    blockingTask = .none
                }
            }
            if currentlyInstalled {
                await PlayTools.removeFromApp(
                    executable,
                    appBundleURL: bundleURL,
                    bundleIdentifier: bundleID,
                    svcManifestURL: svcManifestURL
                )
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
