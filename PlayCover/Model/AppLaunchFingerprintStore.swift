//
//  AppLaunchFingerprintStore.swift
//  PlayCover
//

import CryptoKit
import Foundation
import PlayCoverCore
import PlayCoverMachO
import Synchronization

nonisolated struct LaunchFastPathStamp: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let exec: PlayTools.FileStatStamp
    let infoPlist: PlayTools.FileStatStamp
    let codeResources: PlayTools.FileStatStamp?
    let frameworksDir: PlayTools.FileStatStamp?
    let plugInsDir: PlayTools.FileStatStamp?
    let akExec: PlayTools.FileStatStamp?
    let playTools: PlayTools.FileStatStamp
    let usesPlayTools: Bool
    let isCatalyst: Bool
    let strictEmulationMode: Bool
    let interceptInlineSyscalls: Bool
    let enableAutomationBridge: Bool
    let coverUseBridge: PlayTools.FileStatStamp?
    let coverUseBridgeStaged: Bool
    let storedHasIntrospection: Bool
    let storedHasIosFrameworks: Bool
    let entitlementsInputsHash: String
    let userPluginsStoreDigest: String?
    let bundledUserPluginsDigest: String?
    let svcPatchManifest: PlayTools.FileStatStamp?

    init(
        schemaVersion: Int,
        exec: PlayTools.FileStatStamp,
        infoPlist: PlayTools.FileStatStamp,
        codeResources: PlayTools.FileStatStamp?,
        frameworksDir: PlayTools.FileStatStamp?,
        plugInsDir: PlayTools.FileStatStamp?,
        akExec: PlayTools.FileStatStamp?,
        playTools: PlayTools.FileStatStamp,
        usesPlayTools: Bool,
        isCatalyst: Bool,
        strictEmulationMode: Bool,
        interceptInlineSyscalls: Bool,
        enableAutomationBridge: Bool,
        coverUseBridge: PlayTools.FileStatStamp?,
        coverUseBridgeStaged: Bool,
        storedHasIntrospection: Bool,
        storedHasIosFrameworks: Bool,
        entitlementsInputsHash: String,
        userPluginsStoreDigest: String? = nil,
        bundledUserPluginsDigest: String? = nil,
        svcPatchManifest: PlayTools.FileStatStamp? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exec = exec
        self.infoPlist = infoPlist
        self.codeResources = codeResources
        self.frameworksDir = frameworksDir
        self.plugInsDir = plugInsDir
        self.akExec = akExec
        self.playTools = playTools
        self.usesPlayTools = usesPlayTools
        self.isCatalyst = isCatalyst
        self.strictEmulationMode = strictEmulationMode
        self.interceptInlineSyscalls = interceptInlineSyscalls
        self.enableAutomationBridge = enableAutomationBridge
        self.coverUseBridge = coverUseBridge
        self.coverUseBridgeStaged = coverUseBridgeStaged
        self.storedHasIntrospection = storedHasIntrospection
        self.storedHasIosFrameworks = storedHasIosFrameworks
        self.entitlementsInputsHash = entitlementsInputsHash
        self.userPluginsStoreDigest = userPluginsStoreDigest
        self.bundledUserPluginsDigest = bundledUserPluginsDigest
        self.svcPatchManifest = svcPatchManifest
    }
}

