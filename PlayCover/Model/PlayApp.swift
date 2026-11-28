//
//  PlayApp.swift
//  PlayCover
//

import Cocoa
import Darwin
import Foundation
import IOKit.pwr_mgt
import Observation
import PlayCoverCore
import Synchronization

@Observable
nonisolated class PlayApp: BaseApp, Identifiable, Hashable, @unchecked Sendable {
    var id: URL { url }

    static func == (lhs: PlayApp, rhs: PlayApp) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    // MARK: - Static
    public static let bundleIDCacheURL = PlayTools.playCoverContainer.appendingPathComponent("CACHE")

    public static var bundleIDCache: [String] {
        get throws {
            (try String(contentsOf: bundleIDCacheURL, encoding: .utf8))
                .split(whereSeparator: \.isNewline)
                .map { String($0) }
        }
    }

    private struct VerifiedBundleStamp: Equatable {
        let execMTimeSec: Int
        let execMTimeNSec: Int
        let execIno: UInt64
        let codeResMTimeSec: Int
        let codeResMTimeNSec: Int
        let playToolsMTimeSec: Int
        let playToolsMTimeNSec: Int
        let userPluginsDigest: String?
    }

    private static let verifiedBundleStamps = Mutex<[String: VerifiedBundleStamp]>([:])

    private static func fileStamp(for url: URL) -> (sec: Int, nsec: Int, ino: UInt64) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return (0, 0, 0) }
        return (Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), UInt64(st.st_ino))
    }

    private static func currentBundleStamp(bundleURL: URL, executableURL: URL) -> VerifiedBundleStamp {
        let exec = fileStamp(for: executableURL)
        let codeRes = fileStamp(for: bundleURL.appendingPathComponent("_CodeSignature/CodeResources"))
        let playTools = fileStamp(for: PlayTools.playToolsPath)
        let userPluginsDigest = PlayTools.directoryTreeDigest(
            at: bundleURL.appendingPathComponent("Frameworks/UserPlugins", isDirectory: true)
        )
        return VerifiedBundleStamp(
            execMTimeSec: exec.sec,
            execMTimeNSec: exec.nsec,
            execIno: exec.ino,
            codeResMTimeSec: codeRes.sec,
            codeResMTimeNSec: codeRes.nsec,
            playToolsMTimeSec: playTools.sec,
            playToolsMTimeNSec: playTools.nsec,
            userPluginsDigest: userPluginsDigest
        )
    }

    static func invalidateVerifiedBundleStamp(for bundleURL: URL) {
        verifiedBundleStamps.withLock {
            _ = $0.removeValue(forKey: bundleURL.path)
        }
        AppLaunchFingerprintStore.shared.invalidate(for: bundleURL.path)
    }

    // MARK: - Instance State
    @ObservationIgnored private let assertionLock = Mutex<Void>(())
    @ObservationIgnored var displaySleepAssertionID: IOPMAssertionID?
    @ObservationIgnored private let runStateMirror = Mutex<AppRunState>(.idle)
    @ObservationIgnored private var _sessionDisableKeychain = false
    @ObservationIgnored private var runningApplication: NSRunningApplication?
    @MainActor var runState: AppRunState = .idle
    @MainActor var hasPlayToolsCached: Bool = true
    @MainActor var strictEmulationModeCached: Bool = false
    @MainActor var effectiveIOSDeviceModelCached: String = "iPad13,8"
    @MainActor var pixelBudgetRatioCached: Double = 0
    @MainActor var launchSnapshot: AppSettingsData?
    @ObservationIgnored weak var dependencies: PlayCoverDependencies?
    @ObservationIgnored private let settingsSummaryMirror = Mutex<(strict: Bool, device: String, ratio: Double)>(
        (false, "iPad13,8", 0)
    )

    @MainActor
    var isRunning: Bool {
        get { runState.isRunning }
        set { setRunState(newValue ? .running(isActive: false) : .idle) }
    }

    @MainActor
    public var isStarting: Bool {
        runState.isStarting
    }

    @MainActor
    var isTerminating: Bool {
        runState.isTerminating
    }

    @MainActor
    var isBusy: Bool {
        runState.isBusy
    }

    @MainActor
    var restartRequiredChanges: [PlayCoverRestartField] {
        guard isRunning, let launchSnapshot else { return [] }
        return settings.settings.restartRequiredChanges(comparedTo: launchSnapshot)
    }

    func currentRunState() -> AppRunState {
        runStateMirror.withLock { $0 }
    }

    @MainActor
    func setRunState(_ next: AppRunState) {
        let previous = runState
        guard previous != next else { return }
        runStateMirror.withLock { $0 = next }
        runState = next
        if previous.sortRank != next.sortRank {
            dependencies?.appsVM.applyFilter()
        }
    }

    @MainActor
    private func beginLaunchIfIdle() -> Bool {
        guard !runState.isRunning && !runState.isBusy else { return false }
        setRunState(.preparing(.verifying))
        return true
    }

    var sessionDisableKeychain: Bool {
        get { assertionLock.withLock { _ in _sessionDisableKeychain } }
        set { assertionLock.withLock { _ in _sessionDisableKeychain = newValue } }
    }

    // MARK: - Init
    init(appUrl: URL, dependencies: PlayCoverDependencies? = nil, settings: AppSettings? = nil) {
        self.dependencies = dependencies
        super.init(appUrl: appUrl)
        if let settings {
            attachInitialSettings(settings)
        }
    }

    init(appUrl: URL, info: AppInfo, dependencies: PlayCoverDependencies? = nil, settings: AppSettings? = nil) {
        self.dependencies = dependencies
        super.init(appUrl: appUrl, info: info)
        if let settings {
            attachInitialSettings(settings)
        }
    }

    private func attachInitialSettings(_ initialSettings: AppSettings) {
        settingsLock.withLock { cached in
            cached = initialSettings
        }
        syncSettingsSummary(from: initialSettings.settings)
        _ = initialSettings.addChangeObserver { [weak self, weak initialSettings] in
            guard let self, let initialSettings else { return }
            self.syncSettingsSummary(from: initialSettings.settings)
        }
    }

    func applySettingsSummary(
        strictEmulationMode: Bool,
        effectiveIOSDeviceModel: String,
        pixelBudgetRatio: Double
    ) {
        settingsSummaryMirror.withLock {
            $0 = (strictEmulationMode, effectiveIOSDeviceModel, pixelBudgetRatio)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                strictEmulationModeCached = strictEmulationMode
                effectiveIOSDeviceModelCached = effectiveIOSDeviceModel
                pixelBudgetRatioCached = pixelBudgetRatio
            }
        } else {
            Task { @MainActor [weak self] in
                self?.strictEmulationModeCached = strictEmulationMode
                self?.effectiveIOSDeviceModelCached = effectiveIOSDeviceModel
                self?.pixelBudgetRatioCached = pixelBudgetRatio
            }
        }
    }

    private func syncSettingsSummary(from data: AppSettingsData) {
        applySettingsSummary(
            strictEmulationMode: data.strictEmulationMode,
            effectiveIOSDeviceModel: data.effectiveIOSDeviceModel,
            pixelBudgetRatio: data.pixelBudget.ratio
        )
    }

    // MARK: - Computed
    var searchText: String {
        info.displayName.lowercased()
            .appending(" ")
            .appending(info.bundleName)
            .lowercased()
    }

    var name: String {
        info.displayName.isEmpty ? info.bundleName : info.displayName
    }

    // MARK: - Paths / Singletons
    static let aliasDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications")
        .appendingPathComponent("MacOver")

    var aliasURL: URL {
        PlayApp.aliasDirectory
            .appendingEscapedPathComponent(name)
            .appendingPathExtension("app")
    }
    var playChainURL: URL {
        KeyCover.playChainPath.appendingPathComponent(info.bundleIdentifier)
    }

    @ObservationIgnored private let settingsLock = Mutex<AppSettings?>(nil)
    var settings: AppSettings {
        let (resolved, newlyCreated) = settingsLock.withLock { cached -> (AppSettings, Bool) in
            if let cached { return (cached, false) }
            let created = AppSettings(info)
            cached = created
            return (created, true)
        }
        if newlyCreated {
            syncSettingsSummary(from: resolved.settings)
            _ = resolved.addChangeObserver { [weak self, weak resolved] in
                guard let self, let resolved else { return }
                self.syncSettingsSummary(from: resolved.settings)
            }
        }
        return resolved
    }

    @ObservationIgnored private let keymappingLock = Mutex<Keymapping?>(nil)
    var keymapping: Keymapping {
        keymappingLock.withLock { cached in
            if let cached { return cached }
            let created = Keymapping(info, alertPresenter: dependencies?.alertPresenter)
            cached = created
            return created
        }
    }

    var container: AppContainer {
        AppContainer(bundleId: info.bundleIdentifier)
    }

    // MARK: - Launch
    @concurrent
    func launch(
        safeModeOneShot: Bool = false,
        automationOneShot: Bool = false,
        captureDebugLog: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) async {
        guard await beginLaunchIfIdle() else { return }
        let launchSpan = PerformanceSignpost.beginInterval("AppLaunchTotal")
        defer {
            PerformanceSignpost.endInterval("AppLaunchTotal", launchSpan)
            Task { @MainActor [weak self] in
                guard let self, !self.runState.isRunning && !self.runState.isTerminating else { return }
                self.setRunState(.idle)
            }
        }

        do {
            let launchBundleID = info.bundleIdentifier
            guard HelperSecurityValidator.validateGuestBundleIdentifier(launchBundleID) else {
                throw PlayCoverError.playToolsError(
                    "Refused to launch app with invalid or reserved bundle identifier: \(launchBundleID)"
                )
            }
            if prohibitedToPlay {
                await clearAllCache()
                throw PlayCoverError.appProhibited
            } else if maliciousProhibited {
                await clearAllCache()
                deleteApp()
                throw PlayCoverError.appMaliciousProhibited
            }

            if let versionCheck = dependencies?.versionCheck,
               await versionCheck.checkNewVersion(myApp: self) {
                return
            }

            settings.sync()

            let launchInfo = AppInfo(
                contentsOf: url.appendingPathComponent("Info").appendingPathExtension("plist")
            )
            let diskBundleID = launchInfo.bundleIdentifier
            guard HelperSecurityValidator.validateGuestBundleIdentifier(diskBundleID),
                  diskBundleID == launchBundleID else {
                throw PlayCoverError.playToolsError(
                    "Refused to launch app with invalid or mismatched Info.plist bundle identifier: \(diskBundleID)"
                )
            }
            let launchBackupsDir = BaseApp.appBackupsRoot.appendingEscapedPathComponent(diskBundleID)
            try Installer.validateOrInvalidateAppBackupsForLaunch(at: launchBackupsDir, for: launchInfo)
            try prepareLaunchDirectories(bundleID: diskBundleID)

            let svcBundleID = diskBundleID
            let currentSettings = settings.settings
            // Only copy CoverUseBridge into Frameworks/UserPlugins when the persistent setting is enabled.
            // One-shot automation (automationOneShot == true) loads CoverUseBridge from the read-only
            // PlayTools.framework/Versions/A/Frameworks/BuiltInPlugins/CoverUseBridge directory without
            // mutating or re-signing the target .app bundle on disk.
            let wantsBundleBridge = !safeModeOneShot && currentSettings.enableAutomationBridge
            let wantsAutomationEnv = !safeModeOneShot
                && (currentSettings.enableAutomationBridge || automationOneShot)
            let stagedBridgePath = url
                .appendingPathComponent("Frameworks/UserPlugins/CoverUseBridge/CoverUseBridge.dylib")
                .path
            let stagedBridgeExists = FileManager.default.fileExists(atPath: stagedBridgePath)
            let stagedBridgeMatchesForPlayTools = stagedBridgeExists == wantsBundleBridge
            let stagedBridgeMatchesWithoutPlayTools = !stagedBridgeExists

            await PlayTools.waitForSystemInstall()

            let stampTarget = AppLaunchFingerprintStore.Target(
                appURL: url,
                executableURL: executable,
                appEntitlementsURL: entitlements,
                bundleID: svcBundleID
            )
            var fastPathHit = false
            var cachedUsesPlayTools = true
            if !safeModeOneShot && stagedBridgeMatchesForPlayTools,
               let candidateStamp = AppLaunchFingerprintStore.currentStamp(
                   target: stampTarget,
                   settings: currentSettings,
                   usesPlayTools: true,
                   isCatalyst: true
               ),
               AppLaunchFingerprintStore.shared.matches(candidateStamp, for: url.path) {
                fastPathHit = true
                cachedUsesPlayTools = candidateStamp.usesPlayTools
            } else if !safeModeOneShot && stagedBridgeMatchesWithoutPlayTools,
                      let nonPTStamp = AppLaunchFingerprintStore.currentStamp(
                          target: stampTarget,
                          settings: currentSettings,
                          usesPlayTools: false,
                          isCatalyst: true
                      ),
                      AppLaunchFingerprintStore.shared.matches(nonPTStamp, for: url.path) {
                fastPathHit = true
                cachedUsesPlayTools = false
            }

            let usesPlayTools: Bool
            if fastPathHit {
                PerformanceSignpost.emitEvent("AppLaunchFastPathHit")
                usesPlayTools = cachedUsesPlayTools
                await MainActor.run {
                    self.hasPlayToolsCached = usesPlayTools
                }
            } else {
                let preflightSpan = PerformanceSignpost.beginInterval("AppLaunchSlowPreflight")
                defer { PerformanceSignpost.endInterval("AppLaunchSlowPreflight", preflightSpan) }

                let binaryInfo = try? Macho.inspectBinary(
                    atURL: executable,
                    playToolsPath: PlayTools.playToolsPath.path
                )
                usesPlayTools = binaryInfo?.hasPlayTools ?? hasPlayTools()
                await MainActor.run {
                    self.hasPlayToolsCached = usesPlayTools
                }

                var pluginsModified = false
                if usesPlayTools && !safeModeOneShot {
                    let componentModified = try PlayTools.installPluginInIPA(url)
                    let bridgeDirs = wantsBundleBridge
                        ? [PlayTools.builtInCoverUseBridgeDirectory()].compactMap { $0 }
                        : []
                    let userPluginsModified = try PlayTools.syncUserDylibs(
                        bundleIdentifier: svcBundleID,
                        into: executable,
                        extraPluginDirectories: bridgeDirs
                    )
                    pluginsModified = componentModified || userPluginsModified
                }

                let binaryModified = try Macho.fixLibrariesIfNeeded(atURL: executable)
                let svcResult: InlineSyscallPatcher.ReconcileResult
                if !safeModeOneShot && !svcBundleID.isEmpty {
                    let shouldInterceptSVC = usesPlayTools && currentSettings.effectiveInterceptInlineSyscalls
                    svcResult = try InlineSyscallPatcher.reconcile(
                        appBundleURL: url,
                        bundleIdentifier: svcBundleID,
                        manifestURL: BaseApp.svcPatchManifestURL(forBundleIdentifier: svcBundleID),
                        enabled: shouldInterceptSVC
                    )
                } else {
                    svcResult = InlineSyscallPatcher.ReconcileResult(
                        modified: false,
                        modifiedBinaryURLs: [],
                        patchedSiteCount: 0
                    )
                }

                if svcResult.modified {
                    let execCanonical = executable.standardizedFileURL.resolvingSymlinksInPath()
                    for modifiedURL in svcResult.modifiedBinaryURLs where
                        modifiedURL.standardizedFileURL.resolvingSymlinksInPath() != execCanonical {
                        try Shell.signMacho(modifiedURL)
                    }
                }

                let introspectionModified: Bool
                if usesPlayTools && !safeModeOneShot {
                    if currentSettings.strictEmulationMode {
                        introspectionModified = stripIntrospectionForStrictLaunch(launchInfo: launchInfo)
                    } else {
                        introspectionModified = restoreIntrospectionForNonStrictLaunch(launchInfo: launchInfo)
                    }
                } else {
                    introspectionModified = false
                }

                let entitlementsInvalid = try !Entitlements.areEntitlementsValid(app: self)

                if entitlementsInvalid {
                    Self.invalidateVerifiedBundleStamp(for: url)
                    try signThrowing()
                    try Shell.verifyAppSignature(url)
                    let stamp = Self.currentBundleStamp(bundleURL: url, executableURL: executable)
                    Self.verifiedBundleStamps.withLock {
                        $0[url.path] = stamp
                    }
                } else if binaryModified
                            || pluginsModified
                            || svcResult.modified
                            || introspectionModified
                            || !isBundleSignatureStrictlyValid() {
                    Self.invalidateVerifiedBundleStamp(for: url)
                    do {
                        try Shell.signApp(executable)
                        try Shell.verifyAppSignature(url)
                    } catch {
                        try signThrowing()
                        try Shell.verifyAppSignature(url)
                    }
                    let stamp = Self.currentBundleStamp(bundleURL: url, executableURL: executable)
                    Self.verifiedBundleStamps.withLock {
                        $0[url.path] = stamp
                    }
                }

                let validArch: Bool
                if !binaryModified, let binaryInfo {
                    validArch = binaryInfo.isCatalyst
                } else {
                    validArch = try Macho.isMachoValidArch(executable)
                }
                if !validArch {
                    PlayCoverDiagnostics.reportError("The app threw an error during conversion.")
                    return
                }

                if !safeModeOneShot,
                   let verifiedStamp = AppLaunchFingerprintStore.currentStamp(
                       target: stampTarget,
                       settings: settings.settings,
                       usesPlayTools: usesPlayTools,
                       isCatalyst: validArch
                   ) {
                    AppLaunchFingerprintStore.shared.record(verifiedStamp, for: url.path)
                }
            }

            if try (usesPlayTools && !PlayTools.isInstalled()) {
                if let installErr = PlayTools.systemInstallFailure() {
                    let message = "PlayTools installation failed: \(installErr.localizedDescription)"
                    PlayCoverDiagnostics.reportError(message)
                } else {
                    PlayCoverDiagnostics.reportError(
                        "PlayTools are not installed! Please move MacOver.app into Applications!"
                    )
                }
                return
            }

            if usesPlayTools && wantsAutomationEnv && !wantsBundleBridge {
                try? PlayTools.ensureBuiltInCoverUseBridgeInstalled()
            }

            await setRunState(.preparing(.unlocking))
            // Wait for keychain unlock to finish before continuing
            await unlockKeyCover()

            let hadContainer = container.doesExist()
            if settings.settings.discordActivity.enable {
                loadDiscordIPC()
            } else {
                releaseDiscordIPC()
            }

            await setRunState(.preparing(.opening))
            do {
                if !safeModeOneShot && !svcBundleID.isEmpty {
                    await AppSettings.syncMetalHUD(
                        bundleID: svcBundleID,
                        enabled: settings.settings.effectiveMetalHUD
                    )
                }
                settings.flush()
                if !safeModeOneShot && settings.effectiveOpenWithLLDB {
                    let launchDate = Date()
                    let launchedSettings = settings.settings
                    let discordAlreadyLinked = hadContainer && launchedSettings.discordActivity.enable
                    let monitor = dependencies?.runningAppsMonitor
                    let openWithTerminal = settings.openLLDBWithTerminal
                    if let monitor {
                        await monitor.registerPendingHostLaunch(
                            app: self,
                            launchDate: launchDate,
                            launchSnapshot: launchedSettings,
                            discordAlreadyLinked: discordAlreadyLinked
                        )
                    }
                    try Shell.lldb(
                        executable,
                        withTerminalWindow: openWithTerminal,
                        onExit: { [weak self] launchedSuccessfully in
                            guard let self else { return }
                            // For non-terminal LLDB, onExit fires when the debugger process exits;
                            // for Terminal AppleScript, onExit fires immediately, so only clean up on error.
                            guard !openWithTerminal || !launchedSuccessfully else { return }
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                let clearedPending = monitor?.clearPendingHostLaunchIfNotRunning(for: self) ?? true
                                if clearedPending && !self.runState.isRunning {
                                    self.releaseDiscordIPC()
                                    self.lockKeyCover()
                                }
                            }
                        }
                    )
                } else {
                    ensureAliasUpToDate()

                    var mergedExtraEnv = extraEnvironment
                    if captureDebugLog && mergedExtraEnv["PLAYTOOLS_DEBUG_LOG"] == nil {
                        mergedExtraEnv["PLAYTOOLS_DEBUG_LOG"] = "1"
                    }
                    if usesPlayTools && wantsAutomationEnv {
                        if mergedExtraEnv["MACOVER_AUTOMATION_TOKEN"] == nil,
                           let bridgeEnv = await dependencies?.mcpCoordinator.prepareAutomationEnvironment(
                               for: svcBundleID
                           ) {
                            for (envKey, envValue) in bridgeEnv where mergedExtraEnv[envKey] == nil {
                                mergedExtraEnv[envKey] = envValue
                            }
                        }
                    }

                    try await runAppExec(
                        discordAlreadyLinked: hadContainer && settings.settings.discordActivity.enable,
                        safeModeOneShot: safeModeOneShot,
                        extraEnvironment: mergedExtraEnv
                    )
                }
            } catch {
                self.lockKeyCover()
                throw error
            }
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }
}

