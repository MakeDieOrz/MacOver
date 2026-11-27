//
//  ConfigInfoPane.swift
//  PlayCover
//

import SwiftUI

struct ConfigInfoPane: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppNavigationState.self) var navState
    @Environment(\.locale) private var locale

    var app: PlayApp
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
                infoRow("settings.info.displayName", value: app.info.displayName)
                infoRow("settings.info.bundleName", value: app.info.bundleName)
                infoRow("settings.info.bundleIdentifier", value: app.info.bundleIdentifier, monospaced: true)
                infoRow("settings.info.bundleVersion", value: app.info.bundleVersion, monospaced: true)
                infoRow("settings.info.executableName", value: app.info.executableName, monospaced: true)
                infoRow("settings.info.minimumOSVersion", value: app.info.minimumOSVersion, monospaced: true)
                LabeledContent(ConfigLabelFormatter.clean("settings.info.playTools", locale: locale)) {
                    Text(hasPlayTools ? "button.Yes" : "button.No")
                        .foregroundStyle(hasPlayTools ? .green : .orange)
                }
                infoPathRow("settings.info.url", path: app.info.url.relativePath)
                infoPathRow(
                    "settings.info.alias",
                    path: PlayApp.aliasDirectory.appendingPathComponent(app.info.bundleIdentifier).path
                )
            }
            .textSelection(.enabled)

            Section {
                Picker(selection: $applicationCategoryType) {
                    ForEach(LSApplicationCategoryType.allCases, id: \.rawValue) { value in
                        Text(value.localizedName).tag(value)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("settings.applicationCategoryType")
                        if blockingTask == .applicationCategoryType {
                            ProgressView()
                                .controlSize(.small)
                        }
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
                fileActionsRow
                maintenanceActionsRow
            }

            Section {
                HStack {
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        Task {
                            let didUninstall = await Uninstaller.uninstallPopup(app, dependencies: dependencies)
                            if didUninstall {
                                navState.closeConfiguration()
                            }
                        }
                    } label: {
                        Label("playapp.delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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

    private func infoRow(_ key: String, value: String, monospaced: Bool = false) -> some View {
        LabeledContent(ConfigLabelFormatter.clean(key, locale: locale)) {
            Text(value)
                .font(monospaced ? .callout.monospacedDigit() : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func infoPathRow(_ key: String, path: String) -> some View {
        LabeledContent(ConfigLabelFormatter.clean(key, locale: locale)) {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .truncationMode(.middle)
                .help(path)
        }
    }

    private var fileActionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                openCacheButton.fixedSize()
                showInFinderButton.fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                openCacheButton
                showInFinderButton
            }
        }
    }

    private var maintenanceActionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                clearCacheButton.fixedSize()
                clearPreferencesButton.fixedSize()
                clearPlayChainButton.fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    clearCacheButton.fixedSize()
                    clearPreferencesButton.fixedSize()
                    Spacer(minLength: 0)
                }
                clearPlayChainButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                clearCacheButton
                clearPreferencesButton
                clearPlayChainButton
            }
        }
    }

    private var openCacheButton: some View {
        Button {
            app.openAppCache()
        } label: {
            Label("playapp.openCache", systemImage: "folder")
        }
    }

    private var showInFinderButton: some View {
        Button {
            app.showInFinder()
        } label: {
            Label("playapp.showInFinder", systemImage: "magnifyingglass")
        }
    }

    private var clearCacheButton: some View {
        Button("playapp.clearCache") {
            Task { await Uninstaller.clearCachePopup(app, dependencies: dependencies) }
        }
    }

    private var clearPreferencesButton: some View {
        Button("playapp.clearPreferences") {
            showClearPreferencesAlert = true
        }
    }

    private var clearPlayChainButton: some View {
        Button("playapp.clearPlayChain") {
            showClearPlayChainAlert = true
        }
    }
}
