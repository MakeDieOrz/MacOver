//
//  Uninstaller.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 9/26/22.
//

import Synchronization
import SwiftUI

struct CheckBoxHelper {
    var view: NSView
    var button: NSButton
    var preferenceKeyPath: ReferenceWritableKeyPath<UninstallPreferences, Bool>
}

class Uninstaller {
    private static let libraryUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    private static let pruneURLs: [URL] = [
        PlayTools.playCoverContainer.appendingPathComponent("App Settings"),
        PlayTools.playCoverContainer.appendingPathComponent("Certificates"),
        PlayTools.playCoverContainer.appendingPathComponent("AppBackups"),
        PlayTools.playCoverContainer.appendingPathComponent("Entitlements"),
        PlayTools.playCoverContainer.appendingPathComponent("Keymapping"),
        PlayTools.playCoverContainer.appendingPathComponent("PlayChain"),
        PlayTools.playCoverContainer.appendingPathComponent("SVCPatches")
    ]
    private static let cacheURLs: [URL] = [
        Uninstaller.libraryUrl.appendingPathComponent("Containers"),
        Uninstaller.libraryUrl.appendingPathComponent("Application Scripts"),
        Uninstaller.libraryUrl.appendingPathComponent("Caches"),
        Uninstaller.libraryUrl.appendingPathComponent("HTTPStorages"),
        Uninstaller.libraryUrl.appendingPathComponent("Saved Application State")
    ]

    private static func createButtonView(
        _ yaxis: CGFloat,
        _ text: String,
        _ keyPath: ReferenceWritableKeyPath<UninstallPreferences, Bool>,
        preferences: UninstallPreferences
    ) -> CheckBoxHelper {
        let button = NSButton(checkboxWithTitle: text, target: self, action: nil)

        if preferences[keyPath: keyPath] {
            button.animator().setNextState()
        }

        let view = NSView(frame: NSRect(x: 0, y: yaxis,
                                        width: button.fittingSize.width,
                                        height: button.fittingSize.height))

        view.addSubview(button)

        return CheckBoxHelper(view: view, button: button, preferenceKeyPath: keyPath)
    }