// MARK: - Environment Management
nonisolated extension PlayApp {
    static let introspection: String = LaunchEnvironmentPatcher.introspectionLibraryPath
    static let iosFrameworks: String = LaunchEnvironmentPatcher.iosFrameworksLibraryPath

    /// Common Metal and capture related environment keys used in multiple places
    private static let metalEnvKeys: [String] = [
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_LAYER",
        "MTL_DEBUG_LAYER",
        "METAL_API_VALIDATION",
        "METAL_SHADER_VALIDATION",
        "METAL_SHADER_VALIDATION_OPTIONS",
        "METAL_CAPTURE_ENABLED",
        "METAL_CAPTURE_OUTPUT_FILE",
        "METAL_CAPTURE_TYPE",
        "METAL_FORCE_LAZY_COMPILATION",
        "METAL_FRAME_CAPTURE_ENABLED",
        "METAL_ERROR_MODE",
        "MTLCaptureEnabled"
    ]

    // Clear debug-affecting host environment variables once at startup on the main thread
    // (unsetenv(3) is not thread-safe and must never be called concurrently from background tasks).
    @MainActor
    static func clearDebugAffectingEnvironmentOnMainActor() {
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }
        for key in PlayApp.metalEnvKeys {
            unsetenv(key)
        }
    }

    func runAppExec(
        discordAlreadyLinked: Bool = false,
        safeModeOneShot: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) async throws {
        let launchDate = Date()
        if let mitmCoordinator = dependencies?.mitmCoordinator {
            try await mitmCoordinator.prepareForLaunch(app: self, safeModeOneShot: safeModeOneShot)
        }
        let config = NSWorkspace.OpenConfiguration()
        if safeModeOneShot || !extraEnvironment.isEmpty {
            var env = config.environment
            for (key, value) in extraEnvironment {
                env[key] = value
            }
            if safeModeOneShot {
                env["PLAYTOOLS_SAFE_MODE"] = "1"
            }
            config.environment = env
        }
        let launchedSettings = settings.settings

        let targetURL = url
        let targetPath = targetURL.path
        await setRunState(.launching)
        let runningApp: NSRunningApplication?
        do {
            runningApp = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(
                    at: targetURL,
                    configuration: config,
                    completionHandler: { app, error in
                        if let error {
                            PlayCoverDiagnostics.log(
                                "LaunchServices failed to open \(targetPath): \(error)",
                                isError: true
                            )
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: app)
                        }
                    }
                )
            }
        } catch {
            if let mitmCoordinator = dependencies?.mitmCoordinator {
                await mitmCoordinator.handleAppTermination(bundleID: info.bundleIdentifier, settings: settings)
            }
            throw error
        }

        if let runningApp {
            if let monitor = dependencies?.runningAppsMonitor {
                await monitor.registerHostLaunch(
                    app: self,
                    runningApplication: runningApp,
                    launchDate: launchDate,
                    launchSnapshot: launchedSettings,
                    discordAlreadyLinked: discordAlreadyLinked
                )
            } else {
                setRunningApplication(runningApp)
                await MainActor.run {
                    self.launchSnapshot = launchedSettings
                    self.setRunState(.running(isActive: runningApp.isActive))
                }
            }
        } else {
            self.enableTimeOut()
            self.releaseDiscordIPC()
            self.lockKeyCover()
            if let mitmCoordinator = self.dependencies?.mitmCoordinator {
                let bid = self.info.bundleIdentifier
                let appSettings = self.settings
                Task { await mitmCoordinator.handleAppTermination(bundleID: bid, settings: appSettings) }
            }
        }
    }

    func setRunningApplication(_ app: NSRunningApplication) {
        assertionLock.withLock { _ in
            runningApplication = app
        }
    }

    func clearRunningApplicationIfMatches(processIdentifier: pid_t) -> Bool {
        assertionLock.withLock { _ in
            guard runningApplication?.processIdentifier == processIdentifier else {
                return false
            }
            runningApplication = nil
            return true
        }
    }

    func clearRunningApplication() {
        assertionLock.withLock { _ in
            runningApplication = nil
        }
    }

    func snapshotRunningApplication() -> NSRunningApplication? {
        assertionLock.withLock { _ in runningApplication }
    }

    @MainActor
    @discardableResult
    func activateRunningApplication() -> Bool {
        let liveRunning: NSRunningApplication?
        if let current = snapshotRunningApplication(), !current.isTerminated {
            liveRunning = current
        } else if let fallback = NSRunningApplication.runningApplications(
            withBundleIdentifier: info.bundleIdentifier
        ).first(where: { !$0.isTerminated }) {
            liveRunning = fallback
        } else {
            liveRunning = nil
        }
        guard let running = liveRunning else {
            return false
        }
        _ = running.activate()
        if !ProcessInfo.isRunningUnitTests {
            let reopenURL = running.bundleURL ?? url
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(
                at: reopenURL,
                configuration: config,
                completionHandler: nil
            )
        }
        return true
    }

    func terminate() async {
        let current = snapshotRunningApplication()
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleIdentifier)
                .first(where: { !$0.isTerminated })
        guard let current, !current.isTerminated else {
            if let monitor = dependencies?.runningAppsMonitor {
                await monitor.notifyProcessTerminated(
                    for: self,
                    pid: current?.processIdentifier ?? 0
                )
            } else {
                enableTimeOut()
                await setRunState(.idle)
            }
            return
        }

        let targetPID = current.processIdentifier
        await setRunState(.terminating)
        _ = current.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while !current.isTerminated && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !current.isTerminated {
            _ = current.forceTerminate()
            let forceDeadline = Date().addingTimeInterval(0.5)
            while !current.isTerminated && Date() < forceDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let stillAlive = await MainActor.run {
            RunningAppsMonitor.isProcessAlive(pid: targetPID, isTerminated: current.isTerminated)
        }
        if !stillAlive {
            if let monitor = dependencies?.runningAppsMonitor {
                await monitor.notifyProcessTerminated(for: self, pid: targetPID)
            } else {
                _ = clearRunningApplicationIfMatches(processIdentifier: targetPID)
                enableTimeOut()
                await setRunState(.idle)
            }
        } else {
            await setRunState(.running(isActive: current.isActive))
        }
    }

    @concurrent
    func restart(
        safeModeOneShot: Bool = false,
        automationOneShot: Bool = false,
        captureDebugLog: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) async {
        await terminate()
        await launch(
            safeModeOneShot: safeModeOneShot,
            automationOneShot: automationOneShot,
            captureDebugLog: captureDebugLog,
            extraEnvironment: extraEnvironment
        )
    }

    func deletePreferences() {
        let appID = info.bundleIdentifier
        let plistURL = AppContainer(bundleId: appID).userPrefsUrl

        _ = try? Shell.run(print: false, "/usr/bin/defaults", "delete", appID)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            PlayCoverDiagnostics.showToast(
                toastType: .notice,
                toastDetails: NSLocalizedString("playapp.clearPreferences", comment: "")
            )
            return
        }

        do {
            try FileManager.default.removeItem(atPath: plistURL.path)
            PlayCoverDiagnostics.showToast(
                toastType: .notice,
                toastDetails: NSLocalizedString("playapp.clearPreferences", comment: "")
            )
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    var sortName: String { name.lowercased() }
    var sortVersion: String { info.bundleVersion }
    var sortDevice: String { settingsSummaryMirror.withLock { $0.device } }
    var sortPixelRatio: Double { settingsSummaryMirror.withLock { $0.ratio } }
    var sortRunningRank: Int { currentRunState().sortRank }
}

