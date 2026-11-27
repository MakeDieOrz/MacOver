//
//  AppsVM.swift
//  PlayCover
//

import Foundation
import Observation

@Observable
class AppsVM {

    nonisolated public static let appDirectory = PlayTools.playCoverContainer.appendingPathComponent("Applications")

    weak var dependencies: PlayCoverDependencies?

    init(dependencies: PlayCoverDependencies? = nil, loadOnInit: Bool = !ProcessInfo.isRunningUnitTests) {
        self.dependencies = dependencies
        try? AppsVM.ensureBaseDirectoriesExist()
        if loadOnInit {
            PlayTools.installOnSystem()
            fetchApps()
        }
    }

    nonisolated static func ensureBaseDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
    }

    var filteredApps: [PlayApp] = []
    var apps: [PlayApp] = []
    var searchText: String = ""
    var updatingApps = true

    private var fetchTask: Task<Void, Never>?
    private var hasStartedInitialFetch = false
    private var cachedIndexByPath: [String: CachedAppIndexEntry] = [:]

    @MainActor
    func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nextFiltered = query.isEmpty
            ? apps
            : apps.filter { $0.searchText.contains(query) }
        filteredApps = nextFiltered.sorted { lhs, rhs in
            let lhsRank = lhs.sortRunningRank
            let rhsRank = rhs.sortRunningRank
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.sortName < rhs.sortName
        }
    }

    @MainActor
    func loadCachedIndexIfAvailable() {
        let span = PerformanceSignpost.beginInterval("AppsIndexLoad")
        defer { PerformanceSignpost.endInterval("AppsIndexLoad", span) }

        let entries = AppLibraryIndexCache.load()
        guard !entries.isEmpty else { return }

        let fm = FileManager.default
        var restored: [PlayApp] = []
        var byPath: [String: CachedAppIndexEntry] = [:]

        for entry in entries {
            let appURL = URL(fileURLWithPath: entry.urlPath)
            let plistURL = appURL.appendingPathComponent("Info").appendingPathExtension("plist")
            guard fm.fileExists(atPath: plistURL.path) else { continue }
            let cachedInfo = AppInfo(
                cachedPlistURL: plistURL,
                cachedFields: AppInfo.CachedFields(
                    bundleIdentifier: entry.bundleIdentifier,
                    bundleName: entry.bundleName,
                    displayName: entry.displayName,
                    bundleVersion: entry.bundleVersion,
                    cfBundleVersion: entry.cfBundleVersion,
                    executableName: entry.executableName,
                    installGeneration: entry.installGeneration,
                    primaryIconName: entry.primaryIconName
                ),
                installGenerationKey: Installer.installGenerationInfoKey
            )
            let app = PlayApp(appUrl: appURL, info: cachedInfo, dependencies: dependencies)
            app.hasPlayToolsCached = entry.hasPlayTools
            app.applySettingsSummary(
                strictEmulationMode: entry.strictEmulationMode,
                effectiveIOSDeviceModel: entry.effectiveIOSDeviceModel,
                pixelBudgetRatio: entry.pixelBudgetRatio
            )
            restored.append(app)
            byPath[entry.urlPath] = entry
        }

        cachedIndexByPath = byPath
        guard !restored.isEmpty else { return }
        apps = restored
        dependencies?.runningAppsMonitor.reconcile(apps: restored)
        applyFilter()
        updatingApps = false
    }

    @MainActor
    func fetchAppsIfNeeded() {
        guard !hasStartedInitialFetch else { return }
        fetchApps()
    }

    nonisolated static func shouldReuseExistingApp(_ existing: PlayApp, at appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Info").appendingPathExtension("plist")
        let freshInfo = AppInfo(contentsOf: plistURL)
        let existingInfo = existing.info
        let generationKey = Installer.installGenerationInfoKey
        return freshInfo.bundleIdentifier == existingInfo.bundleIdentifier
            && freshInfo.bundleVersion == existingInfo.bundleVersion
            && freshInfo[object: "CFBundleVersion"] == existingInfo[object: "CFBundleVersion"]
            && freshInfo.executableName == existingInfo.executableName
            && freshInfo.displayName == existingInfo.displayName
            && freshInfo.bundleName == existingInfo.bundleName
            && freshInfo[string: generationKey] == existingInfo[string: generationKey]
    }

    private nonisolated static func resolveHasPlayTools(
        app: PlayApp,
        cachedEntry: CachedAppIndexEntry?,
        infoPlistStamp: PlayTools.FileStatStamp?,
        execStamp: PlayTools.FileStatStamp?
    ) -> Bool {
        if let cachedEntry,
           cachedEntry.infoPlistMTimeSec == (infoPlistStamp?.mtimeSec ?? -1),
           cachedEntry.execMTimeSec == (execStamp?.mtimeSec ?? -1),
           cachedEntry.execInode == (execStamp?.inode ?? 0),
           cachedEntry.execSize == (execStamp?.size ?? -1) {
            return cachedEntry.hasPlayTools
        }
        return (try? PlayTools.installedInExec(atURL: app.executable)) ?? true
    }

    private nonisolated struct ResolvedAppSettingsSummary: Sendable {
        let strictEmulationMode: Bool
        let effectiveIOSDeviceModel: String
        let pixelBudgetRatio: Double
        let settingsPlistMTimeSec: Int
    }

    private nonisolated static func resolveSettingsSummary(
        bundleIdentifier: String,
        cachedEntry: CachedAppIndexEntry?
    ) -> ResolvedAppSettingsSummary {
        guard !bundleIdentifier.isEmpty else {
            return ResolvedAppSettingsSummary(
                strictEmulationMode: false,
                effectiveIOSDeviceModel: "iPad13,8",
                pixelBudgetRatio: 0,
                settingsPlistMTimeSec: -1
            )
        }
        let settingsURL = AppSettings.settingsURL(forBundleIdentifier: bundleIdentifier)
        let settingsStamp = PlayTools.fileStamp(for: settingsURL)
        let mtime = settingsStamp?.mtimeSec ?? -1
        if let cachedEntry,
           cachedEntry.bundleIdentifier == bundleIdentifier,
           cachedEntry.settingsPlistMTimeSec == mtime {
            return ResolvedAppSettingsSummary(
                strictEmulationMode: cachedEntry.strictEmulationMode,
                effectiveIOSDeviceModel: cachedEntry.effectiveIOSDeviceModel,
                pixelBudgetRatio: cachedEntry.pixelBudgetRatio,
                settingsPlistMTimeSec: mtime
            )
        }
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? PropertyListDecoder().decode(AppSettingsData.self, from: data) {
            return ResolvedAppSettingsSummary(
                strictEmulationMode: decoded.strictEmulationMode,
                effectiveIOSDeviceModel: decoded.effectiveIOSDeviceModel,
                pixelBudgetRatio: decoded.pixelBudget.ratio,
                settingsPlistMTimeSec: mtime
            )
        }
        let defaults = AppSettingsData()
        return ResolvedAppSettingsSummary(
            strictEmulationMode: defaults.strictEmulationMode,
            effectiveIOSDeviceModel: defaults.effectiveIOSDeviceModel,
            pixelBudgetRatio: defaults.pixelBudget.ratio,
            settingsPlistMTimeSec: -1
        )
    }

    func fetchApps() {
        hasStartedInitialFetch = true
        fetchTask?.cancel()
        let deps = self.dependencies
        fetchTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let span = PerformanceSignpost.beginInterval("AppsFetchReconcile")
            defer { PerformanceSignpost.endInterval("AppsFetchReconcile", span) }

            await MainActor.run {
                if self.apps.isEmpty {
                    self.updatingApps = true
                }
            }

            let existingByURL = await MainActor.run {
                Dictionary(self.apps.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            }
            let cachedEntriesSnapshot = await MainActor.run { self.cachedIndexByPath }

            let result: [(
                app: PlayApp,
                hasPlayTools: Bool,
                settingsSummary: ResolvedAppSettingsSummary,
                entry: CachedAppIndexEntry
            )] =
                await Task.detached(priority: .userInitiated) {
                    var discovered: [(
                        app: PlayApp,
                        hasPlayTools: Bool,
                        settingsSummary: ResolvedAppSettingsSummary,
                        entry: CachedAppIndexEntry
                    )] = []
                    do {
                        let fm = FileManager.default
                        let directoryContents = try fm.contentsOfDirectory(
                            at: AppsVM.appDirectory,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: []
                        )

                        for sub in directoryContents where sub.hasDirectoryPath {
                            if Task.isCancelled { return discovered }
                            let plistURL = sub.appendingPathComponent("Info").appendingPathExtension("plist")
                            if sub.pathExtension.contains("app") && fm.fileExists(atPath: plistURL.path) {
                                let infoStamp = PlayTools.fileStamp(for: plistURL)
                                let cachedEntry = cachedEntriesSnapshot[sub.path]

                                let app: PlayApp
                                if let existing = existingByURL[sub] {
                                    if let cachedEntry,
                                       let infoStamp,
                                       infoStamp.mtimeSec == cachedEntry.infoPlistMTimeSec {
                                        app = existing
                                    } else if AppsVM.shouldReuseExistingApp(existing, at: sub) {
                                        app = existing
                                    } else {
                                        app = PlayApp(appUrl: sub, dependencies: deps)
                                    }
                                } else {
                                    app = PlayApp(appUrl: sub, dependencies: deps)
                                }
                                app.dependencies = deps

                                let execStamp = PlayTools.fileStamp(for: app.executable)
                                let installedPT = AppsVM.resolveHasPlayTools(
                                    app: app,
                                    cachedEntry: cachedEntry,
                                    infoPlistStamp: infoStamp,
                                    execStamp: execStamp
                                )
                                let settingsSummary = AppsVM.resolveSettingsSummary(
                                    bundleIdentifier: app.info.bundleIdentifier,
                                    cachedEntry: cachedEntry
                                )

                                let indexEntry = CachedAppIndexEntry(
                                    urlPath: sub.path,
                                    bundleIdentifier: app.info.bundleIdentifier,
                                    bundleName: app.info.bundleName,
                                    displayName: app.info.displayName,
                                    bundleVersion: app.info.bundleVersion,
                                    cfBundleVersion: app.info[string: "CFBundleVersion"] ?? "",
                                    executableName: app.info.executableName,
                                    installGeneration: app.info[string: Installer.installGenerationInfoKey] ?? "",
                                    primaryIconName: app.info.primaryIconName,
                                    hasPlayTools: installedPT,
                                    strictEmulationMode: settingsSummary.strictEmulationMode,
                                    effectiveIOSDeviceModel: settingsSummary.effectiveIOSDeviceModel,
                                    pixelBudgetRatio: settingsSummary.pixelBudgetRatio,
                                    infoPlistMTimeSec: infoStamp?.mtimeSec ?? -1,
                                    settingsPlistMTimeSec: settingsSummary.settingsPlistMTimeSec,
                                    execMTimeSec: execStamp?.mtimeSec ?? -1,
                                    execInode: execStamp?.inode ?? 0,
                                    execSize: execStamp?.size ?? -1
                                )
                                discovered.append((
                                    app: app,
                                    hasPlayTools: installedPT,
                                    settingsSummary: settingsSummary,
                                    entry: indexEntry
                                ))
                            }
                        }
                    } catch {
                        print(error)
                    }

                    if Task.isCancelled { return discovered }

                    do {
                        let existingCache: [String]
                        if FileManager.default.fileExists(atPath: PlayApp.bundleIDCacheURL.path) {
                            existingCache = try PlayApp.bundleIDCache
                        } else {
                            existingCache = []
                        }
                        let existingSet = Set(existingCache)
                        var missingIDs: [String] = []
                        var seenMissing = Set<String>()
                        for item in discovered {
                            let bid = item.app.info.bundleIdentifier
                            if !bid.isEmpty && !existingSet.contains(bid) && seenMissing.insert(bid).inserted {
                                missingIDs.append(bid)
                            }
                        }
                        if !missingIDs.isEmpty {
                            let merged = existingCache + missingIDs
                            let payload = merged.joined(separator: "\n") + "\n"
                            try payload.write(to: PlayApp.bundleIDCacheURL, atomically: true, encoding: .utf8)
                        }
                    } catch {
                        PlayCoverDiagnostics.reportError(error)
                    }

                    return discovered
                }.value

            guard !Task.isCancelled else { return }

            let loadedApps = result.map(\.app)
            let updatedEntries = result.map(\.entry)
            let updatedMap = Dictionary(
                updatedEntries.map { ($0.urlPath, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            await MainActor.run {
                for item in result {
                    item.app.hasPlayToolsCached = item.hasPlayTools
                    item.app.applySettingsSummary(
                        strictEmulationMode: item.settingsSummary.strictEmulationMode,
                        effectiveIOSDeviceModel: item.settingsSummary.effectiveIOSDeviceModel,
                        pixelBudgetRatio: item.settingsSummary.pixelBudgetRatio
                    )
                }
                self.cachedIndexByPath = updatedMap
                self.apps = loadedApps
                self.dependencies?.runningAppsMonitor.reconcile(apps: loadedApps)
                self.applyFilter()
                self.updatingApps = false
            }

            Task.detached(priority: .background) {
                _ = AppLibraryIndexCache.save(updatedEntries)
                for app in loadedApps {
                    app.ensureAliasUpToDate()
                }
            }
        }
    }
}
