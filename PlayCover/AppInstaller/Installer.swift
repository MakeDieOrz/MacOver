//
//  Installer.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 24.11.2021.
//

import Darwin
import Foundation
import Synchronization

nonisolated class Installer {
    static let installGenerationInfoKey = PlayCoverInstaller.AppBackupManifest.installGenerationInfoKey
    static let backupManifestFileName = PlayCoverInstaller.AppBackupManifest.backupManifestFileName

    typealias AppBackupManifest = PlayCoverInstaller.AppBackupManifest
    typealias AppBackupStagingResult = PlayCoverInstaller.AppBackupStagingResult
    typealias AppBackupCommitOutcome = PlayCoverInstaller.AppBackupCommitOutcome
    typealias PathPresence = PlayCoverInstaller.PathPresence

    @MainActor
    static func installPlayToolsPopup(
        alertPresenter: AlertPresenter? = nil,
        installPreferences: InstallPreferences? = nil
    ) async -> Bool {
        let presenter = alertPresenter ?? AlertPresenter()
        let prefs = installPreferences ?? InstallPreferences()
        let response = await presenter.present(
            PlayCoverAlertRequest(
                title: NSLocalizedString("alert.install.injectPlayToolsQuestion", comment: ""),
                message: NSLocalizedString("alert.install.playToolsInformative", comment: ""),
                style: .informational,
                buttons: [
                    PlayCoverAlertButton(title: NSLocalizedString("button.Yes", comment: "")),
                    PlayCoverAlertButton(title: NSLocalizedString("button.No", comment: ""), isCancel: true)
                ],
                suppressionTitle: NSLocalizedString("alert.supression", comment: "String"),
                defaultCancelIndex: 1
            )
        )

        let shouldInstall = response.buttonIndex == 0
        if response.suppressionChecked {
            prefs.showInstallPopup = false
            prefs.alwaysInstallPlayTools = shouldInstall
        }

        return shouldInstall
    }

    static private func returnErrorString(error: Error) -> String {
        switch error.localizedDescription {
        case let str where str.contains("(disk full?)"): NSLocalizedString("alert.notSpace", comment: "")
        case let str where str.contains(".html"): NSLocalizedString("alert.quota.limit", comment: "")
        case let str where str.contains(".ipa"): NSLocalizedString("alert.corrupted", comment: "")
        default: NSLocalizedString(error.localizedDescription, comment: "")
        }
    }

    static func install(
        ipaUrl: URL,
        export: Bool,
        dependencies: PlayCoverDependencies? = nil,
        returnCompletion: @escaping @Sendable (URL?) -> Void
    ) {
        Task { @MainActor in
            let installVM = dependencies?.installVM ?? InstallVM()
            let installPreferences = dependencies?.installPreferences ?? InstallPreferences()
            let modifierObserver = dependencies?.modifierKeyObserver
            let alertPresenter = dependencies?.alertPresenter

            // If (the option key is held or the install playtools popup settings is true) and its not an export,
            //    then show the installer dialog
            let installPlayTools: Bool
            let applicationType = installPreferences.defaultAppType

            if ((modifierObserver?.isOptionKeyPressed ?? false)
                    || installPreferences.showInstallPopup) && !export {
                installPlayTools = await installPlayToolsPopup(
                    alertPresenter: alertPresenter,
                    installPreferences: installPreferences
                )
            } else {
                installPlayTools = installPreferences.alwaysInstallPlayTools
            }

            installVM.next(.begin, 0.05, 0.10)

            Task.detached(priority: .userInitiated) {
                let ipa = IPA(url: ipaUrl)
                defer { ipa.releaseTempDir() }

                var touchedEntitlementsState: (url: URL, existedBefore: Bool, previousData: Data?)?
                var touchedSettingsState: (url: URL, existedBefore: Bool, previousData: Data?)?
                var quarantinedAppBackups: (quarantinedDir: URL, targetDir: URL, bundleID: String)?
                var unrolledPublishedBackupsTarget: (dir: URL, bundleID: String)?

                do {
                installVM.next(.unzip, 0.10, 0.45)
                try ipa.allocateTempDir()

                let unzipProgressTask = Task.detached(priority: .utility) {
                    let start = Date()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { break }
                        let elapsed = Date().timeIntervalSince(start)
                        let fraction = 1.0 - exp(-elapsed / 6.0)
                        installVM.updateStepProgress(min(0.95, fraction))
                    }
                }
                let app: BaseApp
                do {
                    app = try ipa.unzip()
                } catch {
                    unzipProgressTask.cancel()
                    throw error
                }
                unzipProgressTask.cancel()
                installVM.updateProgress(0.45)

                if await ipa.checkOfficialMacOS(
                    app: IPA.Application.base(app),
                    alertPresenter: alertPresenter,
                    installPreferences: installPreferences
                ) {
                    installVM.next(.failed, 0.95, 1.0)
                    returnCompletion(nil)
                    return
                }
                installVM.next(.playtools, 0.45, 0.70)
                let machos = resolveValidMachOs(app)
                app.validMachOs = machos

                for macho in machos where try Macho.isMachoEncrypted(atURL: macho) {
                    throw PlayCoverError.appEncrypted
                }

                if !app.info.bundleIdentifier.isEmpty,
                   !isSafeBundleIdentifierForStorage(app.info.bundleIdentifier) {
                    throw PlayCoverError.playToolsError(
                        "Invalid bundle identifier for local storage: \(app.info.bundleIdentifier)"
                    )
                }

                let entitlementsURL = app.entitlements
                var entStat = stat()
                let entitlementsExistedBefore = Darwin.lstat(entitlementsURL.path, &entStat) == 0
                let previousEntitlementsData = entitlementsExistedBefore
                    ? (try? Data(contentsOf: entitlementsURL))
                    : nil
                try saveEntitlements(app)
                touchedEntitlementsState = (entitlementsURL, entitlementsExistedBefore, previousEntitlementsData)

                let backupStagingResult: AppBackupStagingResult
                if !export, !app.info.bundleIdentifier.isEmpty {
                    if let stagingURL = ipa.tmpDir?.appendingPathComponent("AppBackupsStaging") {
                        backupStagingResult = stageAppBackups(for: app, in: stagingURL)
                    } else {
                        backupStagingResult = .failed
                    }
                } else {
                    backupStagingResult = .noneApplicable
                }

                for macho in machos where !export {
                    try Macho.convertMacho(macho)
                    if macho != app.executable {
                        try Shell.signMacho(macho)
                    }
                }
                installVM.updateProgress(0.58)

                if export {
                    try PlayTools.injectInIPA(app.executable, payload: app.url)
                } else if installPlayTools {
                    try await PlayTools.installInIPA(app.executable, appInfo: app.info, signBundle: false)
                }
                installVM.updateProgress(0.66)

                app.info.setApplicationCategoryType(applicationType, persist: false)

                if !export {
                    // -rwxr-xr-x
                    try app.executable.setBinaryPosixPermissions(0o755)
                    try removeMobileProvision(app)
                }

                let info = app.info
                if !export, !info.bundleIdentifier.isEmpty {
                    let originalMinimumOSVersion = info.minimumOSVersion
                    let settingsURL = AppSettings.settingsURL(forBundleIdentifier: info.bundleIdentifier)
                    var settingsStat = stat()
                    let settingsExistedBefore = Darwin.lstat(settingsURL.path, &settingsStat) == 0
                    let previousSettingsData = settingsExistedBefore
                        ? (try? Data(contentsOf: settingsURL))
                        : nil
                    touchedSettingsState = (settingsURL, settingsExistedBefore, previousSettingsData)
                    let appSettings = AppSettings(info)
                    appSettings.update { updatedSettings in
                        updatedSettings.originalBundleName = app.url.lastPathComponent
                        updatedSettings.originalMinimumOSVersion = originalMinimumOSVersion.isEmpty
                            ? nil
                            : originalMinimumOSVersion
                    }
                    appSettings.flush()
                    info[string: Installer.installGenerationInfoKey] = UUID().uuidString
                }
                info.assert(minimumVersion: 11.0)
                try info.write()
                installVM.next(.sign, 0.70, 0.86)

                var finalURL: URL

                if export {
                    finalURL = try ipa.packIPABack(app: app.url)
                    installVM.next(.library, 0.86, 0.96)
                    try? ipa.removeQuarantine(finalURL)
                } else {
                    let targetBundleID = info.bundleIdentifier
                    let targetBackupsDir = app.appBackupsDir
                    finalURL = try publishSignedBundle(
                        app,
                        into: AppsVM.appDirectory,
                        prepareAndVerify: { stagedBundleURL, finalLocationURL in
                            try? ipa.removeQuarantine(stagedBundleURL)
                            let stagedApp = PlayApp(appUrl: stagedBundleURL, dependencies: dependencies)
                            try stagedApp.signThrowing(targetBundleURL: finalLocationURL)
                            installVM.next(.library, 0.86, 0.96)
                            try Shell.verifyAppSignature(stagedBundleURL)
                            installVM.updateProgress(0.92)
                        },
                        beforeSwap: {
                            if !targetBundleID.isEmpty,
                               let quarantinedDir = try quarantineAppBackups(
                                   at: targetBackupsDir,
                                   bundleIdentifier: targetBundleID
                               ) {
                                quarantinedAppBackups = (quarantinedDir, targetBackupsDir, targetBundleID)
                            }
                        },
                        afterSwap: { publishedURL in
                            let installedApp = PlayApp(appUrl: publishedURL, dependencies: dependencies)
                            let installedBundleID = installedApp.info.bundleIdentifier
                            if !installedBundleID.isEmpty {
                                try finalizeAppBackupsAfterSwap(
                                    backupStagingResult,
                                    for: installedApp,
                                    quarantinedDir: quarantinedAppBackups?.quarantinedDir
                                )
                                quarantinedAppBackups = nil
                                try? FileManager.default.removeItem(at: installedApp.svcPatchManifestURL)
                            }
                            try? ipa.removeQuarantine(publishedURL)
                            installVM.updateProgress(0.96)
                        },
                        onUnrecoverableRollbackFailure: { publishedURL, preservedPreviousURL in
                            if let preservedPreviousURL {
                                PlayCoverDiagnostics.log(
                                    "Unrecoverable rollback for \(targetBundleID): previous app bundle preserved at " +
                                        "\(preservedPreviousURL.path)",
                                    isError: true
                                )
                            }
                            let strandedApp = BaseApp(appUrl: publishedURL)
                            let bid = strandedApp.info.bundleIdentifier.isEmpty
                                ? targetBundleID
                                : strandedApp.info.bundleIdentifier
                            if !bid.isEmpty {
                                unrolledPublishedBackupsTarget = (strandedApp.appBackupsDir, bid)
                            }
                        }
                    )
                }

                installVM.next(.finish, 0.96, 1.0)
                returnCompletion(finalURL)
            } catch {
                if let unrolledPublishedBackupsTarget {
                    if !invalidateAppBackups(
                        at: unrolledPublishedBackupsTarget.dir,
                        bundleIdentifier: unrolledPublishedBackupsTarget.bundleID
                    ) {
                        PlayCoverDiagnostics.log(
                            "Failed to evict AppBackups after unrolled publish for " +
                                "\(unrolledPublishedBackupsTarget.bundleID)",
                            isError: true
                        )
                    }
                    let excludedQuarantined: Set<URL> = quarantinedAppBackups.map { [$0.quarantinedDir] } ?? []
                    cleanupInvalidatedAppBackups(
                        primary: nil,
                        in: unrolledPublishedBackupsTarget.dir.deletingLastPathComponent(),
                        bundleIdentifier: unrolledPublishedBackupsTarget.bundleID,
                        excluding: excludedQuarantined
                    )
                } else if let quarantinedAppBackups {
                    var canRestoreQuarantined = true
                    switch probePathPresence(at: quarantinedAppBackups.targetDir) {
                    case .absent:
                        canRestoreQuarantined = true
                    case .present:
                        canRestoreQuarantined = invalidateAppBackups(
                            at: quarantinedAppBackups.targetDir,
                            bundleIdentifier: quarantinedAppBackups.bundleID
                        )
                    case .queryFailed(let err):
                        PlayCoverDiagnostics.log(
                            "Failed to query target AppBackups during rollback for " +
                                "\(quarantinedAppBackups.bundleID): \(String(cString: strerror(err))) (errno=\(err))",
                            isError: true
                        )
                        canRestoreQuarantined = false
                    }
                    var restoredQuarantined = false
                    if canRestoreQuarantined {
                        restoredQuarantined = restoreQuarantinedAppBackups(
                            quarantinedAppBackups.quarantinedDir,
                            to: quarantinedAppBackups.targetDir,
                            bundleIdentifier: quarantinedAppBackups.bundleID
                        )
                    }
                    let preservedQuarantined: Set<URL> = restoredQuarantined
                        ? []
                        : [quarantinedAppBackups.quarantinedDir]
                    cleanupInvalidatedAppBackups(
                        primary: nil,
                        in: quarantinedAppBackups.targetDir.deletingLastPathComponent(),
                        bundleIdentifier: quarantinedAppBackups.bundleID,
                        excluding: preservedQuarantined
                    )
                }
                if unrolledPublishedBackupsTarget == nil {
                    if let touchedEntitlementsState {
                        restoreRollbackFile(
                            at: touchedEntitlementsState.url,
                            existedBefore: touchedEntitlementsState.existedBefore,
                            previousData: touchedEntitlementsState.previousData,
                            label: "entitlements"
                        )
                    }
                    if let touchedSettingsState {
                        restoreRollbackFile(
                            at: touchedSettingsState.url,
                            existedBefore: touchedSettingsState.existedBefore,
                            previousData: touchedSettingsState.previousData,
                            label: "settings"
                        )
                    }
                } else {
                    PlayCoverDiagnostics.log(
                        "Keeping updated entitlements/settings because published bundle could not be rolled back",
                        isError: true
                    )
                }
                PlayCoverDiagnostics.reportError(returnErrorString(error: error))
                installVM.next(.failed, 0.95, 1.0)
                returnCompletion(nil)
            }
            }
        }
    }

    static func fromIPA(detectingAppNameInFolder folderURL: URL) throws -> BaseApp {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)

        var url: URL?

        for entry in contents {
            guard entry.hasSuffix(".app") else {
                continue
            }

            let entryURL = folderURL.appendingEscapedPathComponent(entry)
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            url = entryURL
            break
        }

        guard let url = url else {
            throw PlayCoverError.infoPlistNotFound
        }

        return BaseApp(appUrl: url)
    }

    /// Returns an array of URLs to MachO files within the app
    static func resolveValidMachOs(_ baseApp: BaseApp) -> [URL] {
        if let validMachOs = baseApp.validMachOs {
            return validMachOs
        }

        let resolved = Mutex<[URL]>([])

        baseApp.url.enumerateContents { url, attributes in
            guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize > 4 else {
                return
            }

            if !url.pathExtension.isEmpty && url.pathExtension != "dylib" {
                return
            }

            let handle = try FileHandle(forReadingFrom: url)

            defer {
                do {
                    try handle.close()
                } catch {
                    print("Failed to close FileHandle for \(url.absoluteString): \(error.localizedDescription)")
                }
            }

            guard let data = try handle.read(upToCount: 4) else {
                return
            }

            switch Array(data) {
            case [202, 254, 186, 190], [190, 186, 254, 202],
                 [202, 254, 186, 191], [191, 186, 254, 202],
                 [207, 250, 237, 254], [254, 237, 250, 207]:
                resolved.withLock { $0.append(url) }
            default:
                return
            }
        }

        return resolved.withLock { $0 }
    }

    /// Wrapper for codesign, applies the given entitlements to the application and all of its contents
    static func saveEntitlements(_ baseApp: BaseApp) throws {
        var toSave = try Entitlements.dumpEntitlements(exec: baseApp.executable)
        let groupKey = "com.apple.security.application-groups"
        if toSave[groupKey] == nil,
           FileManager.default.fileExists(atPath: baseApp.entitlements.path),
           let existing = try? [String: Any].read(baseApp.entitlements),
           let existingGroups = existing[groupKey] {
            let hasNonEmptyGroups: Bool
            if let array = existingGroups as? [String] {
                hasNonEmptyGroups = !array.isEmpty
            } else if let str = existingGroups as? String {
                hasNonEmptyGroups = !str.isEmpty
            } else if let array = existingGroups as? [Any] {
                hasNonEmptyGroups = !array.isEmpty
            } else {
                hasNonEmptyGroups = false
            }
            if hasNonEmptyGroups {
                toSave[groupKey] = existingGroups
            }
        }
        try toSave.store(baseApp.entitlements)
    }

    static func removeMobileProvision(_ baseApp: BaseApp) throws {
        let provision = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }
    }

    static func restoreRollbackFile(at url: URL, existedBefore: Bool, previousData: Data?, label: String) {
        BackupTransactionStore.restoreRollbackFile(
            at: url,
            existedBefore: existedBefore,
            previousData: previousData,
            label: label
        )
    }

    static func stageAppBackups(for baseApp: BaseApp, in stagingDir: URL) -> AppBackupStagingResult {
        BackupTransactionStore.stageAppBackups(
            bundleURL: baseApp.url,
            executableURL: baseApp.executable,
            in: stagingDir
        )
    }

    private static func isSubpath(_ candidate: URL, of directory: URL) -> Bool {
        BackupTransactionStore.isSubpath(candidate, of: directory)
    }

    static func probePathPresence(at targetURL: URL) -> PathPresence {
        BackupTransactionStore.probePathPresence(at: targetURL)
    }

    static func isSafeBundleIdentifierForStorage(_ bundleIdentifier: String) -> Bool {
        BackupTransactionStore.isSafeBundleIdentifierForStorage(bundleIdentifier)
    }

    static func quarantineAppBackups(at targetDir: URL, bundleIdentifier: String) throws -> URL? {
        try BackupTransactionStore.quarantineAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier)
    }

    @discardableResult
    static func restoreQuarantinedAppBackups(
        _ quarantinedDir: URL,
        to targetDir: URL,
        bundleIdentifier: String
    ) -> Bool {
        BackupTransactionStore.restoreQuarantinedAppBackups(
            quarantinedDir,
            to: targetDir,
            bundleIdentifier: bundleIdentifier
        )
    }

    static func cleanupInvalidatedAppBackups(
        primary: URL?,
        in parentDir: URL,
        bundleIdentifier: String,
        excluding excludedURLs: Set<URL> = []
    ) {
        BackupTransactionStore.cleanupInvalidatedAppBackups(
            primary: primary,
            in: parentDir,
            bundleIdentifier: bundleIdentifier,
            excluding: excludedURLs
        )
    }

    static func invalidateAppBackups(at targetDir: URL, bundleIdentifier: String) -> Bool {
        BackupTransactionStore.invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier)
    }

    static func verifyAppBackupManifest(in backupDir: URL, for appInfo: AppInfo) -> Bool {
        BackupTransactionStore.verifyAppBackupManifest(in: backupDir, for: appInfo)
    }

    static func validateOrInvalidateAppBackupsForLaunch(
        at backupDir: URL,
        for appInfo: AppInfo
    ) throws {
        try BackupTransactionStore.validateOrInvalidateAppBackupsForLaunch(at: backupDir, for: appInfo)
    }

    @discardableResult
    static func finalizeAppBackupsAfterSwap(
        _ stagingResult: AppBackupStagingResult,
        for installedApp: BaseApp,
        quarantinedDir: URL?
    ) throws -> AppBackupCommitOutcome {
        try BackupTransactionStore.finalizeAppBackupsAfterSwap(
            stagingResult,
            to: installedApp.appBackupsDir,
            bundleIdentifier: installedApp.info.bundleIdentifier,
            manifest: AppBackupManifest(appInfo: installedApp.info),
            quarantinedDir: quarantinedDir
        )
    }

    @discardableResult
    static func finalizeAppBackupsAfterSwap(
        _ stagingResult: AppBackupStagingResult,
        to targetDir: URL,
        bundleIdentifier: String,
        manifest: AppBackupManifest?,
        quarantinedDir: URL?
    ) throws -> AppBackupCommitOutcome {
        try BackupTransactionStore.finalizeAppBackupsAfterSwap(
            stagingResult,
            to: targetDir,
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            quarantinedDir: quarantinedDir
        )
    }

    @discardableResult
    static func commitAppBackups(
        _ stagingResult: AppBackupStagingResult,
        for installedApp: BaseApp
    ) throws -> AppBackupCommitOutcome {
        try BackupTransactionStore.commitAppBackups(
            stagingResult,
            to: installedApp.appBackupsDir,
            bundleIdentifier: installedApp.info.bundleIdentifier,
            manifest: AppBackupManifest(appInfo: installedApp.info)
        )
    }

    static func replaceBackupDirectoryAtomically(
        incomingDir: URL,
        targetDir: URL,
        parentDir: URL,
        bundleIdentifier: String,
        allowRenameSwap: Bool = true
    ) throws {
        try BackupTransactionStore.replaceBackupDirectoryAtomically(
            incomingDir: incomingDir,
            targetDir: targetDir,
            parentDir: parentDir,
            bundleIdentifier: bundleIdentifier,
            allowRenameSwap: allowRenameSwap
        )
    }

    @discardableResult
    static func commitAppBackups(
        _ stagingResult: AppBackupStagingResult,
        to targetDir: URL,
        bundleIdentifier: String,
        manifest: AppBackupManifest?
    ) throws -> AppBackupCommitOutcome {
        try BackupTransactionStore.commitAppBackups(
            stagingResult,
            to: targetDir,
            bundleIdentifier: bundleIdentifier,
            manifest: manifest
        )
    }

    private static func preserveDisplacedBundleOnRollbackFailure(
        _ displacedPreviousURL: URL,
        beside location: URL,
        stagingRoot: URL
    ) -> (preservedURL: URL, outsideStagingRoot: Bool) {
        let fm = FileManager.default
        if !isSubpath(displacedPreviousURL, of: stagingRoot) {
            PlayCoverDiagnostics.log(
                "Critical: rollback failed for \(location.lastPathComponent); " +
                    "previous app bundle preserved at \(displacedPreviousURL.path)",
                isError: true
            )
            return (displacedPreviousURL, true)
        }
        let rescuedSiblingURL = location.deletingLastPathComponent().appendingPathComponent(
            ".\(location.lastPathComponent).rollback-\(UUID().uuidString)"
        )
        if Darwin.rename(displacedPreviousURL.path, rescuedSiblingURL.path) == 0 {
            PlayCoverDiagnostics.log(
                "Critical: rollback failed for \(location.lastPathComponent); " +
                    "previous app bundle moved beside target at \(rescuedSiblingURL.path)",
                isError: true
            )
            return (rescuedSiblingURL, true)
        }
        do {
            try fm.moveItem(at: displacedPreviousURL, to: rescuedSiblingURL)
            PlayCoverDiagnostics.log(
                "Critical: rollback failed for \(location.lastPathComponent); " +
                    "previous app bundle moved beside target at \(rescuedSiblingURL.path)",
                isError: true
            )
            return (rescuedSiblingURL, true)
        } catch {
            PlayCoverDiagnostics.log(
                "Critical: rollback failed for \(location.lastPathComponent) and could not relocate " +
                    "previous bundle beside target (\(error)); retaining staging copy at \(displacedPreviousURL.path)",
                isError: true
            )
            return (displacedPreviousURL, false)
        }
    }

    private static func rollbackBundleSwap(
        location: URL,
        displacedPreviousURL: URL?,
        stagingRoot: URL
    ) -> Bool {
        let fm = FileManager.default
        if let displacedPreviousURL {
            var prevStat = stat()
            guard Darwin.lstat(displacedPreviousURL.path, &prevStat) == 0 else {
                return false
            }
            var locStat = stat()
            if Darwin.lstat(location.path, &locStat) == 0 {
                if Darwin.renamex_np(displacedPreviousURL.path, location.path, UInt32(RENAME_SWAP)) == 0 {
                    if !isSubpath(displacedPreviousURL, of: stagingRoot) {
                        try? fm.removeItem(at: displacedPreviousURL)
                    }
                    return true
                }
                let stagingParkURL = stagingRoot.appendingPathComponent("failed-\(UUID().uuidString).app")
                let siblingParkURL = location.deletingLastPathComponent().appendingPathComponent(
                    ".\(location.lastPathComponent).failed-\(UUID().uuidString)"
                )
                var parkedNewURL: URL?
                if Darwin.rename(location.path, stagingParkURL.path) == 0 {
                    parkedNewURL = stagingParkURL
                } else if (try? fm.moveItem(at: location, to: stagingParkURL)) != nil {
                    parkedNewURL = stagingParkURL
                } else if Darwin.rename(location.path, siblingParkURL.path) == 0 {
                    parkedNewURL = siblingParkURL
                } else if (try? fm.moveItem(at: location, to: siblingParkURL)) != nil {
                    parkedNewURL = siblingParkURL
                } else {
                    PlayCoverDiagnostics.log(
                        "Critical: failed to move aside published app bundle at \(location.lastPathComponent) " +
                            "during rollback; keeping both bundles untouched",
                        isError: true
                    )
                    return false
                }

                let restoredToLocation: Bool
                if Darwin.rename(displacedPreviousURL.path, location.path) == 0 {
                    restoredToLocation = true
                } else if (try? fm.moveItem(at: displacedPreviousURL, to: location)) != nil {
                    restoredToLocation = true
                } else {
                    restoredToLocation = false
                }

                if restoredToLocation {
                    var restoredStat = stat()
                    if Darwin.lstat(location.path, &restoredStat) == 0 {
                        if let parkedNewURL, !isSubpath(parkedNewURL, of: stagingRoot) {
                            try? fm.removeItem(at: parkedNewURL)
                        }
                        return true
                    }
                }

                if let parkedNewURL {
                    var checkLocStat = stat()
                    if Darwin.lstat(location.path, &checkLocStat) != 0 {
                        _ = Darwin.rename(parkedNewURL.path, location.path)
                    }
                }
                PlayCoverDiagnostics.log(
                    "Critical: failed to restore previous app bundle to \(location.lastPathComponent)",
                    isError: true
                )
                return false
            }
            if Darwin.rename(displacedPreviousURL.path, location.path) == 0 {
                return true
            }
            do {
                try fm.moveItem(at: displacedPreviousURL, to: location)
                return true
            } catch {
                PlayCoverDiagnostics.log(
                    "Critical: failed to restore previous app bundle to \(location.lastPathComponent): \(error)",
                    isError: true
                )
                return false
            }
        } else {
            switch probePathPresence(at: location) {
            case .absent:
                return true
            case .queryFailed(let err):
                PlayCoverDiagnostics.log(
                    "Critical: failed to query rolled-back fresh app bundle \(location.lastPathComponent): " +
                        "\(String(cString: strerror(err))) (errno=\(err))",
                    isError: true
                )
                return false
            case .present:
                break
            }
            let evictedNewURL = stagingRoot.appendingPathComponent("evicted-\(UUID().uuidString).app")
            if Darwin.rename(location.path, evictedNewURL.path) == 0 {
                return true
            }
            do {
                try fm.removeItem(at: location)
                return true
            } catch {
                PlayCoverDiagnostics.log(
                    "Critical: failed to remove rolled-back fresh app bundle \(location.lastPathComponent): \(error)",
                    isError: true
                )
                return false
            }
        }
    }

    /// Stages `baseApp` into a temporary directory under `destinationDir`, runs signing/verification
    /// before touching any existing `.app` at the target path, atomically swaps the verified bundle
    /// into place, and rolls back to preserve the previous `.app` if any post-swap step fails.
    static func publishSignedBundle(
        _ baseApp: BaseApp,
        into destinationDir: URL = AppsVM.appDirectory,
        prepareAndVerify: (URL, URL) throws -> Void,
        beforeSwap: () throws -> Void = {},
        afterSwap: (URL) throws -> Void = { _ in },
        onUnrecoverableRollbackFailure: (URL, URL?) -> Void = { _, _ in }
    ) throws -> URL {
        let fm = FileManager.default
        let info = AppInfo(contentsOf: baseApp.url
            .appendingPathComponent("Info")
            .appendingPathExtension("plist"))
        guard !info.bundleIdentifier.isEmpty else {
            throw PlayCoverError.infoPlistNotFound
        }
        guard isSafeBundleIdentifierForStorage(info.bundleIdentifier) else {
            throw PlayCoverError.playToolsError(
                "Invalid bundle identifier for local installation: \(info.bundleIdentifier)"
            )
        }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let location = destinationDir
            .appendingEscapedPathComponent(info.bundleIdentifier)
            .appendingPathExtension("app")
        let tempPrefix = ".\(location.deletingPathExtension().lastPathComponent)"
        let stagingRoot = destinationDir.appendingPathComponent(
            "\(tempPrefix).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedBundleURL = stagingRoot
            .appendingEscapedPathComponent(info.bundleIdentifier)
            .appendingPathExtension("app")

        var allowStagingCleanup = true
        defer {
            if allowStagingCleanup {
                var rootStat = stat()
                if Darwin.lstat(stagingRoot.path, &rootStat) == 0 {
                    do {
                        try fm.removeItem(at: stagingRoot)
                    } catch {
                        PlayCoverDiagnostics.log(
                            "Failed to clean up app staging root \(stagingRoot.lastPathComponent): \(error)",
                            isError: true
                        )
                    }
                }
            } else {
                PlayCoverDiagnostics.log(
                    "Retaining app staging root \(stagingRoot.path) to preserve unrecovered previous bundle",
                    isError: true
                )
            }
        }

        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try fm.moveItem(at: baseApp.url, to: stagedBundleURL)

        try prepareAndVerify(stagedBundleURL, location)
        try beforeSwap()

        var displacedPreviousURL: URL?
        switch probePathPresence(at: location) {
        case .present:
            if Darwin.renamex_np(stagedBundleURL.path, location.path, UInt32(RENAME_SWAP)) == 0 {
                displacedPreviousURL = stagedBundleURL
                allowStagingCleanup = false
            } else {
                let backupName = ".\(location.lastPathComponent).previous-\(UUID().uuidString)"
                if let replacedURL = try? fm.replaceItemAt(
                    location,
                    withItemAt: stagedBundleURL,
                    backupItemName: backupName,
                    options: [.withoutDeletingBackupItem]
                ) {
                    let candidateBackupURL = replacedURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(backupName)
                    let parkedPreviousURL = stagingRoot.appendingPathComponent(backupName)
                    if Darwin.rename(candidateBackupURL.path, parkedPreviousURL.path) == 0 {
                        displacedPreviousURL = parkedPreviousURL
                        allowStagingCleanup = false
                    } else if (try? fm.moveItem(at: candidateBackupURL, to: parkedPreviousURL)) != nil {
                        displacedPreviousURL = parkedPreviousURL
                        allowStagingCleanup = false
                    } else {
                        displacedPreviousURL = candidateBackupURL
                    }
                } else {
                    let previousURL = stagingRoot.appendingPathComponent(backupName)
                    try fm.moveItem(at: location, to: previousURL)
                    allowStagingCleanup = false
                    do {
                        try fm.moveItem(at: stagedBundleURL, to: location)
                        displacedPreviousURL = previousURL
                    } catch {
                        let restoredPreSwap: Bool
                        if Darwin.rename(previousURL.path, location.path) == 0 {
                            restoredPreSwap = true
                        } else if (try? fm.moveItem(at: previousURL, to: location)) != nil {
                            restoredPreSwap = true
                        } else {
                            restoredPreSwap = false
                        }
                        var verifyStat = stat()
                        if restoredPreSwap && Darwin.lstat(location.path, &verifyStat) == 0 {
                            allowStagingCleanup = true
                        } else {
                            let outcome = preserveDisplacedBundleOnRollbackFailure(
                                previousURL,
                                beside: location,
                                stagingRoot: stagingRoot
                            )
                            allowStagingCleanup = outcome.outsideStagingRoot
                            onUnrecoverableRollbackFailure(location, outcome.preservedURL)
                        }
                        throw error
                    }
                }
            }
        case .absent:
            try fm.moveItem(at: stagedBundleURL, to: location)
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            throw PlayCoverError.playToolsError(
                "Failed to inspect target app location \(location.lastPathComponent): \(msg) (errno=\(err))"
            )
        }

        do {
            try afterSwap(location)
            allowStagingCleanup = true
            if let displacedPreviousURL,
               !isSubpath(displacedPreviousURL, of: stagingRoot) {
                try? fm.removeItem(at: displacedPreviousURL)
            }
            return location
        } catch {
            let restored = rollbackBundleSwap(
                location: location,
                displacedPreviousURL: displacedPreviousURL,
                stagingRoot: stagingRoot
            )
            if restored {
                allowStagingCleanup = true
            } else {
                var preservedURL: URL?
                if let displacedPreviousURL {
                    let outcome = preserveDisplacedBundleOnRollbackFailure(
                        displacedPreviousURL,
                        beside: location,
                        stagingRoot: stagingRoot
                    )
                    preservedURL = outcome.preservedURL
                    allowStagingCleanup = outcome.outsideStagingRoot
                } else {
                    allowStagingCleanup = true
                }
                onUnrecoverableRollbackFailure(location, preservedURL)
            }
            throw error
        }
    }

    /// Generates a wrapper bundle for an iOS app that allows it to be launched from Finder and other macOS UIs
    static func wrap(_ baseApp: BaseApp, into destinationDir: URL = AppsVM.appDirectory) throws -> URL {
        try publishSignedBundle(baseApp, into: destinationDir, prepareAndVerify: { _, _ in })
    }
}