// MARK: - Management
nonisolated extension PlayApp {
    func disableTimeOut() {
        guard settings.settings.disableTimeout else {
            enableTimeOut()
            return
        }
        assertionLock.withLock { _ in
            guard let app = runningApplication, !app.isTerminated else { return }
            if displaySleepAssertionID != nil { return }

            let reason = "PlayCover: \(info.bundleIdentifier) is disabling sleep" as CFString
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            if result == kIOReturnSuccess {
                displaySleepAssertionID = assertionID
            }
        }
    }

    func enableTimeOut() {
        assertionLock.withLock { _ in
            if let assertionID = displaySleepAssertionID {
                IOPMAssertionRelease(assertionID)
                displaySleepAssertionID = nil
            }
        }
    }
}

// MARK: - KeyCover
nonisolated extension PlayApp {
    func unlockKeyCover() async {
        guard let keyCover = dependencies?.keyCover, keyCover.isKeyCoverEnabled() else { return }
        let keychain = keyCover.listKeychains()
            .first(where: { $0.appBundleID == self.info.bundleIdentifier })

        if let keychain = keychain, keychain.chainEncryptionStatus {
            try? await keyCover.unlockChain(keychain)

            if keyCover.keyCoverPlainTextKey == nil {
                let presenter = dependencies?.alertPresenter ?? AlertPresenter()
                _ = await presenter.present(
                    PlayCoverAlertRequest(
                        title: NSLocalizedString("keycover.alert.title", comment: ""),
                        message: NSLocalizedString("keycover.alert.content", comment: ""),
                        style: .warning,
                        buttons: [PlayCoverAlertButton(title: NSLocalizedString("button.OK", comment: ""))],
                        defaultCancelIndex: 0
                    )
                )
                settings.update { $0.playChain = false }
                _ = settings.flush()
                sessionDisableKeychain = true
            }
        }
    }

    func lockKeyCover() {
        guard let keyCover = dependencies?.keyCover, keyCover.isKeyCoverEnabled() else { return }
        if sessionDisableKeychain {
            settings.update { $0.playChain = true }
            _ = settings.flush()
            sessionDisableKeychain = false
            return
        }

        let keychain = keyCover.listKeychains()
            .first(where: { $0.appBundleID == self.info.bundleIdentifier })

        if let keychain = keychain, !keychain.chainEncryptionStatus {
            try? keyCover.lockChain(keychain)
        }
    }
}

