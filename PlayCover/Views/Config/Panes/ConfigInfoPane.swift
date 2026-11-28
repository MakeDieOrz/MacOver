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

    private var isAppActiveOrBusy: Bool {
        app.isRunning || app.isBusy
    }

    init(app: PlayApp, hasPlayTools: Bool, blockingTask: Binding<ConfigBlockingTask>) {
        self.app = app
        self.hasPlayTools = hasPlayTools
        self._blockingTask = blockingTask
        _applicationCategoryType = State(initialValue: app.info.applicationCategoryType)
    }

    var body: some View {
        Form {
            if isAppActiveOrBusy {
                runningLockNoticeSection
            }

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
                .disabled(isAppActiveOrBusy || blockingTask != .none)
                .onChange(of: applicationCategoryType) { _, newCategory in
                    guard app.info.applicationCategoryType != newCategory else { return }
                    guard !isAppActiveOrBusy else {
                        applicationCategoryType = app.info.applicationCategoryType
                        return
                    }
                    blockingTask = .applicationCategoryType
                    app.info.applicationCategoryType = newCategory
                    PlayApp.invalidateVerifiedBundleStamp(for: app.url)
                    let executableURL = app.executable
                    let bundleURL = app.url
                    Task { @MainActor in
                        defer { blockingTask = .none }
                        do {
                            try await Task.detached(priority: .userInitiated) {
                                try Shell.signApp(executableURL)
                                PlayApp.invalidateVerifiedBundleStamp(for: bundleURL)
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
                        guard !isAppActiveOrBusy else { return }
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
                    .disabled(isAppActiveOrBusy || blockingTask != .none)
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
                guard !isAppActiveOrBusy else { return }
                app.deletePreferences()
            }
            Button("button.Cancel", role: .cancel) {}
        }
        .alert("alert.app.clearPlayChain", isPresented: $showClearPlayChainAlert) {
            Button("button.Proceed", role: .destructive) {
                guard !isAppActiveOrBusy else { return }
                app.clearPlayChain()
                Self.removeResidualPlayChainArtifacts(for: app.info.bundleIdentifier)
            }
            Button("button.Cancel", role: .cancel) {}
        }
    }

    private var runningLockNoticeSection: some View {
        Section {
            AdaptiveLeadingTrailingLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("config.runningLock.title")
                            .font(.callout.weight(.semibold))
                        Text("config.runningLock.infoNote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if app.isRunning {
                    Button("action.quit", role: .destructive) {
                        Task {
                            guard app.isRunning, !app.isBusy else { return }
                            await app.terminate()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(app.isBusy)
                    .fixedSize()
                }
            }
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
        AdaptiveWrappingRowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            openCacheButton
            showInFinderButton
        }
    }

    private var maintenanceActionsRow: some View {
        AdaptiveWrappingRowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            clearCacheButton
            clearPreferencesButton
            clearPlayChainButton
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
            guard !isAppActiveOrBusy else { return }
            Task { await Uninstaller.clearCachePopup(app, dependencies: dependencies) }
        }
        .disabled(isAppActiveOrBusy || blockingTask != .none)
    }

    private var clearPreferencesButton: some View {
        Button("playapp.clearPreferences") {
            guard !isAppActiveOrBusy else { return }
            showClearPreferencesAlert = true
        }
        .disabled(isAppActiveOrBusy || blockingTask != .none)
    }

    private var clearPlayChainButton: some View {
        Button("playapp.clearPlayChain") {
            guard !isAppActiveOrBusy else { return }
            showClearPlayChainAlert = true
        }
        .disabled(isAppActiveOrBusy || blockingTask != .none)
    }

    nonisolated static func removeResidualPlayChainArtifacts(
        for bundleID: String,
        in playChainDirectory: URL = KeyCover.playChainPath
    ) {
        guard !bundleID.isEmpty else { return }
        let fm = FileManager.default
        let exactNames: Set<String> = [
            bundleID,
            "\(bundleID).keyCover",
            "\(bundleID).db",
            "\(bundleID).db-wal",
            "\(bundleID).db-shm",
            "\(bundleID).db-journal"
        ]
        for name in exactNames {
            let candidate = playChainDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                fm.delete(at: candidate)
            }
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: playChainDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        for entry in entries where isPlayChainVersionedBackupFile(
            entry.lastPathComponent,
            bundleID: bundleID
        ) {
            fm.delete(at: entry)
        }
    }

    nonisolated private static func isPlayChainVersionedBackupFile(
        _ fileName: String,
        bundleID: String
    ) -> Bool {
        guard fileName.hasSuffix(".bak") else { return false }
        let stem = fileName.dropLast(".bak".count)
        let prefixes = ["\(bundleID).db.v", "\(bundleID).v"]
        for prefix in prefixes where stem.hasPrefix(prefix) {
            let versionSlice = stem.dropFirst(prefix.count)
            if !versionSlice.isEmpty && versionSlice.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return true
            }
        }
        return false
    }
}
