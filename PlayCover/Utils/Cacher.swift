//
//  Cacher.swift
//  PlayCover
//
//  Created by Amir Mohammadi on 10/2/1401 AP.
//

import Foundation
import AppKit
import DataCache
import CachedAsyncImage

class Cacher {
    weak var appsVM: AppsVM?
    @ImageCache private var imageCache
    let cache = DataCache.instance
    private let memoryIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    init() {
        // Set image cache limit.
        ImageCache().wrappedValue.setCacheLimit(
            countLimit: 400,
            totalCostLimit: 4*1024*1024
        )
    }

    func removeImageCache() {
        imageCache.removeCache()
        memoryIconCache.removeAllObjects()
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
            let lock = NSLock()
            url.enumerateContents(blocking: true) { file, _ in
                guard file.lastPathComponent.contains(primaryIconName), let icon = NSImage(contentsOf: file) else {
                    return
                }
                lock.lock()
                candidates.append(icon)
                lock.unlock()
            }
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