    @MainActor
    static func uninstallPopup(_ app: PlayApp, dependencies: PlayCoverDependencies? = nil) async {
        let prefs = dependencies?.uninstallPreferences
            ?? app.dependencies?.uninstallPreferences
            ?? UninstallPreferences()
        if prefs.showUninstallPopup {
            let boxmakers: [(ReferenceWritableKeyPath<UninstallPreferences, Bool>, String)] = [
                (\.removePlayChain, NSLocalizedString("preferences.toggle.removePlayChain", comment: "")),
                (\.removeAppEntitlements, NSLocalizedString("preferences.toggle.removeEntitlements", comment: "")),
                (\.removeAppNetworkRules, NSLocalizedString("preferences.toggle.removeNetworkRules", comment: "")),
                (\.removeAppSettings, NSLocalizedString("preferences.toggle.removeSetting", comment: "")),
                (\.removeAppKeymap, NSLocalizedString("preferences.toggle.removeKeymap", comment: "")),
                (\.clearAppData, NSLocalizedString("preferences.toggle.clearAppData", comment: ""))
            ]

            var checkboxes: [CheckBoxHelper] = []

            var viewY = 0.0

            for (keyPath, buttontitle) in boxmakers {
                checkboxes.append(createButtonView(viewY, buttontitle, keyPath, preferences: prefs))
                viewY += checkboxes[checkboxes.count - 1].view.frame.height
            }

            let viewWidth = checkboxes.max(by: { $0.view.frame.width < $1.view.frame.width })?.view.frame.width

            let settingsView = NSStackView(frame: NSRect(x: 0, y: 0, width: viewWidth ?? 0, height: viewY))

            for checkboxhelper in checkboxes {
                settingsView.addSubview(checkboxhelper.view)
            }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("playapp.delete", comment: "")
            alert.informativeText = String(format: NSLocalizedString("playapp.deleteMessage",
                                                                     comment: ""),
                                           arguments: [app.name])

            alert.alertStyle = .warning
            alert.accessoryView = settingsView

            let delete = alert.addButton(withTitle: NSLocalizedString("playapp.deleteConfirm", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "")

            delete.hasDestructiveAction = true

            NSApplication.shared.requestUserAttention(.criticalRequest)
            guard let window = NSApplication.shared.windows.first,
                  await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            for checkboxhelper in checkboxes {
                prefs[keyPath: checkboxhelper.preferenceKeyPath] =
                    (checkboxhelper.button.state == .on)
            }

            if alert.suppressionButton?.state == .on {
                prefs.showUninstallPopup = false
            }

            let alertPresenter = dependencies?.alertPresenter ?? app.dependencies?.alertPresenter
            await uninstall(app, preferences: prefs, alertPresenter: alertPresenter)
        } else {
            let alertPresenter = dependencies?.alertPresenter ?? app.dependencies?.alertPresenter
            await uninstall(app, preferences: prefs, alertPresenter: alertPresenter)
        }
    }

    static func uninstall(
        _ app: PlayApp,
        preferences: UninstallPreferences? = nil,
        alertPresenter: AlertPresenter? = nil
    ) async {
        let prefs = preferences ?? app.dependencies?.uninstallPreferences ?? UninstallPreferences()
        var uninstallNum = 0
        var clearError: Error?

        if prefs.clearAppData {
            clearError = await app.clearAllCache()
            uninstallNum += 1
        }

        if prefs.removeAppKeymap {
            FileManager.default.delete(at: app.keymapping.baseKeymapURL)
            uninstallNum += 1
        }

        let removeSettings = prefs.removeAppSettings
        let removeNetRules = prefs.removeAppNetworkRules
        let savedEnableNet = app.settings.settings.enableNetworkRules
        let savedMock200 = app.settings.settings.networkBlockMock200
        let savedPatterns = app.settings.settings.blockedURLPatterns
        let savedProxyMode = app.settings.settings.networkProxyMode
        let savedCustomCerts = app.settings.settings.enableCustomCertificates
        let hasConfiguredNetRules = savedEnableNet || !savedPatterns.isEmpty ||
            savedProxyMode != "direct" || savedCustomCerts

        if removeNetRules {
            let certsStore = PerAppCertificateStore(
                certificatesBaseURL: PlayTools.playCoverContainer.appendingPathComponent("Certificates"),
                appSettingsBaseURL: PlayTools.playCoverContainer.appendingPathComponent("App Settings")
            )
            certsStore.removeAllData(for: app.info.bundleIdentifier)
        }

        if removeSettings && removeNetRules {
            FileManager.default.delete(at: app.settings.settingsUrl)
            uninstallNum += 2
        } else if removeSettings && !removeNetRules {
            FileManager.default.delete(at: app.settings.settingsUrl)
            if hasConfiguredNetRules {
                app.settings.reset()
                app.settings.update {
                    $0.enableNetworkRules = savedEnableNet
                    $0.networkBlockMock200 = savedMock200
                    $0.blockedURLPatterns = savedPatterns
                    $0.networkProxyMode = savedProxyMode
                    $0.enableCustomCertificates = savedCustomCerts
                }
            }
            uninstallNum += 1
        } else if !removeSettings && removeNetRules {
            app.settings.update {
                $0.enableNetworkRules = false
                $0.networkBlockMock200 = true
                $0.blockedURLPatterns = []
                $0.networkProxyMode = "direct"
                $0.enableCustomCertificates = false
                $0.mitmRuntimePort = 0
                $0.mitmHostPatterns = []
            }
            uninstallNum += 1
        }

        if prefs.removeAppEntitlements {
            FileManager.default.delete(at: app.entitlements)
            uninstallNum += 1
        }

        if prefs.removePlayChain {
            app.clearPlayChain()
            uninstallNum += 1
        }

        app.removeAlias()
        FileManager.default.delete(at: app.appBackupsDir)
        FileManager.default.delete(at: app.svcPatchManifestURL)
        app.deleteApp()

        if uninstallNum >= 5 || FileManager.default.fileExists(atPath: PlayApp.bundleIDCacheURL.path) {
            do {
                let apps = (try PlayApp.bundleIDCache).filter { $0 != app.info.bundleIdentifier }
                let output = apps.isEmpty ? "" : "\(apps.joined(separator: "\n"))\n"
                try output.write(to: PlayApp.bundleIDCacheURL, atomically: true, encoding: .utf8)
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }

        if let err = clearError {
            if isPermissionError(err) {
                await presentPermissionAlert(err, alertPresenter: alertPresenter ?? app.dependencies?.alertPresenter)
            } else {
                PlayCoverDiagnostics.reportError(err)
            }
        }
    }

    @MainActor
    private static func presentPermissionAlert(_ err: Error, alertPresenter: AlertPresenter? = nil) async {
        let message = """
        macOS 阻止了 MacOver 访问该应用的沙盒容器目录（\(err.localizedDescription)）。

        这通常是因为 MacOver 重新编译签名后，macOS 原有的隐私授权记录失效。
        请在「系统设置 -> 隐私与安全性 -> 完全磁盘访问权限」中勾选（或先关闭再重新开启）MacOver，\
        或在终端执行以下命令重置授权后重试：
        tccutil reset All app.makedie.MacOver
        """
        let presenter = alertPresenter ?? AlertPresenter()
        let response = await presenter.present(
            PlayCoverAlertRequest(
                title: "无法清除应用数据（系统权限受限）",
                message: message,
                style: .warning,
                buttons: [
                    PlayCoverAlertButton(title: "打开系统设置"),
                    PlayCoverAlertButton(title: NSLocalizedString("button.Cancel", comment: ""), isCancel: true)
                ],
                defaultCancelIndex: 1
            )
        )
        if response.buttonIndex == 0,
           let settingsURL = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
           ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    @MainActor
    static func clearCachePopup(_ app: PlayApp, dependencies: PlayCoverDependencies? = nil) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.app.delete", comment: "")
        alert.alertStyle = .warning

        let proceed = alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        proceed.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        NSApplication.shared.requestUserAttention(.criticalRequest)
        guard let window = NSApplication.shared.windows.first,
              await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

        let bundleId = app.info.bundleIdentifier
        let bundleURL = app.url
        let err = await Task.detached(priority: .userInitiated) {
            await Uninstaller.clearExternalCache(bundleId, appBundleURL: bundleURL)
        }.value

        if let err = err {
            if isPermissionError(err) {
                let alertPresenter = dependencies?.alertPresenter ?? app.dependencies?.alertPresenter
                await presentPermissionAlert(err, alertPresenter: alertPresenter)
            } else {
                PlayCoverDiagnostics.reportError(err)
            }
        } else {
            PlayCoverDiagnostics.showToast(
                toastType: .notice,
                toastDetails: "\(app.name): \(NSLocalizedString("playapp.clearCache", comment: ""))"
            )
        }
    }

    static func clearCache(of app: PlayApp) async {
        await app.clearAllCache()
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain &&
            (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
            return true
        }
        return false
    }

    private static func terminateRunningAppIfNeeded(_ bundleId: String) async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !runningApps.isEmpty else { return }
        for running in runningApps {
            running.terminate()
        }
        for _ in 0..<15 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .allSatisfy({ $0.isTerminated }) {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        where !running.isTerminated {
            running.forceTerminate()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private static func removeOrTrashItem(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func isExternalContainerSymlink(_ url: URL, containerDataPath: String) -> Bool {
        guard let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              vals.isSymbolicLink == true else {
            return false
        }
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return true
        }
        let resolved: String
        if dest.hasPrefix("/") {
            resolved = (dest as NSString).standardizingPath
        } else {
            let parent = url.deletingLastPathComponent().path as NSString
            resolved = (parent.appendingPathComponent(dest) as NSString).standardizingPath
        }
        let normData = (containerDataPath as NSString).standardizingPath
        return !(resolved == normData || resolved.hasPrefix(normData + "/"))
    }

    private static func clearDirectoryChildren(_ dirURL: URL, containerDataPath: String) throws {
        guard FileManager.default.fileExists(atPath: dirURL.path) else { return }
        let items = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        )
        var firstError: Error?
        for item in items {
            let name = item.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix(".com.apple.containermanager") {
                continue
            }
            if isExternalContainerSymlink(item, containerDataPath: containerDataPath) {
                continue
            }
            let isSym = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            do {
                if isSym {
                    try FileManager.default.removeItem(at: item)
                } else {
                    try removeOrTrashItem(item)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let err = firstError {
            throw err
        }
    }

    private static func clearAppContainer(_ containerRoot: URL, bundleId: String) throws {
        guard FileManager.default.fileExists(atPath: containerRoot.path) else { return }
        let dataURL = containerRoot.appendingPathComponent("Data", isDirectory: true)
        let dataPath = dataURL.path
        let topItems: [URL]
        do {
            topItems = try FileManager.default.contentsOfDirectory(
                at: dataURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: []
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoSuchFileError {
            return
        }
        var firstError: Error?
        let preservedShells: Set<String> = ["Documents", "tmp", "SystemData"]
        let libShells: Set<String> = ["Caches", "Application Support", "Preferences"]

        for item in topItems {
            let name = item.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix(".com.apple.containermanager") {
                continue
            }
            if isExternalContainerSymlink(item, containerDataPath: dataPath) {
                continue
            }
            do {
                if preservedShells.contains(name) {
                    try clearDirectoryChildren(item, containerDataPath: dataPath)
                } else if name == "Library" {
                    let libItems = try FileManager.default.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                        options: []
                    )
                    for libItem in libItems {
                        let libName = libItem.lastPathComponent
                        if libName == ".DS_Store" ||
                            isExternalContainerSymlink(libItem, containerDataPath: dataPath) {
                            continue
                        }
                        if libShells.contains(libName) {
                            try clearDirectoryChildren(libItem, containerDataPath: dataPath)
                        } else {
                            let isSym = (try? libItem.resourceValues(
                                forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                            if isSym {
                                try FileManager.default.removeItem(at: libItem)
                            } else {
                                try removeOrTrashItem(libItem)
                            }
                        }
                    }
                } else {
                    let isSym = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                    if isSym {
                        try FileManager.default.removeItem(at: item)
                    } else {
                        try removeOrTrashItem(item)
                    }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let err = firstError {
            throw err
        }
    }

    @discardableResult
    static func clearExternalCache(_ bundleId: String,
                                   appBundleURL: URL? = nil) async -> Error? {
        guard !bundleId.isEmpty else { return nil }
        await terminateRunningAppIfNeeded(bundleId)

        var firstError: Error?
        let targetIds = AppContainer.targetContainerIdentifiers(for: bundleId, appBundleURL: appBundleURL)

        // Group Containers under ~/Library/Group Containers may be shared with native macOS apps,
        // app extensions, or external bundles outside PlayCover's registry whose entitlements cannot
        // be exhaustively verified in user space; preserve Group Containers to avoid wiping shared data.
        for match in AppContainer.allMatchingContainerURLs(for: bundleId, appBundleURL: appBundleURL) {
            do {
                try clearAppContainer(match.url, bundleId: match.identifier)
            } catch {
                PlayCoverDiagnostics.log("Failed to clear container \(match.url.path): \(error)", isError: true)
                if firstError == nil { firstError = error }
            }
        }

        var exactCacheNames: Set<String> = []
        for id in targetIds {
            exactCacheNames.insert(id)
            exactCacheNames.insert("\(id).savedState")
            exactCacheNames.insert("\(id).binarycookies")
        }

        for cache in cacheURLs where cache.lastPathComponent != "Containers" {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: cache,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for file in items where exactCacheNames.contains(file.lastPathComponent) {
                do {
                    try removeOrTrashItem(file)
                } catch {
                    PlayCoverDiagnostics.log("Failed to clear cache \(file.path): \(error)", isError: true)
                    if firstError == nil { firstError = error }
                }
            }
        }

        _ = try? Shell.run(print: false, "/usr/bin/killall", "cfprefsd")
        return firstError
    }

    static func resolvePruneBundleIdentifier(for file: URL, in dirName: String) -> String {
        switch dirName {
        case "Containers":
            return AppContainer.containerIdentity(at: file) ?? file.lastPathComponent
        case "Entitlements", "App Settings":
            let name = file.deletingPathExtension().lastPathComponent
            if name.hasSuffix(".invalid") {
                return String(name.dropLast(".invalid".count))
            }
            return name
        case "SVCPatches":
            return file.pathExtension == "json"
                ? file.deletingPathExtension().lastPathComponent
                : file.lastPathComponent
        case "PlayChain":
            var name = file.lastPathComponent
            for suffix in ["-wal", "-shm", "-journal"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
            return URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        case "Saved Application State":
            return file.pathExtension == "savedState"
                ? file.deletingPathExtension().lastPathComponent
                : file.lastPathComponent
        default:
            return file.lastPathComponent
        }
    }

    static func pruneFiles(appsVM: AppsVM? = nil) {
        Task { @MainActor in
            let knownAppIds = Set((appsVM?.apps ?? []).map { $0.info.bundleIdentifier })
            await Task.detached(priority: .utility) {
                do {
                    let diskScan = AppContainer.scanActiveIdentifiers()
                    guard diskScan.complete else {
                        PlayCoverDiagnostics.log(
                            "Skipping pruneFiles: disk scan of installed app bundles was incomplete.",
                            isError: true
                        )
                        return
                    }
                    var activeIds = diskScan.ids
                    activeIds.formUnion(knownAppIds)

                    let cachedIds = try PlayApp.bundleIDCache
                    let danglingItems = Set(cachedIds.filter { !$0.isEmpty && !activeIds.contains($0) })

                    var fullPruneURLs = pruneURLs
                    fullPruneURLs.append(contentsOf: cacheURLs)

                    let prunedIdsBox = Mutex<Set<String>>([])

                    for url in fullPruneURLs {
                        let dirName = url.lastPathComponent
                        let isContainersDir = (dirName == "Containers")
                        url.enumerateContents(options: [.skipsSubdirectoryDescendants]) { file, _ in
                            let resolvedId = resolvePruneBundleIdentifier(for: file, in: dirName)
                            if danglingItems.contains(resolvedId) {
                                if isContainersDir {
                                    try clearAppContainer(file, bundleId: resolvedId)
                                } else {
                                    try removeOrTrashItem(file)
                                    if dirName == "App Settings" {
                                        let certsBundle = file.appendingPathExtension("certs")
                                        try? removeOrTrashItem(certsBundle)
                                    }
                                }
                                prunedIdsBox.withLock { _ = $0.insert(resolvedId) }
                            }
                        }
                    }

                    let prunedIds = prunedIdsBox.withLock { $0 }

                    let remaining = cachedIds.filter { !$0.isEmpty && !prunedIds.contains($0) }
                    let output = remaining.isEmpty ? "" : "\(remaining.joined(separator: "\n"))\n"
                    try output.write(to: PlayApp.bundleIDCacheURL, atomically: true, encoding: .utf8)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }.value
        }
    }
}
