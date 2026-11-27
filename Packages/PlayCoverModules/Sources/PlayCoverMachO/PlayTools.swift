//
//  PlayTools.swift
//  PlayCover
//

import CryptoKit
import Darwin
import Foundation
import MachO
import PlayCoverCore
import Synchronization

// This has so many functionality in it that 250 lines is darn near impossible
public class PlayTools {
    private static let containerBaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Containers")
        .appendingPathComponent("app.makedie.MacOver")
    private static let frameworksURL = containerBaseURL
        .appendingPathComponent("Frameworks")
    private static let playToolsFramework = frameworksURL
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")
    public static let playToolsPath = playToolsFramework
        .appendingPathComponent("PlayTools")
    private static let legacyPlayToolsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")
        .appendingPathComponent("PlayTools")
    private static let akInterfacePath = playToolsFramework
        .appendingPathComponent("PlugIns")
        .appendingPathComponent("AKInterface")
        .appendingPathExtension("bundle")
    private static let bundledPlayToolsFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")

    public static var playCoverContainer: URL {
        let playCoverPath = containerBaseURL
        if !FileManager.default.fileExists(atPath: playCoverPath.path) {
            do {
                try FileManager.default.createDirectory(at: playCoverPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }

        return playCoverPath
    }

    private struct InstallState {
        var currentInstallTask: Task<Void, Error>?
        var lastInstallError: Error?
    }

    public struct FileStatStamp: Codable, Equatable, Sendable {
        public let inode: UInt64
        public let size: Int64
        public let mtimeSec: Int
        public let mtimeNSec: Int

        public init(inode: UInt64, size: Int64, mtimeSec: Int, mtimeNSec: Int) {
            self.inode = inode
            self.size = size
            self.mtimeSec = mtimeSec
            self.mtimeNSec = mtimeNSec
        }
    }

    private struct PlayToolsInstallStamp: Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let bundledPlayToolsSHA256: String
        let bundledAKInterfaceSHA256: String
        let bundledInfoPlistSHA256: String
        let bundledStringsSHA256: String?
        let installedPlayTools: FileStatStamp
        let installedAKInterface: FileStatStamp
    }

    private static let installStampURL = frameworksURL.appendingPathComponent(".playtools-install-stamp.json")

    public static func fileStamp(for url: URL) -> FileStatStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileStatStamp(
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSec: Int(st.st_mtimespec.tv_sec),
            mtimeNSec: Int(st.st_mtimespec.tv_nsec)
        )
    }

