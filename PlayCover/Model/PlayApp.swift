//
//  PlayApp.swift
//  PlayCover
//

// swiftlint:disable file_length
import Cocoa
import Combine
import Darwin
import Foundation
import IOKit.pwr_mgt
import PlayCoverCore

class PlayApp: BaseApp, ObservableObject, Identifiable, Hashable {
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
            (try String(contentsOf: bundleIDCacheURL))
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
    }

    private static let verifiedBundleLock = NSLock()
    private static var verifiedBundleStamps: [String: VerifiedBundleStamp] = [:]

    private static func fileStamp(for url: URL) -> (sec: Int, nsec: Int, ino: UInt64) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return (0, 0, 0) }
        return (Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), UInt64(st.st_ino))
    }

    private static func currentBundleStamp(bundleURL: URL, executableURL: URL) -> VerifiedBundleStamp {
        let exec = fileStamp(for: executableURL)
        let codeRes = fileStamp(for: bundleURL.appendingPathComponent("_CodeSignature/CodeResources"))
        let playTools = fileStamp(for: PlayTools.playToolsPath)
        return VerifiedBundleStamp(
            execMTimeSec: exec.sec,
            execMTimeNSec: exec.nsec,
            execIno: exec.ino,
            codeResMTimeSec: codeRes.sec,
            codeResMTimeNSec: codeRes.nsec,
            playToolsMTimeSec: playTools.sec,
            playToolsMTimeNSec: playTools.nsec
        )
    }

    private static func invalidateVerifiedBundleStamp(for bundleURL: URL) {
        verifiedBundleLock.lock()
        verifiedBundleStamps.removeValue(forKey: bundleURL.path)
        verifiedBundleLock.unlock()
    }

    // MARK: - Instance State
    private let assertionLock = NSLock()
    var displaySleepAssertionID: IOPMAssertionID?
    private var _isStarting = false
    private var _sessionDisableKeychain = false
    private var runningApplication: NSRunningApplication?
    @Published var isRunning: Bool = false
    @Published var launchSnapshot: AppSettingsData?
    weak var dependencies: PlayCoverDependencies?

    var restartRequiredChanges: [PlayCoverRestartField] {
        guard isRunning, let launchSnapshot else { return [] }
        return settings.settings.restartRequiredChanges(comparedTo: launchSnapshot)
    }

    public var isStarting: Bool {
        get {
            assertionLock.lock()
            defer { assertionLock.unlock() }
            return _isStarting
        }
        set {
            assertionLock.lock()
            _isStarting = newValue
            assertionLock.unlock()
        }
    }

    var sessionDisableKeychain: Bool {
        get {
            assertionLock.lock()
            defer { assertionLock.unlock() }
            return _sessionDisableKeychain
        }
        set {
            assertionLock.lock()
            _sessionDisableKeychain = newValue
            assertionLock.unlock()
        }
    }

    // MARK: - Init
    init(appUrl: URL, dependencies: PlayCoverDependencies? = nil) {
        self.dependencies = dependencies
        super.init(appUrl: appUrl)
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
    lazy var playChainURL = KeyCover.playChainPath.appendingPathComponent(info.bundleIdentifier)

    lazy var settings = AppSettings(info)
    lazy var keymapping = Keymapping(info, alertPresenter: dependencies?.alertPresenter)
    lazy var container = AppContainer(bundleId: info.bundleIdentifier)

    // MARK: - Launch
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func launch(safeModeOneShot: Bool = false) async {
        isStarting = true
        defer { isStarting = false }

        do {
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

            let binaryInfo = try? Macho.inspectBinary(
                atURL: executable,
                playToolsPath: PlayTools.playToolsPath.path
            )
            let usesPlayTools = binaryInfo?.hasPlayTools ?? hasPlayTools()
            var pluginsModified = false
            if usesPlayTools {
                await PlayTools.waitForSystemInstall()
                pluginsModified = try PlayTools.installPluginInIPA(url)
            }

            let binaryModified = try Macho.fixLibrariesIfNeeded(atURL: executable)
            let entitlementsInvalid = try !Entitlements.areEntitlementsValid(app: self)

            if entitlementsInvalid {
                Self.invalidateVerifiedBundleStamp(for: url)
                try signThrowing()
                try Shell.verifyAppSignature(url)
                let stamp = Self.currentBundleStamp(bundleURL: url, executableURL: executable)
                Self.verifiedBundleLock.lock()
                Self.verifiedBundleStamps[url.path] = stamp
                Self.verifiedBundleLock.unlock()
            } else if binaryModified || pluginsModified || !isBundleSignatureStrictlyValid() {
                Self.invalidateVerifiedBundleStamp(for: url)
                do {
                    try Shell.signApp(executable)
                    try Shell.verifyAppSignature(url)
                } catch {
                    try signThrowing()
                    try Shell.verifyAppSignature(url)
                }
                let stamp = Self.currentBundleStamp(bundleURL: url, executableURL: executable)
                Self.verifiedBundleLock.lock()
                Self.verifiedBundleStamps[url.path] = stamp
                Self.verifiedBundleLock.unlock()
            }

            if try (usesPlayTools && !PlayTools.isInstalled()) {
                if let installErr = PlayTools.systemInstallFailure() {
                    PlayCoverDiagnostics.reportError("PlayTools installation failed: \(installErr.localizedDescription)")
                } else {
                    PlayCoverDiagnostics.reportError(
                        "PlayTools are not installed! Please move MacOver.app into Applications!"
                    )
                }
                return
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

            // Wait for keychain unlock to finish before continuing
            await unlockKeyCover()

            // Clear any debug-related env vars that could affect the launched app
            self.clearDebugAffectingEnvironment()

            let hadContainer = container.doesExist()
            if settings.settings.discordActivity.enable {
                loadDiscordIPC()
            } else {
                releaseDiscordIPC()
            }

            do {
                settings.flush()
                if settings.openWithLLDB {
                    try Shell.lldb(executable, withTerminalWindow: settings.openLLDBWithTerminal)
                } else {
                    ensureAliasUpToDate()

                    try await runAppExec(
                        discordAlreadyLinked: hadContainer && settings.settings.discordActivity.enable,
                        safeModeOneShot: safeModeOneShot
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
extension PlayApp {
    static let introspection: String = "/usr/lib/system/introspection"
    static let iosFrameworks: String = "/System/iOSSupport/System/Library/Frameworks"

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

    // clear environment variables that can force debug wrappers or validation layers
    func clearDebugAffectingEnvironment() {
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }
        for key in PlayApp.metalEnvKeys {
            unsetenv(key)
        }
    }

    func runAppExec(discordAlreadyLinked: Bool = false, safeModeOneShot: Bool = false) async throws {
        let launchDate = Date()
        let config = NSWorkspace.OpenConfiguration()
        if safeModeOneShot {
            var env = config.environment
            env["PLAYTOOLS_SAFE_MODE"] = "1"
            config.environment = env
        }
        let launchedSettings = settings.settings

        let targetURL = url
        let targetPath = targetURL.path
        let runningApp: NSRunningApplication? = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: targetURL,
                configuration: config,
                completionHandler: { app, error in
                    if let error {
                        PlayCoverDiagnostics.log("LaunchServices failed to open \(targetPath): \(error)", isError: true)
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: app)
                    }
                }
            )
        }

        if let runningApp {
            setRunningApplication(runningApp)
            await MainActor.run {
                self.launchSnapshot = launchedSettings
                self.isRunning = true
            }

            Task(priority: .utility) {
                defer {
                    let isSameProcess = self.clearRunningApplicationIfMatches(
                        processIdentifier: runningApp.processIdentifier
                    )
                    if isSameProcess {
                        Task { @MainActor in
                            if self.snapshotRunningApplication() == nil {
                                self.isRunning = false
                                self.launchSnapshot = nil
                            }
                        }
                    }

                    self.enableTimeOut()
                    self.releaseDiscordIPC()
                    self.lockKeyCover()

                    let elapsed = Date().timeIntervalSince(launchDate)
                    let breadcrumbURL = self.container.containerUrl
                        .appendingPathComponent("Data/Library/Caches/app.makedie.PlayTools/.launching_in_progress")
                    if elapsed < 3.0 && FileManager.default.fileExists(atPath: breadcrumbURL.path) {
                        let msg = "\(self.name) exited abnormally within 3 seconds; next launch will automatically use Safe Mode."
                        PlayCoverDiagnostics.log(msg, isError: true)
                        PlayCoverDiagnostics.showToast(
                            toastType: .error,
                            toastDetails: msg,
                            timeRemaining: 5
                        )
                        let appName = self.name
                        let bundleID = self.info.bundleIdentifier
                        let crumbPath = breadcrumbURL.path
                        let startupAlerts = self.dependencies?.startupAlerts
                        Task { @MainActor in
                            startupAlerts?.enqueue(
                                .safeModeActivated(
                                    appName: appName,
                                    bundleID: bundleID,
                                    breadcrumbPath: crumbPath
                                )
                            )
                        }
                    }
                }
                let targetPID = runningApp.processIdentifier
                var discordLinked = discordAlreadyLinked
                let syncLock = NSLock()

                let tryLinkDiscordIfNeeded = {
                    syncLock.lock()
                    let alreadyLinked = discordLinked
                    syncLock.unlock()
                    if !alreadyLinked && self.settings.settings.discordActivity.enable && self.container.doesExist() {
                        self.loadDiscordIPC()
                        syncLock.lock()
                        discordLinked = true
                        syncLock.unlock()
                    }
                }

                if runningApp.isActive {
                    self.disableTimeOut()
                }
                tryLinkDiscordIfNeeded()

                let wsCenter = NSWorkspace.shared.notificationCenter
                var activateObserver: NSObjectProtocol?
                var deactivateObserver: NSObjectProtocol?
                var terminateObserver: NSObjectProtocol?
                defer {
                    if let activateObserver { wsCenter.removeObserver(activateObserver) }
                    if let deactivateObserver { wsCenter.removeObserver(deactivateObserver) }
                    if let terminateObserver { wsCenter.removeObserver(terminateObserver) }
                }

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    var resumed = false
                    func completeTermination() {
                        syncLock.lock()
                        guard !resumed else {
                            syncLock.unlock()
                            return
                        }
                        resumed = true
                        syncLock.unlock()
                        continuation.resume()
                    }

                    activateObserver = wsCenter.addObserver(
                        forName: NSWorkspace.didActivateApplicationNotification,
                        object: nil,
                        queue: nil
                    ) { notification in
                        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication,
                              app.processIdentifier == targetPID else {
                            return
                        }
                        self.disableTimeOut()
                        tryLinkDiscordIfNeeded()
                    }

                    deactivateObserver = wsCenter.addObserver(
                        forName: NSWorkspace.didDeactivateApplicationNotification,
                        object: nil,
                        queue: nil
                    ) { notification in
                        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication,
                              app.processIdentifier == targetPID else {
                            return
                        }
                        self.enableTimeOut()
                    }

                    terminateObserver = wsCenter.addObserver(
                        forName: NSWorkspace.didTerminateApplicationNotification,
                        object: nil,
                        queue: nil
                    ) { notification in
                        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication,
                              app.processIdentifier == targetPID else {
                            return
                        }
                        completeTermination()
                    }

                    if runningApp.isTerminated {
                        completeTermination()
                    }
                }
            }
        } else {
            self.enableTimeOut()
            self.releaseDiscordIPC()
            self.lockKeyCover()
        }
    }

    private func setRunningApplication(_ app: NSRunningApplication) {
        assertionLock.withLock {
            runningApplication = app
        }
    }

    private func clearRunningApplicationIfMatches(processIdentifier: pid_t) -> Bool {
        assertionLock.withLock {
            guard runningApplication?.processIdentifier == processIdentifier else {
                return false
            }
            runningApplication = nil
            return true
        }
    }

    private func snapshotRunningApplication() -> NSRunningApplication? {
        assertionLock.withLock { runningApplication }
    }

    func terminate() async {
        let current = snapshotRunningApplication()
        guard let current, !current.isTerminated else { return }

        _ = current.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while !current.isTerminated && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !current.isTerminated {
            _ = current.forceTerminate()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func restart(safeModeOneShot: Bool = false) async {
        await terminate()
        await launch(safeModeOneShot: safeModeOneShot)
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
    var sortDevice: String { settings.settings.iosDeviceModel }
    var sortPixelRatio: Double { settings.settings.pixelBudget.ratio }
    var sortRunningRank: Int { isRunning ? 0 : 1 }
}

// MARK: - Management
extension PlayApp {
    func disableTimeOut() {
        assertionLock.lock()
        defer { assertionLock.unlock() }
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

    func enableTimeOut() {
        assertionLock.lock()
        defer { assertionLock.unlock() }
        if let assertionID = displaySleepAssertionID {
            IOPMAssertionRelease(assertionID)
            displaySleepAssertionID = nil
        }
    }
}

// MARK: - KeyCover
extension PlayApp {
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
extension PlayApp {
    func hasPlayTools() -> Bool {
        do {
            return try PlayTools.installedInExec(atURL: url.appendingEscapedPathComponent(info.executableName))
        } catch {
            PlayCoverDiagnostics.reportError(error)
            return true
        }
    }

    func changeDyldLibraryPath(set: Bool? = nil, path: String) async -> Bool {
        var env = info.lsEnvironment
        var entries = (env["DYLD_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        if let set = set {
            if set {
                if !entries.contains(path) {
                    entries.append(path)
                }
            } else {
                entries.removeAll { $0 == path }
            }

            if entries.isEmpty {
                env.removeValue(forKey: "DYLD_LIBRARY_PATH")
            } else {
                env["DYLD_LIBRARY_PATH"] = entries.joined(separator: ":")
            }
            info.lsEnvironment = env
            Self.invalidateVerifiedBundleStamp(for: url)

            do {
                try Shell.signApp(executable)
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }

        return entries.contains(path)
    }
}

// MARK: - FS / Codesign
extension PlayApp {
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
            Self.verifiedBundleLock.lock()
            let cached = Self.verifiedBundleStamps[url.path] == stamp
            Self.verifiedBundleLock.unlock()
            if cached {
                return true
            }
            try Shell.verifyAppSignature(url)
            Self.verifiedBundleLock.lock()
            Self.verifiedBundleStamps[url.path] = stamp
            Self.verifiedBundleLock.unlock()
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
                toastDetails: "应用尚未生成数据目录，请先启动一次应用"
            )
        }
    }

    @discardableResult
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

    func clearPlayChain() {
        FileManager.default.delete(at: playChainURL)
        FileManager.default.delete(at: playChainURL.appendingPathExtension("keyCover"))
        FileManager.default.delete(at: playChainURL.appendingPathExtension("db"))
        FileManager.default.delete(at: URL(fileURLWithPath: playChainURL.path + ".db-wal"))
        FileManager.default.delete(at: URL(fileURLWithPath: playChainURL.path + ".db-shm"))
        let dbPrefix = playChainURL.lastPathComponent + ".db.v"
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: KeyCover.playChainPath,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix(dbPrefix) {
                FileManager.default.delete(at: entry)
            }
        }
    }

    func deleteApp() {
        Self.invalidateVerifiedBundleStamp(for: url)
        FileManager.default.delete(at: URL(fileURLWithPath: url.path))
        dependencies?.appsVM.fetchApps()
    }

    func signThrowing() throws {
        Self.invalidateVerifiedBundleStamp(for: url)
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpEnts = tmpDir
            .appendingEscapedPathComponent(ProcessInfo().globallyUniqueString)
            .appendingPathExtension("plist")
        defer {
            if FileManager.default.fileExists(atPath: tmpEnts.path) {
                try? FileManager.default.removeItem(at: tmpEnts)
            }
        }
        let conf = try Entitlements.composeEntitlements(self)
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
extension PlayApp {
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
