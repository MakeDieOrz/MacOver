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

    private enum AppBackupManifestCodingKeys: String, CodingKey {
        case bundleIdentifier = "CFBundleIdentifier"
        case shortVersionString = "CFBundleShortVersionString"
        case bundleVersion = "CFBundleVersion"
        case installGeneration = "PCInstallGeneration"
    }

    struct AppBackupManifest: Codable, Equatable {
        let bundleIdentifier: String
        let shortVersionString: String
        let bundleVersion: String
        let installGeneration: String

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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AppBackupManifestCodingKeys.self)
            self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
            self.shortVersionString = try container.decode(String.self, forKey: .shortVersionString)
            self.bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
            self.installGeneration = try container.decode(String.self, forKey: .installGeneration)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AppBackupManifestCodingKeys.self)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encode(shortVersionString, forKey: .shortVersionString)
            try container.encode(bundleVersion, forKey: .bundleVersion)
            try container.encode(installGeneration, forKey: .installGeneration)
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

                var touchedEntitlementsState: (url: URL, existedBefore: Bool, previousData: Data?)?
                var touchedSettingsState: (url: URL, existedBefore: Bool, previousData: Data?)?
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
                                try finalizeAppBackupsAfterSwap(
                                    backupStagingResult,
                                    for: installedApp,
                                    quarantinedDir: quarantinedAppBackups?.quarantinedDir
                                )
                                quarantinedAppBackups = nil
                            }
                            try? ipa.removeQuarantine(publishedURL)
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

    static func restoreRollbackFile(at url: URL, existedBefore: Bool, previousData: Data?, label: String) {
        if let previousData {
            try? previousData.write(to: url, options: .atomic)
        } else if !existedBefore {
            try? FileManager.default.removeItem(at: url)
        } else {
            PlayCoverDiagnostics.log(
                "Preserving pre-existing unreadable \(label) file at \(url.path) during install rollback",
                isError: true
            )
        }
    }

    private static func isRegularFileNoFollow(at url: URL) -> Bool {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            return false
        }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func checkBackupSourceRegularFile(at url: URL, label: String) -> Bool {
        if isRegularFileNoFollow(at: url) {
            return true
        }
        if case .present = probePathPresence(at: url) {
            PlayCoverDiagnostics.log(
                "Refusing non-regular \(label) during AppBackups staging: \(url.lastPathComponent)",
                isError: true
            )
        }
        return false
    }

    private static func copyRegularFileNoFollow(from src: URL, to dst: URL) throws {
        let srcFD = Darwin.open(src.path, O_RDONLY | O_NOFOLLOW)
        guard srcFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(srcFD) }

        var st = stat()
        guard Darwin.fstat(srcFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }

        let dstFD = Darwin.open(dst.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        guard dstFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var closedDst = false
        defer {
            if !closedDst {
                Darwin.close(dstFD)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(srcFD, ptr.baseAddress, ptr.count)
            }
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var written = 0
            while written < bytesRead {
                let res = buffer.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.write(dstFD, base.advanced(by: written), bytesRead - written)
                }
                if res < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                written += res
            }
        }
        if Darwin.close(dstFD) != 0 {
            closedDst = true
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        closedDst = true
    }

    private static func cloneOrCopyRegularFileNoFollow(from src: URL, to dst: URL) throws {
        if Darwin.clonefile(src.path, dst.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            return
        }
        let cloneErr = errno
        if cloneErr == ELOOP || cloneErr == EISDIR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(cloneErr))
        }
        try copyRegularFileNoFollow(from: src, to: dst)
    }

    static func stageAppBackups(for baseApp: BaseApp, in stagingDir: URL) -> AppBackupStagingResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: stagingDir.path) {
            try? fm.removeItem(at: stagingDir)
        }

        let provisionURL = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        let hasProvision = checkBackupSourceRegularFile(at: provisionURL, label: "embedded.mobileprovision")

        let infoPlistURL = baseApp.url.appendingPathComponent("Info.plist")
        let hasInfoPlist = checkBackupSourceRegularFile(at: infoPlistURL, label: "Info.plist")

        let hasThinExecutable: Bool
        if checkBackupSourceRegularFile(at: baseApp.executable, label: "executable") {
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
            do {
                try cloneOrCopyRegularFileNoFollow(
                    from: infoPlistURL,
                    to: stagingDir.appendingPathComponent("Info.plist")
                )
            } catch {
                PlayCoverDiagnostics.log("Failed to stage Info.plist backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        if hasProvision {
            do {
                try cloneOrCopyRegularFileNoFollow(
                    from: provisionURL,
                    to: stagingDir.appendingPathComponent("embedded.mobileprovision")
                )
            } catch {
                PlayCoverDiagnostics.log("Failed to stage embedded.mobileprovision backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        if hasThinExecutable {
            let stagedExec = stagingDir.appendingPathComponent("executable")
            do {
                try cloneOrCopyRegularFileNoFollow(from: baseApp.executable, to: stagedExec)
                try? stagedExec.setBinaryPosixPermissions(0o755)
            } catch {
                PlayCoverDiagnostics.log("Failed to stage executable backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        return .staged(stagingDir)
    }

    private static func canonicalFilePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSubpath(_ candidate: URL, of directory: URL) -> Bool {
        let stdDir = directory.standardizedFileURL.path
        let stdCand = candidate.standardizedFileURL.path
        let stdPrefix = stdDir.hasSuffix("/") ? stdDir : (stdDir + "/")
        if stdCand.hasPrefix(stdPrefix) {
            return true
        }
        let realDir = canonicalFilePath(directory)
        let realCand = canonicalFilePath(candidate)
        let realPrefix = realDir.hasSuffix("/") ? realDir : (realDir + "/")
        return realCand.hasPrefix(realPrefix)
    }

    enum PathPresence {
        case present
        case absent
        case queryFailed(Int32)
    }

    static func probePathPresence(at targetURL: URL) -> PathPresence {
        var st = stat()
        if Darwin.lstat(targetURL.path, &st) == 0 {
            return .present
        }
        let err = errno
        if err == ENOENT {
            return .absent
        }
        return .queryFailed(err)
    }

    static func isSafeBundleIdentifierForStorage(_ bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != ".",
              bundleIdentifier != "..",
              !bundleIdentifier.hasPrefix("."),
              !bundleIdentifier.contains("/"),
              !bundleIdentifier.contains("\\"),
              !bundleIdentifier.contains("\0") else {
            return false
        }
        return true
    }

    private static func isValidatedBackupTarget(_ targetDir: URL, bundleIdentifier: String) -> Bool {
        guard isSafeBundleIdentifierForStorage(bundleIdentifier),
              targetDir.lastPathComponent == bundleIdentifier else {
            return false
        }
        let parentDir = targetDir.deletingLastPathComponent()
        let expectedPath = parentDir.appendingPathComponent(bundleIdentifier).standardizedFileURL.path
        guard targetDir.standardizedFileURL.path == expectedPath else {
            return false
        }
        return isSubpath(targetDir, of: parentDir)
    }

    private static func invalidatedBackupPrefix(for directoryName: String) -> String {
        ".\(directoryName).invalidated-"
    }

    static func quarantineAppBackups(at targetDir: URL, bundleIdentifier: String) throws -> URL? {
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier) else {
            throw PlayCoverError.playToolsError(
                "Refusing to quarantine AppBackups outside expected container for \(bundleIdentifier)"
            )
        }
        switch probePathPresence(at: targetDir) {
        case .absent:
            return nil
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            PlayCoverDiagnostics.log(
                "Failed to query AppBackups before quarantine for \(bundleIdentifier): \(msg) (errno=\(err))",
                isError: true
            )
            throw PlayCoverError.playToolsError(
                "Failed to query AppBackups for \(bundleIdentifier): \(msg) (errno=\(err))"
            )
        case .present:
            break
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

    @discardableResult
    static func restoreQuarantinedAppBackups(
        _ quarantinedDir: URL,
        to targetDir: URL,
        bundleIdentifier: String
    ) -> Bool {
        let parentDir = targetDir.deletingLastPathComponent()
        let prefix = invalidatedBackupPrefix(for: bundleIdentifier)
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier),
              isSubpath(quarantinedDir, of: parentDir),
              quarantinedDir.lastPathComponent.hasPrefix(prefix) else {
            PlayCoverDiagnostics.log(
                "Refusing to restore quarantined AppBackups outside expected container for \(bundleIdentifier)",
                isError: true
            )
            return false
        }
        switch probePathPresence(at: quarantinedDir) {
        case .present:
            break
        case .absent:
            return false
        case .queryFailed(let err):
            PlayCoverDiagnostics.log(
                "Failed to query quarantined AppBackups for \(bundleIdentifier): " +
                    "\(String(cString: strerror(err))) (errno=\(err))",
                isError: true
            )
            return false
        }
        switch probePathPresence(at: targetDir) {
        case .absent:
            break
        case .present:
            PlayCoverDiagnostics.log(
                "Cannot restore quarantined AppBackups for \(bundleIdentifier): " +
                    "active path \(targetDir.path) is still occupied",
                isError: true
            )
            return false
        case .queryFailed(let err):
            PlayCoverDiagnostics.log(
                "Cannot restore quarantined AppBackups for \(bundleIdentifier): " +
                    "failed to query active path \(targetDir.path): \(String(cString: strerror(err))) (errno=\(err))",
                isError: true
            )
            return false
        }
        if Darwin.rename(quarantinedDir.path, targetDir.path) == 0 {
            return true
        }
        let renameErr = errno
        do {
            try FileManager.default.moveItem(at: quarantinedDir, to: targetDir)
            return true
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to restore quarantined AppBackups for \(bundleIdentifier) " +
                    "(rename errno=\(renameErr)): \(error)",
                isError: true
            )
            return false
        }
    }

    static func cleanupInvalidatedAppBackups(
        primary: URL?,
        in parentDir: URL,
        bundleIdentifier: String,
        excluding excludedURLs: Set<URL> = []
    ) {
        guard isSafeBundleIdentifierForStorage(bundleIdentifier) else {
            PlayCoverDiagnostics.log(
                "Refusing cleanupInvalidatedAppBackups for invalid bundle identifier: \(bundleIdentifier)",
                isError: true
            )
            return
        }
        let fm = FileManager.default
        let prefix = invalidatedBackupPrefix(for: bundleIdentifier)
        let excludedStdPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })
        let excludedRealPaths = Set(excludedURLs.map { canonicalFilePath($0) })
        let isExcluded: (URL) -> Bool = { candidate in
            excludedStdPaths.contains(candidate.standardizedFileURL.path) ||
                excludedRealPaths.contains(canonicalFilePath(candidate))
        }

        if let primary,
           !isExcluded(primary),
           isSubpath(primary, of: parentDir),
           primary.lastPathComponent.hasPrefix(prefix) {
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
        if let entries = try? fm.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                if isExcluded(entry) {
                    continue
                }
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
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier) else {
            PlayCoverDiagnostics.log(
                "Refusing to invalidate AppBackups outside expected container for \(bundleIdentifier)",
                isError: true
            )
            return false
        }
        let fm = FileManager.default
        switch probePathPresence(at: targetDir) {
        case .absent:
            return true
        case .queryFailed(let err):
            PlayCoverDiagnostics.log(
                "Failed to query AppBackups for invalidation at \(targetDir.path) (\(bundleIdentifier)): " +
                    "\(String(cString: strerror(err))) (errno=\(err))",
                isError: true
            )
            return false
        case .present:
            break
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

    static func validateOrInvalidateAppBackupsForLaunch(
        at backupDir: URL,
        for appInfo: AppInfo
    ) throws {
        let bundleID = appInfo.bundleIdentifier
        guard !bundleID.isEmpty else {
            return
        }
        switch probePathPresence(at: backupDir) {
        case .absent:
            return
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            PlayCoverDiagnostics.log(
                "Failed to query AppBackups before launch for \(bundleID): \(msg) (errno=\(err))",
                isError: true
            )
            throw PlayCoverError.playToolsError(
                "Failed to inspect AppBackups for \(bundleID): \(msg) (errno=\(err))"
            )
        case .present:
            if !verifyAppBackupManifest(in: backupDir, for: appInfo) {
                guard invalidateAppBackups(at: backupDir, bundleIdentifier: bundleID) else {
                    throw PlayCoverError.playToolsError(
                        "Failed to evict stale AppBackups for \(bundleID)"
                    )
                }
            }
        }
    }

    enum AppBackupCommitOutcome: Equatable {
        case committed
        case noneApplicable
        case degradedWithoutBackups
    }

    @discardableResult
    static func finalizeAppBackupsAfterSwap(
        _ stagingResult: AppBackupStagingResult,
        for installedApp: BaseApp,
        quarantinedDir: URL?
    ) throws -> AppBackupCommitOutcome {
        try finalizeAppBackupsAfterSwap(
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
        let outcome = try commitAppBackups(
            stagingResult,
            to: targetDir,
            bundleIdentifier: bundleIdentifier,
            manifest: manifest
        )
        switch outcome {
        case .committed, .noneApplicable:
            cleanupInvalidatedAppBackups(
                primary: quarantinedDir,
                in: targetDir.deletingLastPathComponent(),
                bundleIdentifier: bundleIdentifier
            )
        case .degradedWithoutBackups:
            if let quarantinedDir {
                PlayCoverDiagnostics.log(
                    "AppBackups staging or validation failed for \(bundleIdentifier); " +
                        "preserving quarantined previous AppBackups at \(quarantinedDir.path)",
                    isError: true
                )
            } else {
                PlayCoverDiagnostics.log(
                    "AppBackups staging or validation failed for \(bundleIdentifier); " +
                        "continuing installation without AppBackups",
                    isError: true
                )
            }
        }
        return outcome
    }

    @discardableResult
    static func commitAppBackups(
        _ stagingResult: AppBackupStagingResult,
        for installedApp: BaseApp
    ) throws -> AppBackupCommitOutcome {
        try commitAppBackups(
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
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier),
              isSubpath(incomingDir, of: parentDir),
              canonicalFilePath(targetDir.deletingLastPathComponent()) == canonicalFilePath(parentDir) else {
            throw PlayCoverError.playToolsError(
                "Refusing AppBackups replacement outside expected container for \(bundleIdentifier)"
            )
        }
        let fm = FileManager.default
        switch probePathPresence(at: targetDir) {
        case .present:
            if allowRenameSwap && Darwin.renamex_np(incomingDir.path, targetDir.path, UInt32(RENAME_SWAP)) == 0 {
                try? fm.removeItem(at: incomingDir)
                return
            }
            let previousDir = parentDir.appendingPathComponent(
                ".\(targetDir.lastPathComponent).previous-\(UUID().uuidString)"
            )
            try fm.moveItem(at: targetDir, to: previousDir)
            do {
                try fm.moveItem(at: incomingDir, to: targetDir)
                try? fm.removeItem(at: previousDir)
            } catch {
                if Darwin.rename(previousDir.path, targetDir.path) != 0 {
                    do {
                        try fm.moveItem(at: previousDir, to: targetDir)
                    } catch let restoreError {
                        PlayCoverDiagnostics.log(
                            "Critical: failed to restore previous AppBackups for \(bundleIdentifier) " +
                                "from \(previousDir.path) to \(targetDir.path): \(restoreError)",
                            isError: true
                        )
                    }
                }
                throw error
            }
        case .absent:
            try fm.moveItem(at: incomingDir, to: targetDir)
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            throw PlayCoverError.playToolsError(
                "Failed to query target AppBackups for \(bundleIdentifier): \(msg) (errno=\(err))"
            )
        }
    }

    @discardableResult
    static func commitAppBackups(
        _ stagingResult: AppBackupStagingResult,
        to targetDir: URL,
        bundleIdentifier: String,
        manifest: AppBackupManifest?
    ) throws -> AppBackupCommitOutcome {
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier) else {
            throw PlayCoverError.playToolsError(
                "Refusing to commit AppBackups outside expected container for \(bundleIdentifier)"
            )
        }
        let fm = FileManager.default

        let stagingDir: URL
        switch stagingResult {
        case .staged(let url):
            stagingDir = url
        case .noneApplicable:
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict stale AppBackups for \(bundleIdentifier)"
                )
            }
            return .noneApplicable
        case .failed:
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict stale AppBackups for \(bundleIdentifier)"
                )
            }
            return .degradedWithoutBackups
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
            return .degradedWithoutBackups
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

            try replaceBackupDirectoryAtomically(
                incomingDir: incomingDir,
                targetDir: targetDir,
                parentDir: parentDir,
                bundleIdentifier: bundleIdentifier
            )
            var committedStat = stat()
            guard Darwin.lstat(targetDir.path, &committedStat) == 0,
                  Darwin.lstat(
                      targetDir.appendingPathComponent(Installer.backupManifestFileName).path,
                      &committedStat
                  ) == 0 else {
                throw PlayCoverError.playToolsError(
                    "Committed AppBackups verification failed at \(targetDir.path)"
                )
            }
            return .committed
        } catch {
            var incomingStat = stat()
            if Darwin.lstat(incomingDir.path, &incomingStat) == 0 {
                try? fm.removeItem(at: incomingDir)
            }
            PlayCoverDiagnostics.log(
                "Failed to commit AppBackups for \(bundleIdentifier): \(error)",
                isError: true
            )
            throw PlayCoverError.playToolsError(
                "Failed to commit AppBackups for \(bundleIdentifier): \(error.localizedDescription)"
            )
        }
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