    private static func fileSHA256Hex(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func optionalFileSHA256Hex(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? fileSHA256Hex(at: url)
    }

    private static func bundledDigests(
        at frameworkURL: URL
    ) throws -> (playTools: String, akInterface: String, infoPlist: String, strings: String?) {
        let playToolsURL = frameworkURL.appendingPathComponent("PlayTools")
        let akURL = frameworkURL
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface.bundle/Contents/MacOS/AKInterface")
        let infoURL = frameworkURL.appendingPathComponent("Resources/Info.plist")
        let fallbackInfoURL = frameworkURL.appendingPathComponent("Info.plist")
        let resolvedInfoURL = FileManager.default.fileExists(atPath: infoURL.path) ? infoURL : fallbackInfoURL
        let stringsURL = frameworkURL.appendingPathComponent("Resources/Playtools.xcstrings")

        return (
            playTools: try fileSHA256Hex(at: playToolsURL),
            akInterface: try fileSHA256Hex(at: akURL),
            infoPlist: try fileSHA256Hex(at: resolvedInfoURL),
            strings: optionalFileSHA256Hex(at: stringsURL)
        )
    }

    private static let installState = Mutex<InstallState>(InstallState())

    private static func clearExtendedAttributes(at url: URL) {
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", url.path)
    }

    private static func filesMatchFast(source: URL, target: URL) -> Bool {
        var srcStat = stat()
        var dstStat = stat()
        guard stat(source.path, &srcStat) == 0, stat(target.path, &dstStat) == 0 else {
            return false
        }
        guard srcStat.st_size == dstStat.st_size else {
            return false
        }
        if srcStat.st_mtimespec.tv_sec == dstStat.st_mtimespec.tv_sec &&
            srcStat.st_mtimespec.tv_nsec == dstStat.st_mtimespec.tv_nsec {
            return true
        }
        return FileManager.default.contentsEqual(atPath: source.path, andPath: target.path)
    }

    private static func validateFrameworkBundle(at frameworkURL: URL) throws {
        let fm = FileManager.default
        let binaryURL = frameworkURL.appendingPathComponent("PlayTools")
        let akBundleURL = frameworkURL
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface")
            .appendingPathExtension("bundle")

        guard fm.fileExists(atPath: binaryURL.path),
              fm.fileExists(atPath: akBundleURL.path),
              try Macho.isMachoValidArch(binaryURL) else {
            throw PlayCoverError.playToolsError(
                "Bundled PlayTools.framework is incomplete or has an invalid Mach-O binary."
            )
        }

        do {
            try Shell.verifyAppSignature(frameworkURL)
        } catch {
            try Shell.signMacho(akBundleURL)
            try Shell.signMacho(frameworkURL)
            try Shell.verifyAppSignature(frameworkURL)
        }
    }

    @discardableResult
    public static func ensureSystemInstall(
        bundledFrameworkURL: URL? = nil,
        installedFrameworkURL: URL? = nil,
        stampURL: URL? = nil,
        validator: ((URL) throws -> Void)? = nil
    ) throws -> Bool {
        let interval = PerformanceSignpost.beginInterval("PlayToolsEnsureSystemInstall")
        defer { PerformanceSignpost.endInterval("PlayToolsEnsureSystemInstall", interval) }

        let resolvedBundledURL = bundledFrameworkURL ?? Self.bundledPlayToolsFramework
        let resolvedInstalledURL = installedFrameworkURL ?? Self.playToolsFramework

        let fm = FileManager.default
        let resolvedStampURL = stampURL
            ?? resolvedInstalledURL.deletingLastPathComponent().appendingPathComponent(".playtools-install-stamp.json")
        let targetParentURL = resolvedInstalledURL.deletingLastPathComponent()

        guard fm.fileExists(atPath: resolvedBundledURL.path) else {
            throw PlayCoverError.playToolsError(
                "Bundled PlayTools.framework not found inside MacOver.app."
            )
        }

        let sourceDigests = try bundledDigests(at: resolvedBundledURL)
        let installedExecURL = resolvedInstalledURL.appendingPathComponent("PlayTools")
        let installedAKURL = resolvedInstalledURL
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface.bundle/Contents/MacOS/AKInterface")

        if fm.fileExists(atPath: resolvedInstalledURL.path),
           let installedPTStamp = fileStamp(for: installedExecURL),
           let installedAKStamp = fileStamp(for: installedAKURL),
           let stampData = try? Data(contentsOf: resolvedStampURL),
           let savedStamp = try? JSONDecoder().decode(PlayToolsInstallStamp.self, from: stampData),
           savedStamp.schemaVersion == PlayToolsInstallStamp.currentSchemaVersion,
           savedStamp.bundledPlayToolsSHA256 == sourceDigests.playTools,
           savedStamp.bundledAKInterfaceSHA256 == sourceDigests.akInterface,
           savedStamp.bundledInfoPlistSHA256 == sourceDigests.infoPlist,
           savedStamp.bundledStringsSHA256 == sourceDigests.strings,
           savedStamp.installedPlayTools == installedPTStamp,
           savedStamp.installedAKInterface == installedAKStamp {
            return false
        }

        PlayCoverDiagnostics.log("Installing PlayTools")
        if !fm.fileExists(atPath: targetParentURL.path) {
            try fm.createDirectory(
                atPath: targetParentURL.path,
                withIntermediateDirectories: true,
                attributes: [:]
            )
        }

        let stagingDir = targetParentURL.appendingPathComponent(
            ".PlayTools.staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedFramework = stagingDir.appendingPathComponent(
            resolvedInstalledURL.lastPathComponent,
            isDirectory: true
        )
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDir)
        }