// MARK: - Tools
nonisolated extension PlayApp {
    func hasPlayTools() -> Bool {
        do {
            return try PlayTools.installedInExec(atURL: url.appendingEscapedPathComponent(info.executableName))
        } catch {
            PlayCoverDiagnostics.reportError(error)
            return true
        }
    }

    private func syncInMemoryLSEnvironment(_ env: [String: String]) {
        let filtered = LaunchEnvironmentPatcher.sanitizedLSEnvironment(env)
        if filtered.isEmpty {
            info[dictionary: "LSEnvironment"] = nil
        } else {
            info[dictionary: "LSEnvironment"] = NSMutableDictionary(dictionary: filtered)
        }
    }

    func stripIntrospectionForStrictLaunch(launchInfo: AppInfo) -> Bool {
        let result = LaunchEnvironmentPatcher.stripForStrictLaunch(env: launchInfo.lsEnvironment)
        if result.discoveredIntrospection, !settings.settings.storedHasIntrospection {
            settings.update { $0.storedHasIntrospection = true }
            _ = settings.flush()
        }
        if result.discoveredIosFrameworks, !settings.settings.storedHasIosFrameworks {
            settings.update { $0.storedHasIosFrameworks = true }
            _ = settings.flush()
        }
        guard result.changed else {
            return false
        }
        launchInfo.lsEnvironment = result.env
        syncInMemoryLSEnvironment(result.env)
        Self.invalidateVerifiedBundleStamp(for: url)
        return true
    }

    func restoreIntrospectionForNonStrictLaunch(launchInfo: AppInfo) -> Bool {
        let result = LaunchEnvironmentPatcher.restoreForNonStrictLaunch(
            env: launchInfo.lsEnvironment,
            storedHasIntrospection: settings.settings.storedHasIntrospection,
            storedHasIosFrameworks: settings.settings.storedHasIosFrameworks
        )
        guard result.changed else {
            return false
        }
        launchInfo.lsEnvironment = result.env
        syncInMemoryLSEnvironment(result.env)
        Self.invalidateVerifiedBundleStamp(for: url)
        return true
    }

    @concurrent
    func changeDyldLibraryPath(set: Bool? = nil, path: String) async -> Bool {
        if let set {
            if path == Self.introspection {
                settings.update { $0.storedHasIntrospection = set }
            } else if path == Self.iosFrameworks {
                settings.update { $0.storedHasIosFrameworks = set }
            }
            let result = LaunchEnvironmentPatcher.updatedLSEnvironment(
                info.lsEnvironment,
                including: path,
                enabled: set
            )
            if result.changed {
                info.lsEnvironment = result.env
                Self.invalidateVerifiedBundleStamp(for: url)

                do {
                    try Shell.signApp(executable)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }
            return set
        }

        return LaunchEnvironmentPatcher.containsLibraryPath(path, in: info.lsEnvironment)
    }
}

// MARK: - FS / Codesign
nonisolated extension PlayApp {
    func hasAlias() -> Bool {
        FileManager.default.fileExists(atPath: aliasURL.path)
    }

    func isInfoPlistSigned() throws -> Bool {
        if let info = Entitlements.signingInfo(for: executable) {
            return info.isSigned && info.infoPlistSealed
        }
        return try Shell.run("/usr/bin/codesign", "-dv", executable.path).contains("Info.plist entries")
    }

    func isBundleSignatureStrictlyValid() -> Bool {
        do {
            guard try isInfoPlistSigned() else { return false }
            let stamp = Self.currentBundleStamp(bundleURL: url, executableURL: executable)
            let cached = Self.verifiedBundleStamps.withLock {
                $0[url.path] == stamp
            }
            if cached {
                return true
            }
            try Shell.verifyAppSignature(url)
            Self.verifiedBundleStamps.withLock {
                $0[url.path] = stamp
            }
            return true
        } catch {
            return false
        }
    }

    func showInFinder() {
        URL(fileURLWithPath: url.path).showInFinderAndSelectLastComponent()
    }

    func openAppCache() {
        let resolved = container.containerUrl
        if FileManager.default.fileExists(atPath: resolved.path) {
            resolved.showInFinderAndSelectLastComponent()
        } else {
            PlayCoverDiagnostics.showToast(
                toastType: .notice,
                toastDetails: NSLocalizedString("app.dataDirMissing", comment: "")
            )
        }
    }

    @discardableResult
    @concurrent
    func clearAllCache() async -> Error? {
        let bundleId = self.info.bundleIdentifier
        let bundleURL = self.url
        return await Task.detached(priority: .userInitiated) {
            await Uninstaller.clearExternalCache(
                bundleId,
                appBundleURL: bundleURL
            )
        }.value
    }

    private static func ensureSecureDirectory(at url: URL, permissions: Int = 0o700) throws {
        var st = Darwin.stat()
        if Darwin.lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                throw PlayCoverError.playToolsError(
                    "Refused to use non-directory or symlink path: \(url.path)"
                )
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: permissions]
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Re-verify existing directory via lstat below.
        }
        if Darwin.lstat(url.path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR {
            throw PlayCoverError.playToolsError(
                "Failed to verify secure directory: \(url.path)"
            )
        }
    }

    private func prepareLaunchDirectories(bundleID: String) throws {
        let containerRoot = PlayTools.playCoverContainer
        if !FileManager.default.fileExists(atPath: containerRoot.path) {
            try FileManager.default.createDirectory(
                at: containerRoot,
                withIntermediateDirectories: true
            )
        }
        var rootStat = Darwin.stat()
        guard Darwin.lstat(containerRoot.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw PlayCoverError.playToolsError(
                "Refused to prepare directories under non-directory container root."
            )
        }

        let keymappingRoot = containerRoot.appendingPathComponent("Keymapping", isDirectory: true)
        try Self.ensureSecureDirectory(at: keymappingRoot)
        let appKeymapDir = keymappingRoot.appendingPathComponent(bundleID, isDirectory: true)
        try Self.ensureSecureDirectory(at: appKeymapDir)

        if FileManager.default.fileExists(atPath: entitlements.path),
           let entDict = try? [String: Any].read(entitlements) {
            let declaredGroups = EntitlementsComposer.declaredApplicationGroups(from: entDict)
                .filter { EntitlementsComposer.isSafeDeclaredGroupIdentifier($0) }
            if !declaredGroups.isEmpty {
                let appGroupsRoot = containerRoot.appendingPathComponent("AppGroups", isDirectory: true)
                try Self.ensureSecureDirectory(at: appGroupsRoot)
                let appGroupsBundleDir = appGroupsRoot.appendingPathComponent(bundleID, isDirectory: true)
                try Self.ensureSecureDirectory(at: appGroupsBundleDir)
                for groupID in declaredGroups {
                    let groupDir = appGroupsBundleDir.appendingPathComponent(groupID, isDirectory: true)
                    try Self.ensureSecureDirectory(at: groupDir)
                }
            }
        }
    }

    private static func isPlayChainVersionBackup(_ fileName: String, baseName: String) -> Bool {
        guard fileName.hasSuffix(".bak") else { return false }
        let stem = fileName.dropLast(".bak".count)
        for prefix in [baseName + ".db.v", baseName + ".v"] where stem.hasPrefix(prefix) {
            let versionDigits = stem.dropFirst(prefix.count)
            if !versionDigits.isEmpty,
               versionDigits.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) {
                return true
            }
        }
        return false
    }

    func clearPlayChain() {
        FileManager.default.delete(at: playChainURL)
        FileManager.default.delete(at: playChainURL.appendingPathExtension("keyCover"))
        FileManager.default.delete(at: playChainURL.appendingPathExtension("db"))
        FileManager.default.delete(at: URL(fileURLWithPath: playChainURL.path + ".db-wal"))
        FileManager.default.delete(at: URL(fileURLWithPath: playChainURL.path + ".db-shm"))
        FileManager.default.delete(at: URL(fileURLWithPath: playChainURL.path + ".db-journal"))
        let baseName = playChainURL.lastPathComponent
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: KeyCover.playChainPath,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries where Self.isPlayChainVersionBackup(entry.lastPathComponent, baseName: baseName) {
                FileManager.default.delete(at: entry)
            }
        }
    }

    func deleteApp() {
        if let cachedSettings = settingsLock.withLock({ $0 }),
           !FileManager.default.fileExists(atPath: cachedSettings.settingsUrl.path) {
            cachedSettings.discardPendingWrites()
        }
        Self.invalidateVerifiedBundleStamp(for: url)
        FileManager.default.delete(at: URL(fileURLWithPath: url.path))
        if let appsVM = dependencies?.appsVM {
            Task { @MainActor in
                appsVM.fetchApps()
            }
        }
    }

    func signThrowing(targetBundleURL: URL? = nil) throws {
        Self.invalidateVerifiedBundleStamp(for: url)
        if let targetBundleURL {
            Self.invalidateVerifiedBundleStamp(for: targetBundleURL)
        }
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpEnts = tmpDir
            .appendingEscapedPathComponent(ProcessInfo().globallyUniqueString)
            .appendingPathExtension("plist")
        defer {
            if FileManager.default.fileExists(atPath: tmpEnts.path) {
                try? FileManager.default.removeItem(at: tmpEnts)
            }
        }
        let conf = try Entitlements.composeEntitlements(self, targetBundleURL: targetBundleURL)
        try conf.store(tmpEnts)
        try Shell.signAppWith(executable, entitlements: tmpEnts)
    }

    func sign() {
        do {
            try signThrowing()
        } catch {
            print(error)
            PlayCoverDiagnostics.reportError(error)
        }
    }
}

// MARK: - Policies
nonisolated extension PlayApp {
    var prohibitedToPlay: Bool {
        PlayApp.PROHIBITED_APPS.contains(info.bundleIdentifier)
    }

    var maliciousProhibited: Bool {
        PlayApp.MALICIOUS_APPS.contains(info.bundleIdentifier)
    }

    static let PROHIBITED_APPS = [
        "com.activision.callofduty.shooter",
        "com.ea.ios.apexlegendsmobilefps",
        "com.tencent.tmgp.cod",
        "com.tencent.ig",
        "com.pubg.newstate",
        "com.pubg.imobile",
        "com.tencent.tmgp.pubgmhd",
        "com.dts.freefireth",
        "com.dts.freefiremax",
        "vn.vng.codmvn",
        "com.ngame.allstar.eu",
        "com.axlebolt.standoff2",
        "com.tencent.lolm"
    ]

    static let MALICIOUS_APPS = [
        "com.zhiliaoapp.musically"
    ]
}
