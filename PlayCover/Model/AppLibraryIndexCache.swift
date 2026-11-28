//
//  AppLibraryIndexCache.swift
//  PlayCover
//

import Foundation
import PlayCoverMachO

nonisolated struct CachedAppIndexEntry: Codable, Equatable, Sendable {
    let urlPath: String
    let bundleIdentifier: String
    let bundleName: String
    let displayName: String
    let bundleVersion: String
    let cfBundleVersion: String
    let executableName: String
    let installGeneration: String
    let primaryIconName: String
    let hasPlayTools: Bool
    let strictEmulationMode: Bool
    let effectiveIOSDeviceModel: String
    let pixelBudgetRatio: Double
    let infoPlistMTimeSec: Int
    let settingsPlistMTimeSec: Int
    let execMTimeSec: Int
    let execInode: UInt64
    let execSize: Int64
    let infoPlistStamp: PlayTools.FileStatStamp?
    let settingsPlistStamp: PlayTools.FileStatStamp?
    let execStamp: PlayTools.FileStatStamp?

    init(
        urlPath: String,
        bundleIdentifier: String,
        bundleName: String,
        displayName: String,
        bundleVersion: String,
        cfBundleVersion: String,
        executableName: String,
        installGeneration: String,
        primaryIconName: String,
        hasPlayTools: Bool,
        strictEmulationMode: Bool,
        effectiveIOSDeviceModel: String,
        pixelBudgetRatio: Double,
        infoPlistMTimeSec: Int,
        settingsPlistMTimeSec: Int,
        execMTimeSec: Int,
        execInode: UInt64,
        execSize: Int64,
        infoPlistStamp: PlayTools.FileStatStamp? = nil,
        settingsPlistStamp: PlayTools.FileStatStamp? = nil,
        execStamp: PlayTools.FileStatStamp? = nil
    ) {
        self.urlPath = urlPath
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.displayName = displayName
        self.bundleVersion = bundleVersion
        self.cfBundleVersion = cfBundleVersion
        self.executableName = executableName
        self.installGeneration = installGeneration
        self.primaryIconName = primaryIconName
        self.hasPlayTools = hasPlayTools
        self.strictEmulationMode = strictEmulationMode
        self.effectiveIOSDeviceModel = effectiveIOSDeviceModel
        self.pixelBudgetRatio = pixelBudgetRatio
        self.infoPlistMTimeSec = infoPlistMTimeSec
        self.settingsPlistMTimeSec = settingsPlistMTimeSec
        self.execMTimeSec = execMTimeSec
        self.execInode = execInode
        self.execSize = execSize
        self.infoPlistStamp = infoPlistStamp
        self.settingsPlistStamp = settingsPlistStamp
        self.execStamp = execStamp
    }
}

nonisolated private struct CachedAppIndexDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let entries: [CachedAppIndexEntry]
}

nonisolated enum AppLibraryIndexCache {
    static var defaultCacheURL: URL {
        PlayTools.playCoverContainer
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("app-library-index.json")
    }

    static func load(from url: URL = defaultCacheURL) -> [CachedAppIndexEntry] {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(CachedAppIndexDocument.self, from: data),
              doc.schemaVersion == CachedAppIndexDocument.currentSchemaVersion else {
            return []
        }
        return doc.entries
    }

    @discardableResult
    static func save(_ entries: [CachedAppIndexEntry], to url: URL = defaultCacheURL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc = CachedAppIndexDocument(
            schemaVersion: CachedAppIndexDocument.currentSchemaVersion,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(doc) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