        PlayCoverDiagnostics.log("Staging PlayTools in Frameworks")
        try fm.copyItem(at: resolvedBundledURL, to: stagedFramework)
        clearExtendedAttributes(at: stagedFramework)
        if let validator {
            try validator(stagedFramework)
        } else {
            try validateFrameworkBundle(at: stagedFramework)
        }

        if fm.fileExists(atPath: resolvedInstalledURL.path) {
            let swapRc = Darwin.renamex_np(
                stagedFramework.path,
                resolvedInstalledURL.path,
                UInt32(RENAME_SWAP)
            )
            if swapRc != 0 {
                let backupFramework = stagingDir.appendingPathComponent(
                    "PlayTools.framework.backup",
                    isDirectory: true
                )
                try fm.moveItem(at: resolvedInstalledURL, to: backupFramework)
                do {
                    try fm.moveItem(at: stagedFramework, to: resolvedInstalledURL)
                } catch {
                    try? fm.moveItem(at: backupFramework, to: resolvedInstalledURL)
                    throw error
                }
            }
        } else {
            try fm.moveItem(at: stagedFramework, to: resolvedInstalledURL)
        }

        if let installedPTStamp = fileStamp(for: installedExecURL),
           let installedAKStamp = fileStamp(for: installedAKURL) {
            let stamp = PlayToolsInstallStamp(
                schemaVersion: PlayToolsInstallStamp.currentSchemaVersion,
                bundledPlayToolsSHA256: sourceDigests.playTools,
                bundledAKInterfaceSHA256: sourceDigests.akInterface,
                bundledInfoPlistSHA256: sourceDigests.infoPlist,
                bundledStringsSHA256: sourceDigests.strings,
                installedPlayTools: installedPTStamp,
                installedAKInterface: installedAKStamp
            )
            if let encoded = try? JSONEncoder().encode(stamp) {
                try? encoded.write(to: resolvedStampURL, options: .atomic)
            }
        }

