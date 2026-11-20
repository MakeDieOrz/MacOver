//
//  ConfigInfoPane.swift
//  PlayCover
//

import SwiftUI

struct ConfigInfoPane: View {
    @EnvironmentObject var dependencies: PlayCoverDependencies
    @EnvironmentObject var navState: AppNavigationState

    @ObservedObject var app: PlayApp
    let hasPlayTools: Bool
    @Binding var blockingTask: ConfigBlockingTask

    @State private var applicationCategoryType: LSApplicationCategoryType
    @State private var showClearPreferencesAlert = false
    @State private var showClearPlayChainAlert = false

    init(app: PlayApp, hasPlayTools: Bool, blockingTask: Binding<ConfigBlockingTask>) {
        self.app = app
        self.hasPlayTools = hasPlayTools
        self._blockingTask = blockingTask
        _applicationCategoryType = State(initialValue: app.info.applicationCategoryType)
    }

    var body: some View {
        Form {
            Section("settings.tab.info") {
                LabeledContent("settings.info.displayName", value: app.info.displayName)
                LabeledContent("settings.info.bundleName", value: app.info.bundleName)
                LabeledContent("settings.info.bundleIdentifier", value: app.info.bundleIdentifier)
                LabeledContent("settings.info.bundleVersion", value: app.info.bundleVersion)
                LabeledContent("settings.info.executableName", value: app.info.executableName)
                LabeledContent("settings.info.minimumOSVersion", value: app.info.minimumOSVersion)
                LabeledContent("settings.info.playTools") {
                    Text(hasPlayTools ? "button.Yes" : "button.No")
                }
                LabeledContent("settings.info.url", value: app.info.url.relativePath)
                LabeledContent("settings.info.alias",
                               value: PlayApp.aliasDirectory.appendingPathComponent(app.info.bundleIdentifier).path)
            }
            .textSelection(.enabled)

            Section("settings.applicationCategoryType") {
                HStack {
                    Picker("settings.applicationCategoryType", selection: $applicationCategoryType) {
                        ForEach(LSApplicationCategoryType.allCases, id: \.rawValue) { value in
                            Text(value.localizedName).tag(value)
                        }
                    }
                    if blockingTask == .applicationCategoryType {
                        ProgressView().controlSize(.small)
                    }
                }
                .onChange(of: applicationCategoryType) { _, newCategory in
                    guard app.info.applicationCategoryType != newCategory else { return }
                    blockingTask = .applicationCategoryType
                    app.info.applicationCategoryType = newCategory
                    let executableURL = app.executable
                    Task { @MainActor in
                        defer { blockingTask = .none }
                        do {
                            try await Task.detached(priority: .userInitiated) {
                                try Shell.signApp(executableURL)
                            }.value
                        } catch {
                            PlayCoverDiagnostics.reportError(error)
                        }
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("playapp.openCache") { app.openAppCache() }
                    Button("playapp.showInFinder") { app.showInFinder() }
                    Button("playapp.clearCache") {
                        Task { await Uninstaller.clearCachePopup(app, dependencies: dependencies) }
                    }
                    Button("playapp.clearPreferences") { showClearPreferencesAlert = true }
                    Button("playapp.clearPlayChain") { showClearPlayChainAlert = true }
                    Spacer()
                    Button("playapp.delete", role: .destructive) {
                        Task {
                            await Uninstaller.uninstallPopup(app, dependencies: dependencies)
                            navState.closeConfiguration()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: app.url) {
            applicationCategoryType = app.info.applicationCategoryType
        }
        .alert("alert.app.preferences", isPresented: $showClearPreferencesAlert) {
            Button("button.Proceed", role: .destructive) {
                app.deletePreferences()
            }
            Button("button.Cancel", role: .cancel) {}
        }
        .alert("alert.app.clearPlayChain", isPresented: $showClearPlayChainAlert) {
            Button("button.Proceed", role: .destructive) {
                app.clearPlayChain()
            }
            Button("button.Cancel", role: .cancel) {}
        }
    }
}