nonisolated final class AppLaunchFingerprintStore: Sendable {
    static let shared = AppLaunchFingerprintStore(
        storeURL: PlayTools.playCoverContainer
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("launch-fingerprints.json")
    )

    private struct State: Sendable {
        var entries: [String: LaunchFastPathStamp]
        var loadedFromDisk: Bool
    }

    private let storeURL: URL
    private let state: Mutex<State>
    private let writeQueue = DispatchQueue(
        label: "app.makedie.MacOver.LaunchFingerprintStore",
        qos: .utility
    )

    init(storeURL: URL) {
        self.storeURL = storeURL
        self.state = Mutex(State(entries: [:], loadedFromDisk: false))
    }

    func matches(_ candidate: LaunchFastPathStamp, for bundlePath: String) -> Bool {
        ensureLoaded()
        return state.withLock { $0.entries[bundlePath] == candidate }
    }

    func record(_ stamp: LaunchFastPathStamp, for bundlePath: String) {
        ensureLoaded()
        let snapshot = state.withLock { current -> [String: LaunchFastPathStamp] in
            current.entries[bundlePath] = stamp
            return current.entries
        }
        persistAsync(snapshot)
    }

    func invalidate(for bundlePath: String) {
        ensureLoaded()
        let snapshot = state.withLock { current -> [String: LaunchFastPathStamp]? in
            guard current.entries.removeValue(forKey: bundlePath) != nil else { return nil }
            return current.entries
        }
        if let snapshot {
            persistAsync(snapshot)
        }
    }

    @discardableResult
    func flushSynchronously() -> Bool {
        ensureLoaded()
        let snapshot = state.withLock { $0.entries }
        return persistNow(snapshot)
    }

    private func ensureLoaded() {
        let alreadyLoaded = state.withLock { $0.loadedFromDisk }
        guard !alreadyLoaded else { return }

        let decoded: [String: LaunchFastPathStamp]
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode([String: LaunchFastPathStamp].self, from: data) {
            decoded = loaded.filter { $0.value.schemaVersion == LaunchFastPathStamp.currentSchemaVersion }
        } else {
            decoded = [:]
        }

        state.withLock { current in
            guard !current.loadedFromDisk else { return }
            current.entries.merge(decoded) { inMemory, _ in inMemory }
            current.loadedFromDisk = true
        }
    }

    private func persistAsync(_ entries: [String: LaunchFastPathStamp]) {
        writeQueue.async { [weak self] in
            _ = self?.persistNow(entries)
        }
    }

    @discardableResult
    private func persistNow(_ entries: [String: LaunchFastPathStamp]) -> Bool {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }
        return (try? data.write(to: storeURL, options: .atomic)) != nil
    }

    nonisolated struct Target: Sendable {
        let appURL: URL
        let executableURL: URL
        let appEntitlementsURL: URL
        let bundleID: String
    }

    static func currentStamp(
        target: Target,
        settings: AppSettingsData,
        usesPlayTools: Bool,
        isCatalyst: Bool
    ) -> LaunchFastPathStamp? {
        let infoPlistURL = target.appURL.appendingPathComponent("Info.plist")
        guard let execStamp = PlayTools.fileStamp(for: target.executableURL),
              let infoStamp = PlayTools.fileStamp(for: infoPlistURL),
              let playToolsStamp = PlayTools.fileStamp(for: PlayTools.playToolsPath) else {
            return nil
        }

        let codeResourcesURL = target.appURL.appendingPathComponent("_CodeSignature/CodeResources")
        let frameworksURL = target.appURL.appendingPathComponent("Frameworks")
        let plugInsURL = target.appURL.appendingPathComponent("PlugIns")
        let akExecURL = target.appURL.appendingPathComponent("PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface")
        let stagedBridgeDylibURL = frameworksURL
            .appendingPathComponent("UserPlugins/CoverUseBridge/CoverUseBridge.dylib")
        let builtInBridgeDylibStamp = PlayTools.builtInCoverUseBridgeDirectory()
            .flatMap { PlayTools.fileStamp(for: $0.appendingPathComponent("CoverUseBridge.dylib")) }

        let inputsHash = entitlementsInputsDigest(
            bundleID: target.bundleID,
            bundlePath: target.appURL.path,
            settings: settings,
            appEntitlementsURL: target.appEntitlementsURL
        )
        let userPluginsStoreDigest: String? = target.bundleID.isEmpty
            ? nil
            : PlayTools.directoryTreeDigest(at: PlayTools.userPluginsStoreURL(bundleIdentifier: target.bundleID))
        let bundledUserPluginsDigest = PlayTools.directoryTreeDigest(
            at: frameworksURL.appendingPathComponent("UserPlugins", isDirectory: true)
        )
        let svcPatchManifestStamp: PlayTools.FileStatStamp? = target.bundleID.isEmpty
            ? nil
            : PlayTools.fileStamp(for: BaseApp.svcPatchManifestURL(forBundleIdentifier: target.bundleID))

        return LaunchFastPathStamp(
            schemaVersion: LaunchFastPathStamp.currentSchemaVersion,
            exec: execStamp,
            infoPlist: infoStamp,
            codeResources: PlayTools.fileStamp(for: codeResourcesURL),
            frameworksDir: PlayTools.fileStamp(for: frameworksURL),
            plugInsDir: PlayTools.fileStamp(for: plugInsURL),
            akExec: PlayTools.fileStamp(for: akExecURL),
            playTools: playToolsStamp,
            usesPlayTools: usesPlayTools,
            isCatalyst: isCatalyst,
            strictEmulationMode: settings.strictEmulationMode,
            interceptInlineSyscalls: settings.effectiveInterceptInlineSyscalls,
            enableAutomationBridge: settings.enableAutomationBridge,
            coverUseBridge: builtInBridgeDylibStamp,
            coverUseBridgeStaged: FileManager.default.fileExists(atPath: stagedBridgeDylibURL.path),
            storedHasIntrospection: settings.storedHasIntrospection,
            storedHasIosFrameworks: settings.storedHasIosFrameworks,
            entitlementsInputsHash: inputsHash,
            userPluginsStoreDigest: userPluginsStoreDigest,
            bundledUserPluginsDigest: bundledUserPluginsDigest,
            svcPatchManifest: svcPatchManifestStamp
        )
    }

    static func entitlementsInputsDigest(
        bundleID: String,
        bundlePath: String,
        settings: AppSettingsData,
        appEntitlementsURL: URL
    ) -> String {
        var hasher = SHA256()
        func feed(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        func feedStamp(_ stamp: PlayTools.FileStatStamp?) {
            if let stamp {
                feed("\(stamp.inode):\(stamp.size):\(stamp.mtimeSec).\(stamp.mtimeNSec)")
            } else {
                feed("nil")
            }
        }

        feed("v2")
        feed(bundleID)
        feed(bundlePath)
        feed("effectiveBypass=\(settings.effectiveBypass)")
        feed("discordEnable=\(settings.discordActivity.enable)")
        if settings.discordActivity.enable {
            feed("tmpDir=\(FileManager.default.temporaryDirectory.path)")
        }
        feed("playSign=\(SystemConfig.isPlaySignActive)")
        feed(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
        feedStamp(PlayTools.fileStamp(for: appEntitlementsURL))

        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/PlayCover", isDirectory: true)
        feedStamp(PlayTools.fileStamp(for: configDir.appendingPathComponent("default.yaml")))
        feedStamp(Bundle.main.url(forResource: "default", withExtension: "yaml").flatMap(PlayTools.fileStamp))
        if !bundleID.isEmpty {
            feedStamp(PlayTools.fileStamp(for: configDir.appendingPathComponent("\(bundleID).yaml")))
            feedStamp(Bundle.main.url(forResource: bundleID, withExtension: "yaml").flatMap(PlayTools.fileStamp))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
