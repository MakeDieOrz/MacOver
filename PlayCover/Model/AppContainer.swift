//
//  AppContainer.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 07.12.2021.
//

import Darwin
import Foundation

// swiftlint:disable:next type_body_length
struct AppContainer {

    static let containersURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Containers")

    private static let identityXattrName = "com.apple.containermanager.identity"

    let bundleId: String
    var containerUrl: URL {
        AppContainer.resolveContainerURL(for: bundleId)
    }

    var userPrefsUrl: URL {
        containerUrl.appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Preferences")
            .appendingEscapedPathComponent(bundleId)
            .appendingPathExtension("plist")
    }

    init(bundleId: String) {
        self.bundleId = bundleId
    }

    public func clear() async {
        await Uninstaller.clearExternalCache(bundleId)
    }

    static func scanDeclaredExtensionBundleIds(
        in appBundleURL: URL,
        parentBundleId: String
    ) -> (ids: Set<String>, complete: Bool) {
        guard !parentBundleId.isEmpty else { return ([], true) }
        let fm = FileManager.default
        let subdirs = ["PlugIns", "Extensions", "Contents/PlugIns", "Contents/Extensions"]
        var extIds: Set<String> = []
        var complete = true
        let requiredPrefix = parentBundleId + "."

        for subdir in subdirs {
            let dir = appBundleURL.appendingPathComponent(subdir, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue,
                  let items = try? fm.contentsOfDirectory(
                      at: dir,
                      includingPropertiesForKeys: nil,
                      options: [.skipsHiddenFiles]
                  ) else {
                complete = false
                continue
            }
            for item in items where item.pathExtension == "appex" {
                let infoCandidates = [
                    item.appendingPathComponent("Info.plist"),
                    item.appendingPathComponent("Contents/Info.plist")
                ]
                var parsedId: String?
                for infoURL in infoCandidates where fm.fileExists(atPath: infoURL.path) {
                    if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
                       let extId = dict["CFBundleIdentifier"] as? String,
                       !extId.isEmpty {
                        parsedId = extId
                        break
                    }
                }
                if let extId = parsedId {
                    if extId.hasPrefix(requiredPrefix) {
                        extIds.insert(extId)
                    }
                } else {
                    complete = false
                }
            }
        }
        return (extIds, complete)
    }

    static func declaredExtensionBundleIds(in appBundleURL: URL, parentBundleId: String) -> Set<String> {
        scanDeclaredExtensionBundleIds(in: appBundleURL, parentBundleId: parentBundleId).ids
    }

    static func scanInstalledAppBundles() -> (bundles: [String: URL], complete: Bool) {
        let fm = FileManager.default
        let appsDir = PlayTools.playCoverContainer.appendingPathComponent("Applications", isDirectory: true)
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: appsDir.path, isDirectory: &isDir) {
            return ([:], true)
        }
        guard isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(
                  at: appsDir,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return ([:], false)
        }
        var map: [String: URL] = [:]
        var complete = true
        for entry in entries where entry.hasDirectoryPath && entry.pathExtension.contains("app") {
            let infoCandidates = [
                entry.appendingPathComponent("Info.plist"),
                entry.appendingPathComponent("Contents/Info.plist")
            ]
            var foundBid: String?
            for infoURL in infoCandidates where fm.fileExists(atPath: infoURL.path) {
                if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
                   let bid = dict["CFBundleIdentifier"] as? String,
                   !bid.isEmpty {
                    foundBid = bid
                    break
                }
            }
            if let bid = foundBid {
                map[bid] = entry
            } else {
                complete = false
            }
        }
        return (map, complete)
    }

    static func scanActiveIdentifiers() -> (ids: Set<String>, complete: Bool) {
        let scan = scanInstalledAppBundles()
        guard scan.complete else {
            return ([], false)
        }
        var allIds = Set(scan.bundles.keys)
        var complete = true
        for (bid, bundleURL) in scan.bundles {
            let extScan = scanDeclaredExtensionBundleIds(in: bundleURL, parentBundleId: bid)
            allIds.formUnion(extScan.ids)
            if !extScan.complete {
                complete = false
            }
        }
        return (allIds, complete)
    }

    static func installedAppBundles() -> [String: URL] {
        scanInstalledAppBundles().bundles
    }

    static func targetContainerIdentifiers(for bundleId: String, appBundleURL: URL? = nil) -> Set<String> {
        guard !bundleId.isEmpty else { return [] }
        let scan = scanInstalledAppBundles()
        let otherAppIds = Set(scan.bundles.keys).subtracting([bundleId])
        var ids: Set<String> = [bundleId]
        if scan.complete, let bundleURL = appBundleURL ?? scan.bundles[bundleId] {
            let extIds = declaredExtensionBundleIds(in: bundleURL, parentBundleId: bundleId)
                .subtracting(otherAppIds)
            ids.formUnion(extIds)
        }
        return ids
    }

    public func doesExist() -> Bool {
        FileManager.default.fileExists(atPath: containerUrl.path)
    }

    static func containerIdentity(at url: URL) -> String? {
        let path = url.path
        var stackBuf = [UInt8](repeating: 0, count: 4096)
        let readLen = stackBuf.withUnsafeMutableBytes { rawBuf -> ssize_t in
            guard let base = rawBuf.baseAddress else { return -1 }
            return getxattr(path, identityXattrName, base, rawBuf.count, 0, XATTR_NOFOLLOW)
        }
        let text: String?
        if readLen > 0 {
            text = String(bytes: stackBuf.prefix(readLen), encoding: .utf8)
        } else if readLen < 0 && errno == ERANGE {
            let needed = getxattr(path, identityXattrName, nil, 0, 0, XATTR_NOFOLLOW)
            guard needed > 0 else { return nil }
            var dynBuf = [UInt8](repeating: 0, count: needed)
            let actual = dynBuf.withUnsafeMutableBytes { rawBuf -> ssize_t in
                guard let base = rawBuf.baseAddress else { return -1 }
                return getxattr(path, identityXattrName, base, rawBuf.count, 0, XATTR_NOFOLLOW)
            }
            text = actual > 0 ? String(bytes: dynBuf.prefix(actual), encoding: .utf8) : nil
        } else {
            return nil
        }

        guard let content = text else { return nil }
        for line in content.split(whereSeparator: \.isNewline) where line.hasPrefix("identifier:") {
            let value = line.dropFirst("identifier:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func resolveContainerURL(for bundleId: String) -> URL {
        let directURL = containersURL.appendingEscapedPathComponent(bundleId)
        guard !bundleId.isEmpty else { return directURL }
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: containersURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directURL
        }

        var bestURL: URL?
        var bestDate: Date = .distantPast
        for entry in entries where containerIdentity(at: entry) == bundleId {
            let modDate = (try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if bestURL == nil || modDate >= bestDate {
                bestURL = entry
                bestDate = modDate
            }
        }
        return bestURL ?? directURL
    }

    static func allMatchingContainerURLs(for bundleId: String,
                                         appBundleURL: URL? = nil) -> [(url: URL, identifier: String)] {
        let allowedIds = targetContainerIdentifiers(for: bundleId, appBundleURL: appBundleURL)
        guard !allowedIds.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: containersURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [(url: URL, identifier: String)] = []
        for entry in entries {
            if let ident = containerIdentity(at: entry) {
                if allowedIds.contains(ident) {
                    results.append((entry, ident))
                }
            } else {
                let dirName = entry.lastPathComponent
                if allowedIds.contains(dirName) {
                    results.append((entry, dirName))
                }
            }
        }
        return results
    }
}