        return true
    }

    private static func performStagedSystemInstall() throws {
        _ = try ensureSystemInstall()
        guard try isInstalled() else {
            throw PlayCoverError.playToolsError(
                "PlayTools.framework verification failed after installation."
            )
        }
    }

    @discardableResult
    private static func startOrJoinSystemInstall(reportError: Bool) -> Task<Void, Error> {
        installState.withLock { state in
            if let existing = state.currentInstallTask {
                return existing
            }
            let task = Task.detached(priority: .userInitiated) {
                defer {
                    installState.withLock { inner in
                        inner.currentInstallTask = nil
                    }
                }
                do {
                    try performStagedSystemInstall()
                    installState.withLock { inner in
                        inner.lastInstallError = nil
                    }
                } catch {
                    installState.withLock { inner in
                        inner.lastInstallError = error
                    }
                    PlayCoverDiagnostics.log("PlayTools installation failed: \(error)", isError: true)
                    if reportError {
                        PlayCoverDiagnostics.reportError(error)
                    }
                    throw error
                }
            }
            state.currentInstallTask = task
            return task
        }
    }

    public static func installOnSystem() {
        _ = startOrJoinSystemInstall(reportError: true)
    }

    public static func waitForSystemInstall() async {
        let activeTask = installState.withLock { $0.currentInstallTask }

        if let activeTask {
            _ = try? await activeTask.value
            return
        }

        if (try? isInstalled()) != true {
            let retryTask = startOrJoinSystemInstall(reportError: false)
            _ = try? await retryTask.value
        }
    }

    public static func systemInstallFailure() -> Error? {
        installState.withLock { $0.lastInstallError }
    }

    @concurrent
    public static func installInIPA(_ exec: URL, appInfo: AppInfo? = nil, signBundle: Bool = true) async throws {
        await waitForSystemInstall()
        _ = try Macho.removeLoadCommand(
            at: exec,
            dylibPaths: [
                legacyPlayToolsPath.path,
                legacyPlayToolsPath.esc
            ]
        )
        try Macho.injectLoadCommand(
            at: exec,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: playToolsPath.path
        )

        let payload = exec.deletingLastPathComponent()
        try installPluginInIPA(payload)

        let resolvedBundleID: String
        if let appInfo {
            resolvedBundleID = appInfo.bundleIdentifier
        } else {
            let info = AppInfo(contentsOf: payload.appendingPathComponent("Info")
                                                  .appendingPathExtension("plist"))
            resolvedBundleID = info.bundleIdentifier
        }
        try syncUserDylibs(bundleIdentifier: resolvedBundleID, into: exec)

        if signBundle {
            try Shell.signApp(exec)
        }
    }

    @discardableResult
    public static func installPluginInIPA(_ payload: URL) throws -> Bool {
        // Playtools localization strings live inside PlayTools.framework Resources and are resolved
        // via Bundle(for: PlayCover.self), so we must not inject .lproj directories into the guest app bundle.
        try installComponentBundles(into: payload)
    }

    @discardableResult
    public static func installComponentBundles(into payload: URL) throws -> Bool {
        var modified = false
        let fm = FileManager.default
        let pluginsSource = bundledPlayToolsFramework.appendingPathComponent("PlugIns")
        let pluginsTarget = payload.appendingPathComponent("PlugIns")
        try fm.createDirectory(at: pluginsTarget, withIntermediateDirectories: true)

        let bundleNames = try fm.contentsOfDirectory(atPath: pluginsSource.path)
        let bundles = bundleNames
            .map { pluginsSource.appendingPathComponent($0) }
            .filter { $0.pathExtension == "bundle" }

        for bundleSource in bundles {
            let bundleTarget = pluginsTarget.appendingPathComponent(bundleSource.lastPathComponent)
            let execName = bundleSource.deletingPathExtension().lastPathComponent
            let srcExec = bundleSource.appendingPathComponent("Contents/MacOS").appendingPathComponent(execName)
            let dstExec = bundleTarget.appendingPathComponent("Contents/MacOS").appendingPathComponent(execName)
            let srcInfo = bundleSource.appendingPathComponent("Contents/Info.plist")
            let dstInfo = bundleTarget.appendingPathComponent("Contents/Info.plist")

            if fm.fileExists(atPath: dstExec.path),
               filesMatchFast(source: srcExec, target: dstExec),
               filesMatchFast(source: srcInfo, target: dstInfo),
               let perms = (try? fm.attributesOfItem(atPath: dstExec.path)[.posixPermissions] as? NSNumber)?.intValue,
               (perms & 0o111) != 0 {
                continue
            }

            if fm.fileExists(atPath: bundleTarget.path) {
                try fm.removeItem(at: bundleTarget)
            }
            try fm.copyItem(at: bundleSource, to: bundleTarget)
            clearExtendedAttributes(at: bundleTarget)
            try bundleTarget.fixExecutable()
            try Shell.signMacho(bundleTarget)
            modified = true
        }
        return modified
    }

    public static func copyAsset(source: URL? = nil, target: URL, directoryName: String,
                                 component: String, pathExtension: String) throws -> URL {
        try copyAssetIfChanged(source: source ?? bundledPlayToolsFramework,
                               target: target,
                               directoryName: directoryName,
                               component: component,
                               pathExtension: pathExtension).url
    }

    private static func copyAssetIfChanged(
        source: URL = bundledPlayToolsFramework,
        target: URL,
        directoryName: String,
        component: String,
        pathExtension: String
    ) throws -> (url: URL, changed: Bool) {
        let fm = FileManager.default
        let directory = target.appendingPathComponent(directoryName)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetFile = directory
            .appendingPathComponent(component)
            .appendingPathExtension(pathExtension)

        let sourceFile = source
            .appendingPathComponent(directoryName)
            .appendingPathComponent(component)
            .appendingPathExtension(pathExtension)
        if fm.fileExists(atPath: targetFile.path) &&
            filesMatchFast(source: sourceFile, target: targetFile) {
            return (targetFile, false)
        }
        do {
            try fm.copyItem(at: sourceFile, to: targetFile)
        } catch {
            try fm.removeItem(at: targetFile)
            try fm.copyItem(at: sourceFile, to: targetFile)
        }
        clearExtendedAttributes(at: targetFile)
        return (targetFile, true)
    }

    public static func injectInIPA(_ exec: URL, payload: URL) throws {
        try Macho.injectLoadCommand(
            at: exec,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: "@executable_path/Frameworks/PlayTools.dylib"
        )

        let frameworksDir = payload.appendingPathComponent("Frameworks")
        if !FileManager.default.fileExists(atPath: frameworksDir.path) {
            try FileManager.default.createDirectory(
                at: frameworksDir,
                withIntermediateDirectories: true
            )
        }

        let libraryTarget = frameworksDir
            .appendingPathComponent("PlayTools")
            .appendingPathExtension("dylib")

        let tools = bundledPlayToolsFramework
            .appendingPathComponent("PlayTools")

        if FileManager.default.fileExists(atPath: libraryTarget.path) {
            try FileManager.default.removeItem(at: libraryTarget)
        }
        try FileManager.default.copyItem(at: tools, to: libraryTarget)
        clearExtendedAttributes(at: libraryTarget)
        try libraryTarget.fixExecutable()
        try installPluginInIPA(payload)
    }

    private static func resolveAppBundleAndInfo(
        for exec: URL,
        appBundleURL: URL?,
        bundleIdentifier: String?
    ) -> (bundleURL: URL, bundleID: String) {
        let resolvedBundleURL: URL
        if let appBundleURL {
            resolvedBundleURL = appBundleURL
        } else {
            let parent = exec.deletingLastPathComponent()
            let grandParent = parent.deletingLastPathComponent()
            if parent.lastPathComponent == "MacOS" && grandParent.lastPathComponent == "Contents" {
                resolvedBundleURL = grandParent.deletingLastPathComponent()
            } else {
                resolvedBundleURL = parent
            }
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return (resolvedBundleURL, bundleIdentifier)
        }
        let directInfo = resolvedBundleURL.appendingPathComponent("Info.plist")
        let contentsInfo = resolvedBundleURL.appendingPathComponent("Contents/Info.plist")
        for plistURL in [directInfo, contentsInfo] where FileManager.default.fileExists(atPath: plistURL.path) {
            let parsedID = AppInfo(contentsOf: plistURL).bundleIdentifier
            if !parsedID.isEmpty {
                return (resolvedBundleURL, parsedID)
            }
        }
        return (resolvedBundleURL, "")
    }

    @concurrent
    public static func removeFromApp(
        _ exec: URL,
        appBundleURL: URL? = nil,
        bundleIdentifier: String? = nil,
        svcManifestURL: URL? = nil,
        signMacho: @Sendable (URL) throws -> Void = { try Shell.signMacho($0) },
        signApp: @Sendable (URL) throws -> Void = { try Shell.signApp($0) }
    ) async {
        do {
            let resolved = resolveAppBundleAndInfo(
                for: exec,
                appBundleURL: appBundleURL,
                bundleIdentifier: bundleIdentifier
            )
            let resolvedManifestURL: URL?
            if let svcManifestURL {
                resolvedManifestURL = svcManifestURL
            } else if !resolved.bundleID.isEmpty {
                resolvedManifestURL = playCoverContainer
                    .appendingPathComponent("SVCPatches")
                    .appendingPathComponent("\(resolved.bundleID).json")
            } else {
                resolvedManifestURL = nil
            }
            if let resolvedManifestURL {
                let svcResult = try InlineSyscallPatcher.reconcile(
                    appBundleURL: resolved.bundleURL,
                    bundleIdentifier: resolved.bundleID,
                    manifestURL: resolvedManifestURL,
                    enabled: false
                )
                if svcResult.modified {
                    let execCanonical = exec.standardizedFileURL.resolvingSymlinksInPath()
                    for modifiedURL in svcResult.modifiedBinaryURLs where
                        modifiedURL.standardizedFileURL.resolvingSymlinksInPath() != execCanonical {
                        try signMacho(modifiedURL)
                    }
                }
            }

            try Macho.removeLoadCommand(
                at: exec,
                dylibPaths: [
                    playToolsPath.path,
                    playToolsPath.esc,
                    legacyPlayToolsPath.path,
                    legacyPlayToolsPath.esc,
                    "@executable_path/Frameworks/PlayTools.dylib"
                ]
            )

            let fm = FileManager.default
            let appDir = exec.deletingLastPathComponent()
            let pluginsUrl = appDir.appendingPathComponent("PlugIns")
            let akInterfaceUrl = pluginsUrl.appendingPathComponent("AKInterface.bundle")

            if fm.fileExists(atPath: akInterfaceUrl.path) {
                try fm.removeItem(at: akInterfaceUrl)
            }
            if fm.fileExists(atPath: pluginsUrl.path),
               let remaining = try? fm.contentsOfDirectory(atPath: pluginsUrl.path),
               remaining.isEmpty {
                try fm.removeItem(at: pluginsUrl)
            }

            if let contents = try? fm.contentsOfDirectory(
                at: appDir,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                for item in contents where item.pathExtension == "lproj" {
                    let stringsUrl = item.appendingPathComponent("Playtools.strings")
                    if fm.fileExists(atPath: stringsUrl.path) {
                        try fm.removeItem(at: stringsUrl)
                    }
                }
            }

            let userPluginsUrl = appDir
                .appendingPathComponent("Frameworks")
                .appendingPathComponent("UserPlugins")
            if fm.fileExists(atPath: userPluginsUrl.path) {
                try fm.removeItem(at: userPluginsUrl)
            }

            try signApp(exec)
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    public static func installedInExec(atURL url: URL) throws -> Bool {
        let binary = try Macho.readHeaderSlice(at: url)
        var result = false
        _ = try Macho.iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = try binary.extract(load_command.self, offset: offset,
                                                 swap: shouldSwap ? { MachOByteSwap.swapLoadCommand(&$0) } : nil)
            if loadCommand.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCommand = try binary.extract(dylib_command.self, offset: offset,
                                                      swap: shouldSwap ? { MachOByteSwap.swapDylibCommand(&$0) } : nil)

                let dylibName = String(data: binary,
                                       offset: offset,
                                       commandSize: Int(dylibCommand.cmdsize),
                                       loadCommandString: dylibCommand.dylib.name)
                if dylibName == playToolsPath.path || dylibName == playToolsPath.esc {
                    result = true
                    return true
                }
            }
            return false
        }
        return result
    }

    public static func isInstalled() throws -> Bool {
        try FileManager.default.fileExists(atPath: playToolsPath.path)
            && FileManager.default.fileExists(atPath: akInterfacePath.path)
            && Macho.isMachoValidArch(playToolsPath)
    }

    // User plugins loading
    private static func userPluginsStore(bundleIdentifier: String) -> URL {
        playCoverContainer
            .appendingPathComponent("PlayTools")
            .appendingPathComponent("UserPlugins")
            .appendingPathComponent(bundleIdentifier)
    }

    public static func userDylibs(bundleIdentifier: String) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: userPluginsStore(bundleIdentifier: bundleIdentifier), includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "dylib" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func addUserDylib(at sourceURL: URL, bundleIdentifier: String, appExecutable: URL) throws {
        let store = userPluginsStore(bundleIdentifier: bundleIdentifier)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        let canonical = store.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: canonical.path) {
            try FileManager.default.removeItem(at: canonical)
        }
        try FileManager.default.copyItem(at: sourceURL, to: canonical)

        do {
            // Validate & convert the plugin
            if try !Macho.isMachoValidArch(canonical) {
                try Macho.convertMacho(canonical)
            }
        } catch {
            try? FileManager.default.removeItem(at: canonical)
            throw PlayCoverError.invalidUserDylib
        }

        // Downloaded files carry quarantine/provenance flags that block dlopen(); best-effort clear them.
        clearExtendedAttributes(at: canonical)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let sourceDir = sourceURL.deletingLastPathComponent()
        let destManifest = store.appendingPathComponent("\(stem).manifest.json")
        let sidecarCandidate = sourceDir.appendingPathComponent("\(stem).manifest.json")
        let bundleManifestCandidate = sourceDir.appendingPathComponent("PluginManifest.json")
        let fm = FileManager.default

        if fm.fileExists(atPath: sidecarCandidate.path) {
            if fm.fileExists(atPath: destManifest.path) {
                try? fm.removeItem(at: destManifest)
            }
            try fm.copyItem(at: sidecarCandidate, to: destManifest)
            clearExtendedAttributes(at: destManifest)
        } else if fm.fileExists(atPath: bundleManifestCandidate.path),
                  let manifestData = try? Data(contentsOf: bundleManifestCandidate),
                  let manifestObj = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
                  (manifestObj["entrypoint"] as? String) == sourceURL.lastPathComponent {
            if fm.fileExists(atPath: destManifest.path) {
                try? fm.removeItem(at: destManifest)
            }
            try fm.copyItem(at: bundleManifestCandidate, to: destManifest)
            clearExtendedAttributes(at: destManifest)
        }

        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable)
    }

    public static func removeUserDylib(named name: String, bundleIdentifier: String, appExecutable: URL) throws {
        let store = userPluginsStore(bundleIdentifier: bundleIdentifier)
        let canonical = store.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: canonical.path) {
            try FileManager.default.removeItem(at: canonical)
        }
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        if !stem.isEmpty {
            let sidecarManifest = store.appendingPathComponent("\(stem).manifest.json")
            if FileManager.default.fileExists(atPath: sidecarManifest.path) {
                try FileManager.default.removeItem(at: sidecarManifest)
            }
        }
        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable)
    }

    // Resync
    public static func syncUserDylibs(bundleIdentifier: String, into appExecutable: URL) throws {
        let targetDirectory = appExecutable.deletingLastPathComponent()
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("UserPlugins")

        try syncUserPlugins(
            from: userPluginsStore(bundleIdentifier: bundleIdentifier),
            into: targetDirectory
        )
    }

    public static func syncUserPlugins(
        from storeDirectory: URL,
        into targetDirectory: URL,
        signMacho: (URL) throws -> Void = { try Shell.signMacho($0) }
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: targetDirectory.path) {
            try fm.removeItem(at: targetDirectory)
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var topDylibs: [URL] = []
        var topManifests: [URL] = []
        var pluginDirs: [URL] = []

        for entry in sortedEntries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let manifestCandidate = entry.appendingPathComponent("PluginManifest.json")
                if fm.fileExists(atPath: manifestCandidate.path) {
                    pluginDirs.append(entry)
                }
            } else if entry.pathExtension == "dylib" {
                topDylibs.append(entry)
            } else if entry.lastPathComponent.hasSuffix(".manifest.json") {
                topManifests.append(entry)
            }
        }

        guard !topDylibs.isEmpty || !topManifests.isEmpty || !pluginDirs.isEmpty else {
            return
        }

        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        for source in topDylibs {
            let target = targetDirectory.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: target)
            clearExtendedAttributes(at: target)
            try target.fixExecutable()
            try signMacho(target)
        }

        for manifest in topManifests {
            let target = targetDirectory.appendingPathComponent(manifest.lastPathComponent)
            try fm.copyItem(at: manifest, to: target)
            clearExtendedAttributes(at: target)
        }

        for dir in pluginDirs {
            let target = targetDirectory.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            try fm.copyItem(at: dir, to: target)
            clearExtendedAttributes(at: target)
            if let enumerator = fm.enumerator(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let item as URL in enumerator {
                    let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if !itemIsDir && item.pathExtension == "dylib" {
                        try item.fixExecutable()
                        try signMacho(item)
                    }
                }
            }
        }
    }

    public static func fetchEntitlements(_ exec: URL) throws -> String {
        do {
            return try Shell.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", exec.path)
        } catch {
            if error.localizedDescription.contains("Document is empty") {
                // Empty entitlements
                return ""
            } else if error.localizedDescription.contains("code object is not signed at all") {
                // IPA not signed
                return ""
            } else {
                throw error
            }
        }
    }
}
