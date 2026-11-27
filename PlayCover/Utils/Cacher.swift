//
//  Cacher.swift
//  PlayCover
//
//  Created by Amir Mohammadi on 10/2/1401 AP.
//

import AppKit
import CryptoKit
import Foundation
import Synchronization

final class LocalDataCache: Sendable {
    static let shared = LocalDataCache(name: "PlayCoverCache")

    private let cacheDirectory: URL?
    private let ioLock = Mutex<Void>(())

    init(name: String, cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent(name, isDirectory: true)
        }
    }

    private func fileURL(forKey key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hex, isDirectory: false)
    }

    private func ensureDirectoryLocked() {
        guard let cacheDirectory else { return }
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    func hasData(forKey key: String) -> Bool {
        guard let url = fileURL(forKey: key) else { return false }
        return ioLock.withLock { _ in
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    func write(data: Data, forKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        ioLock.withLock { _ in
            ensureDirectoryLocked()
            try? data.write(to: url, options: .atomic)
        }
    }

    func readData(forKey key: String) -> Data? {
        guard let url = fileURL(forKey: key) else { return nil }
        return ioLock.withLock { _ in
            try? Data(contentsOf: url)
        }
    }

    func write(string: String, forKey key: String) {
        write(data: Data(string.utf8), forKey: key)
    }

    func readString(forKey key: String) -> String? {
        readData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func write(image: NSImage, forKey key: String) {
        guard let tiffData = image.tiffRepresentation else { return }
        let encoded = NSBitmapImageRep(data: tiffData)?.representation(using: .png, properties: [:]) ?? tiffData
        write(data: encoded, forKey: key)
    }

    func readImage(forKey key: String) -> NSImage? {
        readData(forKey: key).flatMap(NSImage.init(data:))
    }

    func write<T: Encodable>(codable: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(codable)
        write(data: data, forKey: key)
    }

    func readCodable<T: Decodable>(forKey key: String) throws -> T? {
        guard let data = readData(forKey: key) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func clean(byKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        ioLock.withLock { _ in
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cleanAll() {
        guard let cacheDirectory else { return }
        ioLock.withLock { _ in
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }
}

final class Cacher: @unchecked Sendable {
    weak var appsVM: AppsVM?
    let cache = LocalDataCache.shared
    private let remoteImageMemoryCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 4 * 1024 * 1024
        return c
    }()
    private let memoryIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    private lazy var imageURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.iconCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func removeImageCache() {
        remoteImageMemoryCache.removeAllObjects()
        memoryIconCache.removeAllObjects()
        URLCache.iconCache.removeAllCachedResponses()
    }

    func loadRemoteImage(from urlString: String) async -> NSImage? {
        let cacheKey = urlString as NSString
        if let memoryImage = remoteImageMemoryCache.object(forKey: cacheKey) {
            return memoryImage
        }
        let diskKey = "remote-image:\(urlString)"
        if let diskImage = cache.readImage(forKey: diskKey) {
            remoteImageMemoryCache.setObject(diskImage, forKey: cacheKey)
            return diskImage
        }
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await imageURLSession.data(from: url)
            guard let image = NSImage(data: data) else { return nil }
            remoteImageMemoryCache.setObject(image, forKey: cacheKey, cost: data.count)
            cache.write(data: data, forKey: diskKey)
            return image
        } catch {
            return nil
        }
    }

    func resolveITunesData(_ link: String) async {
        if let refreshedITunesData = await getITunesData(link) {
            try? cache.write(codable: refreshedITunesData, forKey: link)
        }
    }

    func getCachedMemoryIcon(bundleIdentifier: String, bundleVersion: String) -> NSImage? {
        memoryIconCache.object(forKey: (bundleIdentifier + bundleVersion) as NSString)
    }

    func resolveLocalIcon(_ app: PlayApp) -> NSImage? {
        resolveLocalIcon(
            at: app.url,
            bundleIdentifier: app.info.bundleIdentifier,
            bundleVersion: app.info.bundleVersion,
            primaryIconName: app.info.primaryIconName
        )
    }

    func resolveLocalIcon(
        at url: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        primaryIconName: String
    ) -> NSImage? {
        let compareStr = bundleIdentifier + bundleVersion
        let memKey = compareStr as NSString
        if let memImage = memoryIconCache.object(forKey: memKey) {
            return memImage
        }
        if cache.readString(forKey: compareStr) != nil,
           let cachedImage = cache.readImage(forKey: bundleIdentifier) {
            memoryIconCache.setObject(cachedImage, forKey: memKey)
            return cachedImage
        }

        var candidates: [NSImage] = []
        if let topEntries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in topEntries where file.lastPathComponent.contains(primaryIconName) {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                   let icon = NSImage(contentsOf: file) {
                    candidates.append(icon)
                }
            }
        }

        if let assetsExtractor = try? AssetsExtractor(appUrl: url) {
            candidates.append(contentsOf: assetsExtractor.extractIcons())
        }

        if candidates.isEmpty {
            let collected = Mutex<[NSImage]>([])
            url.enumerateContents(blocking: true) { file, _ in
                guard file.lastPathComponent.contains(primaryIconName), let icon = NSImage(contentsOf: file) else {
                    return
                }
                collected.withLock { $0.append(icon) }
            }
            candidates.append(contentsOf: collected.withLock { $0 })
        }

        let bestResImage = candidates.max { $0.size.height < $1.size.height }
        cache.write(string: compareStr, forKey: compareStr)
        if let image = bestResImage {
            memoryIconCache.setObject(image, forKey: memKey)
            cache.write(image: image, forKey: bundleIdentifier)
            return image
        }
        return nil
    }

    func resolveLocalIconData(
        at url: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        primaryIconName: String
    ) -> Data? {
        resolveLocalIcon(
            at: url,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            primaryIconName: primaryIconName
        )?.tiffRepresentation
    }

    func getLocalIcon(bundleId: String) -> NSImage? {
        if let app = appsVM?.apps.first(where: { $0.info.bundleIdentifier == bundleId }) {
            let key = (app.info.bundleIdentifier + app.info.bundleVersion) as NSString
            if let memImage = memoryIconCache.object(forKey: key) {
                return memImage
            }
            return cache.readImage(forKey: app.info.bundleIdentifier)
        } else {
            return nil
        }
    }

}

extension URLCache {
    static let iconCache = URLCache(memoryCapacity: 4*1024*1024, diskCapacity: 20*1024*1024) // 4MB and 20MB
}
