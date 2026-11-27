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
}

nonisolated private struct CachedAppIndexDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

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
