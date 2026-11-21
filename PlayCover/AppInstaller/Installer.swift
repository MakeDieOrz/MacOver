//
//  Installer.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 24.11.2021.
//

import Darwin
import Foundation

class Installer {
    static let installGenerationInfoKey = "PCInstallGeneration"
    static let backupManifestFileName = "manifest.plist"

    struct AppBackupManifest: Codable, Equatable {
        let bundleIdentifier: String
        let shortVersionString: String
        let bundleVersion: String
        let installGeneration: String

        enum CodingKeys: String, CodingKey {
            case bundleIdentifier = "CFBundleIdentifier"
            case shortVersionString = "CFBundleShortVersionString"
            case bundleVersion = "CFBundleVersion"
            case installGeneration = "PCInstallGeneration"
        }

        init(
            bundleIdentifier: String,
            shortVersionString: String,
            bundleVersion: String,
            installGeneration: String
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.shortVersionString = shortVersionString
            self.bundleVersion = bundleVersion
            self.installGeneration = installGeneration
        }

        init?(appInfo: AppInfo) {
            let bundleID = appInfo.bundleIdentifier
            let generation = appInfo[string: Installer.installGenerationInfoKey] ?? ""
            guard !bundleID.isEmpty, !generation.isEmpty else {
                return nil
            }
            self.bundleIdentifier = bundleID
            self.shortVersionString = appInfo[string: "CFBundleShortVersionString"] ?? ""
            self.bundleVersion = appInfo[string: "CFBundleVersion"] ?? ""
            self.installGeneration = generation
        }
    }

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
        returnCompletion: @escaping (URL?) -> Void
    ) {
        let installVM = dependencies?.installVM ?? InstallVM()
        let installPreferences = dependencies?.installPreferences ?? InstallPreferences()
        let modifierObserver = dependencies?.modifierKeyObserver
        let alertPresenter = dependencies?.alertPresenter

        Task { @MainActor in
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

            installVM.next(.begin, 0.0, 0.0)

            Task.detached(priority: .userInitiated) {
                let ipa = IPA(url: ipaUrl)
                defer { ipa.releaseTempDir() }

                var touchedEntitlementsURL: URL?
                var previousEntitlementsData: Data?
                var touchedSettingsURL: URL?
                var previousSettingsData: Data?
                var quarantinedAppBackups: (quarantinedDir: URL, targetDir: URL, bundleID: String)?
                var unrolledPublishedBackupsTarget: (dir: URL, bundleID: String)?

                do {
                installVM.next(.unzip, 0.0, 0.5)
                try ipa.allocateTempDir()

                let app = try ipa.unzip()
                if await ipa.checkOfficialMacOS(
                    app: IPA.Application.base(app),
                    alertPresenter: alertPresenter,
                    installPreferences: installPreferences
                ) {
                    installVM.next(.failed, 0.95, 1.0)
                    returnCompletion(nil)
                    return
                }
                installVM.next(.library, 0.5, 0.55)
                let machos = resolveValidMachOs(app)
                app.validMachOs = machos

                installVM.next(.playtools, 0.55, 0.85)

                for macho in machos where try Macho.isMachoEncrypted(atURL: macho) {
                    throw PlayCoverError.appEncrypted
                }

                let entitlementsURL = app.entitlements
                if FileManager.default.fileExists(atPath: entitlementsURL.path) {
                    previousEntitlementsData = try? Data(contentsOf: entitlementsURL)
                }
                try saveEntitlements(app)
                touchedEntitlementsURL = entitlementsURL

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

                if export {
                    try PlayTools.injectInIPA(app.executable, payload: app.url)
                } else if installPlayTools {
                    try await PlayTools.installInIPA(app.executable, appInfo: app.info, signBundle: false)
                }

                app.info.setApplicationCategoryType(applicationType, persist: false)

                if !export {
                    // -rwxr-xr-x
                    try app.executable.setBinaryPosixPermissions(0o755)
                    try removeMobileProvision(app)
                }

                let info = app.info
                if !export, !info.bundleIdentifier.isEmpty {
                    let originalMinimumOSVersion = info.minimumOSVersion
                    let appSettings = AppSettings(info)
                    let settingsURL = appSettings.settingsUrl
                    if FileManager.default.fileExists(atPath: settingsURL.path) {
                        previousSettingsData = try? Data(contentsOf: settingsURL)
                    }
                    touchedSettingsURL = settingsURL
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
                installVM.next(.wrapper, 0.85, 0.95)

                var finalURL: URL

                if export {
                    finalURL = try ipa.packIPABack(app: app.url)
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
                            try Shell.verifyAppSignature(stagedBundleURL)
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
                                try commitAppBackups(backupStagingResult, for: installedApp)
                                cleanupInvalidatedAppBackups(
                                    primary: quarantinedAppBackups?.quarantinedDir,
                                    in: installedApp.appBackupsDir.deletingLastPathComponent(),
                                    bundleIdentifier: installedBundleID
                                )
                                quarantinedAppBackups = nil
                            }
                            try? ipa.removeQuarantine(publishedURL)
                        },
                        onUnrecoverableRollbackFailure: { publishedURL in
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

                installVM.next(.finish, 0.95, 1.0)
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
                    cleanupInvalidatedAppBackups(
                        primary: quarantinedAppBackups?.quarantinedDir,
                        in: unrolledPublishedBackupsTarget.dir.deletingLastPathComponent(),
                        bundleIdentifier: unrolledPublishedBackupsTarget.bundleID
                    )
                } else if let quarantinedAppBackups {
                    var canRestoreQuarantined = true
                    var targetStat = stat()
                    if Darwin.lstat(quarantinedAppBackups.targetDir.path, &targetStat) == 0 {
                        canRestoreQuarantined = invalidateAppBackups(
                            at: quarantinedAppBackups.targetDir,
                            bundleIdentifier: quarantinedAppBackups.bundleID
                        )
                    }
                    if canRestoreQuarantined {
                        restoreQuarantinedAppBackups(
                            quarantinedAppBackups.quarantinedDir,
                            to: quarantinedAppBackups.targetDir,
                            bundleIdentifier: quarantinedAppBackups.bundleID
                        )
                    }
                    cleanupInvalidatedAppBackups(
                        primary: nil,
                        in: quarantinedAppBackups.targetDir.deletingLastPathComponent(),
                        bundleIdentifier: quarantinedAppBackups.bundleID
                    )
                }
                if let touchedEntitlementsURL {
                    if let previousEntitlementsData {
                        try? previousEntitlementsData.write(to: touchedEntitlementsURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: touchedEntitlementsURL)
                    }
                }
                if let touchedSettingsURL {
                    if let previousSettingsData {
                        try? previousSettingsData.write(to: touchedSettingsURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: touchedSettingsURL)
                    }
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

        var resolved: [URL] = []
        let serialQueue = DispatchQueue(label: "baseAppUrlResolver")

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

            serialQueue.sync {
                switch Array(data) {
                case [202, 254, 186, 190], [190, 186, 254, 202],
                     [202, 254, 186, 191], [191, 186, 254, 202],
                     [207, 250, 237, 254], [254, 237, 250, 207]:
                    resolved.append(url)
                default:
                    return
                }
            }
        }

        return resolved
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

    enum AppBackupStagingResult {
        case staged(URL)
        case noneApplicable
        case failed
    }

    static func stageAppBackups(for baseApp: BaseApp, in stagingDir: URL) -> AppBackupStagingResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: stagingDir.path) {
            try? fm.removeItem(at: stagingDir)
        }

        let provisionURL = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        var isDir: ObjCBool = false
        let hasProvision = fm.fileExists(atPath: provisionURL.path, isDirectory: &isDir) && !isDir.boolValue

        let infoPlistURL = baseApp.url.appendingPathComponent("Info.plist")
        var infoIsDir: ObjCBool = false
        let hasInfoPlist = fm.fileExists(atPath: infoPlistURL.path, isDirectory: &infoIsDir) && !infoIsDir.boolValue

        let hasThinExecutable: Bool
        if fm.fileExists(atPath: baseApp.executable.path) {
            do {
                let ctx = try Macho.inspectArm64Slice(at: baseApp.executable)
                hasThinExecutable = !ctx.isFat
            } catch {
                PlayCoverDiagnostics.log(
                    "Failed to inspect executable for AppBackups staging: \(error)",
                    isError: true
                )
                return .failed
            }
        } else {
            hasThinExecutable = false
        }

        guard hasProvision || hasThinExecutable || hasInfoPlist else {
            return .noneApplicable
        }

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            PlayCoverDiagnostics.log("Failed to create AppBackups staging dir: \(error)", isError: true)
            return .failed
        }

        if hasInfoPlist {
            let stagedInfo = stagingDir.appendingPathComponent("Info.plist")
            if Darwin.clonefile(infoPlistURL.path, stagedInfo.path, 0) != 0 {
                do {
                    try fm.copyItem(at: infoPlistURL, to: stagedInfo)
                } catch {
                    PlayCoverDiagnostics.log("Failed to stage Info.plist backup: \(error)", isError: true)
                    try? fm.removeItem(at: stagingDir)
                    return .failed
                }
            }
        }

        if hasProvision {
            let stagedProvision = stagingDir.appendingPathComponent("embedded.mobileprovision")
            do {
                try fm.copyItem(at: provisionURL, to: stagedProvision)
            } catch {
                PlayCoverDiagnostics.log("Failed to stage embedded.mobileprovision backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        if hasThinExecutable {
            let stagedExec = stagingDir.appendingPathComponent("executable")
            if Darwin.clonefile(baseApp.executable.path, stagedExec.path, 0) == 0 {
                try? stagedExec.setBinaryPosixPermissions(0o755)
            } else {
                do {
                    try fm.copyItem(at: baseApp.executable, to: stagedExec)
                    try? stagedExec.setBinaryPosixPermissions(0o755)
                } catch {
                    PlayCoverDiagnostics.log("Failed to stage executable backup: \(error)", isError: true)
                    try? fm.removeItem(at: stagingDir)
                    return .failed
                }
            }
        }

        return .staged(stagingDir)
    }

    private static func invalidatedBackupPrefix(for directoryName: String) -> String {
        ".\(directoryName).invalidated-"
    }

    static func quarantineAppBackups(at targetDir: URL, bundleIdentifier: String) throws -> URL? {
        var st = stat()
        guard Darwin.lstat(targetDir.path, &st) == 0 else {
            return nil
        }
        let invalidatedDir = targetDir.deletingLastPathComponent().appendingPathComponent(
            "\(invalidatedBackupPrefix(for: targetDir.lastPathComponent))\(UUID().uuidString)"
        )
        if Darwin.rename(targetDir.path, invalidatedDir.path) == 0 {
            return invalidatedDir
        }
        let renameErr = errno
        PlayCoverDiagnostics.log(
            "Atomic rename failed quarantining AppBackups for \(bundleIdentifier): " +
                "\(String(cString: strerror(renameErr)))",
            isError: true
        )
        try FileManager.default.moveItem(at: targetDir, to: invalidatedDir)
        return invalidatedDir
    }

    static func restoreQuarantinedAppBackups(
        _ quarantinedDir: URL,
        to targetDir: URL,
        bundleIdentifier: String
    ) {
        var qst = stat()
        guard Darwin.lstat(quarantinedDir.path, &qst) == 0 else {
            return
        }
        var tst = stat()
        guard Darwin.lstat(targetDir.path, &tst) != 0 else {
            return
        }
        if Darwin.rename(quarantinedDir.path, targetDir.path) == 0 {
            return
        }
        let renameErr = errno
        do {
            try FileManager.default.moveItem(at: quarantinedDir, to: targetDir)
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to restore quarantined AppBackups for \(bundleIdentifier) " +
                    "(rename errno=\(renameErr)): \(error)",
                isError: true
            )
        }
    }

    static func cleanupInvalidatedAppBackups(
        primary: URL?,
        in parentDir: URL,
        bundleIdentifier: String
    ) {
        let fm = FileManager.default
        if let primary {
            var st = stat()
            if Darwin.lstat(primary.path, &st) == 0 {
                do {
                    try fm.removeItem(at: primary)
                } catch {
                    PlayCoverDiagnostics.log(
                        "Failed to remove invalidated AppBackups \(primary.lastPathComponent) " +
                            "for \(bundleIdentifier): \(error)",
                        isError: true
                    )
                }
            }
        }
        let prefix = invalidatedBackupPrefix(for: bundleIdentifier)
        if let entries = try? fm.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                do {
                    try fm.removeItem(at: entry)
                } catch {
                    PlayCoverDiagnostics.log(
                        "Failed to clean up leftover invalidated AppBackups \(entry.lastPathComponent) " +
                            "for \(bundleIdentifier): \(error)",
                        isError: true
                    )
                }
            }
        }
    }

    static func invalidateAppBackups(at targetDir: URL, bundleIdentifier: String) -> Bool {
        let fm = FileManager.default
        var st = stat()
        guard Darwin.lstat(targetDir.path, &st) == 0 else {
            return true
        }
        let invalidatedDir = targetDir.deletingLastPathComponent().appendingPathComponent(
            "\(invalidatedBackupPrefix(for: targetDir.lastPathComponent))\(UUID().uuidString)"
        )
        if Darwin.rename(targetDir.path, invalidatedDir.path) == 0 {
            do {
                try fm.removeItem(at: invalidatedDir)
            } catch {
                PlayCoverDiagnostics.log(
                    "Evicted stale AppBackups for \(bundleIdentifier) to \(invalidatedDir.lastPathComponent), " +
                        "but removal failed: \(error)",
                    isError: true
                )
            }
            return true
        }

        let renameErr = errno
        let renameMessage = String(cString: strerror(renameErr))
        do {
            try fm.removeItem(at: targetDir)
            return true
        } catch let removeError {
            PlayCoverDiagnostics.log(
                "Failed to evict stale AppBackups for \(bundleIdentifier) " +
                    "(rename: \(renameMessage), remove: \(removeError))",
                isError: true
            )
            var orderedNames: [String] = [
                Installer.backupManifestFileName,
                "Info.plist",
                "executable",
                "embedded.mobileprovision"
            ]
            if let listed = try? fm.contentsOfDirectory(atPath: targetDir.path) {
                for item in listed where !orderedNames.contains(item) {
                    orderedNames.append(item)
                }
            }
            for name in orderedNames {
                let itemURL = targetDir.appendingPathComponent(name)
                if Darwin.unlink(itemURL.path) != 0 {
                    let unlinkErr = errno
                    if unlinkErr != ENOENT {
                        PlayCoverDiagnostics.log(
                            "Failed to unlink \(name) in stale AppBackups for \(bundleIdentifier): " +
                                "\(String(cString: strerror(unlinkErr)))",
                            isError: true
                        )
                    }
                }
            }
            if Darwin.rmdir(targetDir.path) == 0 {
                return true
            }
            if Darwin.rename(targetDir.path, invalidatedDir.path) == 0 {
                do {
                    try fm.removeItem(at: invalidatedDir)
                } catch {
                    PlayCoverDiagnostics.log(
                        "Failed to remove evicted AppBackups \(invalidatedDir.lastPathComponent) " +
                            "for \(bundleIdentifier): \(error)",
                        isError: true
                    )
                }
                return true
            }
            PlayCoverDiagnostics.log(
                "Critical: stale AppBackups directory remains at active path for \(bundleIdentifier)",
                isError: true
            )
            return false
        }
    }

    static func verifyAppBackupManifest(in backupDir: URL, for appInfo: AppInfo) -> Bool {
        guard let expected = AppBackupManifest(appInfo: appInfo) else {
            return false
        }
        let manifestURL = backupDir.appendingPathComponent(Installer.backupManifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let actual = try? PropertyListDecoder().decode(AppBackupManifest.self, from: data) else {
            return false
        }
        return actual == expected
    }

    static func commitAppBackups(_ stagingResult: AppBackupStagingResult, for installedApp: BaseApp) throws {
        try commitAppBackups(
            stagingResult,
            to: installedApp.appBackupsDir,
            bundleIdentifier: installedApp.info.bundleIdentifier,
            manifest: AppBackupManifest(appInfo: installedApp.info)
        )
    }

    static func commitAppBackups(
        _ stagingResult: AppBackupStagingResult,
        to targetDir: URL,
        bundleIdentifier: String,
        manifest: AppBackupManifest?
    ) throws {
        let fm = FileManager.default

        let stagingDir: URL
        switch stagingResult {
        case .staged(let url):
            stagingDir = url
        case .noneApplicable, .failed:
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict stale AppBackups for \(bundleIdentifier)"
                )
            }
            return
        }

        guard let manifest,
              !manifest.installGeneration.isEmpty,
              manifest.bundleIdentifier == bundleIdentifier,
              fm.fileExists(atPath: stagingDir.path),
              let entries = try? fm.contentsOfDirectory(atPath: stagingDir.path),
              !entries.isEmpty else {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict unbound AppBackups for \(bundleIdentifier)"
                )
            }
            return
        }

        let parentDir = targetDir.deletingLastPathComponent()
        let incomingDir = parentDir.appendingPathComponent(
            ".\(targetDir.lastPathComponent).staging-\(UUID().uuidString)"
        )

        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try fm.moveItem(at: stagingDir, to: incomingDir)

            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let manifestData = try encoder.encode(manifest)
            let manifestURL = incomingDir.appendingPathComponent(Installer.backupManifestFileName)
            try manifestData.write(to: manifestURL, options: .atomic)

            if fm.fileExists(atPath: targetDir.path) {
                if Darwin.renamex_np(incomingDir.path, targetDir.path, UInt32(RENAME_SWAP)) == 0 {
                    try? fm.removeItem(at: incomingDir)
                } else {
                    let previousDir = parentDir.appendingPathComponent(
                        ".\(targetDir.lastPathComponent).previous-\(UUID().uuidString)"
                    )
                    try fm.moveItem(at: targetDir, to: previousDir)
                    do {
                        try fm.moveItem(at: incomingDir, to: targetDir)
                        try? fm.removeItem(at: previousDir)
                    } catch {
                        try? fm.removeItem(at: previousDir)
                        throw error
                    }
                }
            } else {
                try fm.moveItem(at: incomingDir, to: targetDir)
            }
        } catch {
            if fm.fileExists(atPath: incomingDir.path) {
                try? fm.removeItem(at: incomingDir)
            }
            let evicted = invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier)
            PlayCoverDiagnostics.log(
                "Failed to commit AppBackups for \(bundleIdentifier): \(error)",
                isError: true
            )
            if !evicted {
                throw PlayCoverError.playToolsError(
                    "Failed to commit AppBackups and stale backup remained active for \(bundleIdentifier)"
                )
            }
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
                    if !displacedPreviousURL.path.hasPrefix(stagingRoot.path + "/") {
                        try? fm.removeItem(at: displacedPreviousURL)
                    }
                    return true
                }
                let failedNewURL = stagingRoot.appendingPathComponent("failed-\(UUID().uuidString).app")
                if Darwin.rename(location.path, failedNewURL.path) != 0 {
                    do {
                        try fm.moveItem(at: location, to: failedNewURL)
                    } catch {
                        try? fm.removeItem(at: location)
                    }
                }
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
            var locStat = stat()
            guard Darwin.lstat(location.path, &locStat) == 0 else {
                return true
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
        onUnrecoverableRollbackFailure: (URL) -> Void = { _ in }
    ) throws -> URL {
        let fm = FileManager.default
        let info = AppInfo(contentsOf: baseApp.url
            .appendingPathComponent("Info")
            .appendingPathExtension("plist"))
        guard !info.bundleIdentifier.isEmpty else {
            throw PlayCoverError.infoPlistNotFound
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

        defer {
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
        }

        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try fm.moveItem(at: baseApp.url, to: stagedBundleURL)

        try prepareAndVerify(stagedBundleURL, location)
        try beforeSwap()

        var displacedPreviousURL: URL?
        var existingStat = stat()
        if Darwin.lstat(location.path, &existingStat) == 0 {
            if Darwin.renamex_np(stagedBundleURL.path, location.path, UInt32(RENAME_SWAP)) == 0 {
                displacedPreviousURL = stagedBundleURL
            } else {
                let backupName = "previous-\(UUID().uuidString).app"
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
                    } else if (try? fm.moveItem(at: candidateBackupURL, to: parkedPreviousURL)) != nil {
                        displacedPreviousURL = parkedPreviousURL
                    } else {
                        displacedPreviousURL = candidateBackupURL
                    }
                } else {
                    let previousURL = stagingRoot.appendingPathComponent(backupName)
                    try fm.moveItem(at: location, to: previousURL)
                    do {
                        try fm.moveItem(at: stagedBundleURL, to: location)
                        displacedPreviousURL = previousURL
                    } catch {
                        if Darwin.rename(previousURL.path, location.path) != 0 {
                            try? fm.moveItem(at: previousURL, to: location)
                        }
                        throw error
                    }
                }
            }
        } else {
            try fm.moveItem(at: stagedBundleURL, to: location)
        }

        do {
            try afterSwap(location)
            if let displacedPreviousURL,
               !displacedPreviousURL.path.hasPrefix(stagingRoot.path + "/") {
                try? fm.removeItem(at: displacedPreviousURL)
            }
            return location
        } catch {
            let restored = rollbackBundleSwap(
                location: location,
                displacedPreviousURL: displacedPreviousURL,
                stagingRoot: stagingRoot
            )
            if !restored {
                onUnrecoverableRollbackFailure(location)
            }
            throw error
        }
    }

    /// Generates a wrapper bundle for an iOS app that allows it to be launched from Finder and other macOS UIs
    static func wrap(_ baseApp: BaseApp, into destinationDir: URL = AppsVM.appDirectory) throws -> URL {
        try publishSignedBundle(baseApp, into: destinationDir, prepareAndVerify: { _, _ in })
    }
}
