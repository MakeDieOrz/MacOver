//
//  Cacher.swift
//  PlayCover
//
//  Created by Amir Mohammadi on 10/2/1401 AP.
//

import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayCoverMachO
import Synchronization
import UniformTypeIdentifiers

nonisolated final class LocalDataCache: Sendable {
    static let shared = LocalDataCache(name: "PlayCoverCache")

    private let cacheDirectory: URL?
    private let writeLock = Mutex<Void>(())
    private let dirReady = Mutex<Bool>(false)
    private let cleanAllObservers = Mutex<[UUID: @Sendable () -> Void]>([:])

    @discardableResult
    func addCleanAllObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        cleanAllObservers.withLock { $0[id] = observer }
        return id
    }

    func removeCleanAllObserver(_ id: UUID) {
        cleanAllObservers.withLock { _ = $0.removeValue(forKey: id) }
    }

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

    private func ensureDirectoryIfNeeded() {
        let isReady = dirReady.withLock { $0 }
        guard !isReady, let cacheDirectory else { return }
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        dirReady.withLock { $0 = true }
    }

    func hasData(forKey key: String) -> Bool {
        guard let url = fileURL(forKey: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func write(data: Data, forKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        writeLock.withLock { _ in
            ensureDirectoryIfNeeded()
            try? data.write(to: url, options: .atomic)
        }
    }

    func readData(forKey key: String) -> Data? {
        guard let url = fileURL(forKey: key) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
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
        writeLock.withLock { _ in
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cleanAll() {
        if let cacheDirectory {
            writeLock.withLock { _ in
                try? FileManager.default.removeItem(at: cacheDirectory)
                dirReady.withLock { $0 = false }
            }
        }
        let observers = cleanAllObservers.withLock { Array($0.values) }
        for observer in observers {
            observer()
        }
    }
}

nonisolated final class Cacher: @unchecked Sendable {
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
    private let latestIconKeyByBaseKey = Mutex<[String: String]>([:])
    private let inFlightLocalIcons = Mutex<[String: Task<CGImage?, Never>]>([:])
    private var cleanAllObserverID: UUID?
    private let imageURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.iconCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    init() {
        cleanAllObserverID = cache.addCleanAllObserver { [weak self] in
            self?.clearMemoryCaches()
        }
    }

    deinit {
        if let cleanAllObserverID {
            cache.removeCleanAllObserver(cleanAllObserverID)
        }
    }

    private func clearMemoryCaches() {
        remoteImageMemoryCache.removeAllObjects()
        memoryIconCache.removeAllObjects()
        latestIconKeyByBaseKey.withLock { $0.removeAll() }
        URLCache.iconCache.removeAllCachedResponses()
    }

    func removeImageCache() {
        clearMemoryCaches()
        cache.cleanAll()
    }

    private static func baseIconKey(bundleIdentifier: String, bundleVersion: String) -> String {
        "\(bundleIdentifier)\u{1F}\(bundleVersion)"
    }

    private static func diskFreshnessKey(bundleIdentifier: String) -> String {
        "icon-freshness:\(bundleIdentifier)"
    }

    private static func diskIconDataKey(bundleIdentifier: String) -> String {
        "icon-data:\(bundleIdentifier)"
    }

    private static func fullIconKey(
        bundleIdentifier: String,
        bundleVersion: String,
        cfBundleVersion: String,
        installGeneration: String,
        infoPlistStamp: PlayTools.FileStatStamp?
    ) -> String {
        let stampPart: String
        if let stamp = infoPlistStamp {
            stampPart = "\(stamp.inode):\(stamp.size):\(stamp.mtimeSec).\(stamp.mtimeNSec)"
        } else {
            stampPart = ""
        }
        return [
            "v2",
            bundleIdentifier,
            bundleVersion,
            cfBundleVersion,
            installGeneration,
            stampPart
        ].joined(separator: "\u{1F}")
    }

    func invalidateLocalIcon(bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return }
        let prefix = bundleIdentifier + "\u{1F}"
        let evictedKeys = latestIconKeyByBaseKey.withLock { map -> [String] in
            let matchingBaseKeys = map.keys.filter { $0.hasPrefix(prefix) }
            var fullKeys: [String] = []
            for baseKey in matchingBaseKeys {
                if let full = map.removeValue(forKey: baseKey) {
                    fullKeys.append(full)
                }
            }
            return fullKeys
        }
        for key in evictedKeys {
            memoryIconCache.removeObject(forKey: key as NSString)
        }
        cache.clean(byKey: Self.diskFreshnessKey(bundleIdentifier: bundleIdentifier))
        cache.clean(byKey: Self.diskIconDataKey(bundleIdentifier: bundleIdentifier))
        cache.clean(byKey: bundleIdentifier)
    }

    @concurrent
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

    @concurrent
    func resolveITunesData(_ link: String) async {
        if let refreshedITunesData = await getITunesData(link) {
            try? cache.write(codable: refreshedITunesData, forKey: link)
        }
    }

    func getCachedMemoryIcon(
        bundleIdentifier: String,
        bundleVersion: String,
        cfBundleVersion: String = "",
        installGeneration: String = ""
    ) -> NSImage? {
        let baseKey = Self.baseIconKey(bundleIdentifier: bundleIdentifier, bundleVersion: bundleVersion)
        guard let latestFullKey = latestIconKeyByBaseKey.withLock({ $0[baseKey] }) else {
            return nil
        }
        if !cfBundleVersion.isEmpty || !installGeneration.isEmpty {
            let expectedPrefix = [
                "v2",
                bundleIdentifier,
                bundleVersion,
                cfBundleVersion,
                installGeneration
            ].joined(separator: "\u{1F}") + "\u{1F}"
            guard latestFullKey.hasPrefix(expectedPrefix) else {
                return nil
            }
        }
        return memoryIconCache.object(forKey: latestFullKey as NSString)
    }

    func resolveLocalIcon(_ app: PlayApp) -> NSImage? {
        resolveLocalIcon(
            at: app.url,
            bundleIdentifier: app.info.bundleIdentifier,
            bundleVersion: app.info.bundleVersion,
            primaryIconName: app.info.primaryIconName,
            cfBundleVersion: app.info[string: "CFBundleVersion"] ?? "",
            installGeneration: app.info[string: Installer.installGenerationInfoKey] ?? ""
        )
    }

    func resolveLocalIcon(
        at url: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        primaryIconName: String,
        cfBundleVersion: String = "",
        installGeneration: String = ""
    ) -> NSImage? {
        guard let cgImage = resolveLocalIconCGImage(
            at: url,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            primaryIconName: primaryIconName,
            cfBundleVersion: cfBundleVersion,
            installGeneration: installGeneration
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func loadLocalIcon(
        at url: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        primaryIconName: String,
        cfBundleVersion: String = "",
        installGeneration: String = ""
    ) async -> CGImage? {
        let infoPlistURL = url.appendingPathComponent("Info").appendingPathExtension("plist")
        let infoStamp = PlayTools.fileStamp(for: infoPlistURL)
        let fullKey = Self.fullIconKey(
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            cfBundleVersion: cfBundleVersion,
            installGeneration: installGeneration,
            infoPlistStamp: infoStamp
        )
        if let memImage = memoryIconCache.object(forKey: fullKey as NSString),
           let memCG = memImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return memCG
        }
        let task = inFlightLocalIcons.withLock { inflight -> Task<CGImage?, Never> in
            if let existing = inflight[fullKey] {
                return existing
            }
            let created = Task.detached(priority: .utility) { [weak self] () -> CGImage? in
                defer {
                    self?.inFlightLocalIcons.withLock { _ = $0.removeValue(forKey: fullKey) }
                }
                return self?.resolveLocalIconCGImage(
                    at: url,
                    bundleIdentifier: bundleIdentifier,
                    bundleVersion: bundleVersion,
                    primaryIconName: primaryIconName,
                    cfBundleVersion: cfBundleVersion,
                    installGeneration: installGeneration
                )
            }
            inflight[fullKey] = created
            return created
        }
        return await task.value
    }

    func resolveLocalIconData(
        at url: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        primaryIconName: String,
        cfBundleVersion: String = "",
        installGeneration: String = ""
    ) -> Data? {
        resolveLocalIcon(
            at: url,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            primaryIconName: primaryIconName,
            cfBundleVersion: cfBundleVersion,
            installGeneration: installGeneration
        )?.tiffRepresentation
    }

    static func downsampleCGImage(from data: Data, maxPixelSize: Int = 256) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var bestIndex = 0
        if count > 1 {
            var bestPixels = 0
            for idx in 0..<count {
                let dim = imagePixelMaxDimension(source: source, index: idx)
                if dim > bestPixels {
                    bestPixels = dim
                    bestIndex = idx
                }
            }
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, bestIndex, thumbOptions as CFDictionary)
    }

    private static func imagePixelMaxDimension(source: CGImageSource, index: Int) -> Int {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, opts) as? [CFString: Any] else {
            return 0
        }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(width, height)
    }

    private static func probeImageMaxDimension(at url: URL) -> Int {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts) else {
            return 0
        }
        let count = CGImageSourceGetCount(source)
        var best = 0
        for idx in 0..<count {
            best = max(best, imagePixelMaxDimension(source: source, index: idx))
        }
        return best
    }

    private static func encodePNG(from cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func resolveLocalIconCGImage(
        at url: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        primaryIconName: String,
        cfBundleVersion: String = "",
        installGeneration: String = ""
    ) -> CGImage? {
        let infoPlistURL = url.appendingPathComponent("Info").appendingPathExtension("plist")
        let infoStamp = PlayTools.fileStamp(for: infoPlistURL)
        let fullKey = Self.fullIconKey(
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            cfBundleVersion: cfBundleVersion,
            installGeneration: installGeneration,
            infoPlistStamp: infoStamp
        )
        let baseKey = Self.baseIconKey(bundleIdentifier: bundleIdentifier, bundleVersion: bundleVersion)
        let memKey = fullKey as NSString
        if let memImage = memoryIconCache.object(forKey: memKey),
           let memCG = memImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            latestIconKeyByBaseKey.withLock { $0[baseKey] = fullKey }
            return memCG
        }
        let freshnessKey = Self.diskFreshnessKey(bundleIdentifier: bundleIdentifier)
        let dataKey = Self.diskIconDataKey(bundleIdentifier: bundleIdentifier)
        if cache.readString(forKey: freshnessKey) == fullKey,
           let cachedData = cache.readData(forKey: dataKey),
           let diskCG = Self.downsampleCGImage(from: cachedData, maxPixelSize: 256) {
            let memImg = NSImage(cgImage: diskCG, size: NSSize(width: diskCG.width, height: diskCG.height))
            memoryIconCache.setObject(memImg, forKey: memKey)
            latestIconKeyByBaseKey.withLock { $0[baseKey] = fullKey }
            return diskCG
        }

        var bestFileURL: URL?
        var bestFileDim = 0
        if let topEntries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in topEntries where !primaryIconName.isEmpty && file.lastPathComponent.contains(primaryIconName) {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    let dim = Self.probeImageMaxDimension(at: file)
                    if dim > bestFileDim {
                        bestFileDim = dim
                        bestFileURL = file
                    }
                }
            }
        }

        var chosenCG: CGImage?
        if let bestFileURL, bestFileDim >= 128,
           let rawData = try? Data(contentsOf: bestFileURL, options: .mappedIfSafe) {
            chosenCG = Self.downsampleCGImage(from: rawData, maxPixelSize: 256)
        }

        if chosenCG == nil,
           let assetsExtractor = try? AssetsExtractor(appUrl: url),
           let assetCG = assetsExtractor.extractBestIconCGImage(matching: primaryIconName, maxPixelSize: 256) {
            let assetDim = max(assetCG.width, assetCG.height)
            if assetDim >= bestFileDim {
                chosenCG = assetCG
            }
        }

        if chosenCG == nil, let bestFileURL,
           let rawData = try? Data(contentsOf: bestFileURL, options: .mappedIfSafe) {
            chosenCG = Self.downsampleCGImage(from: rawData, maxPixelSize: 256)
        }

        if chosenCG == nil {
            let bestDeep = Mutex<(url: URL?, dim: Int)>((nil, 0))
            url.enumerateContents(blocking: true) { file, _ in
                guard !primaryIconName.isEmpty && file.lastPathComponent.contains(primaryIconName) else {
                    return
                }
                let dim = Self.probeImageMaxDimension(at: file)
                guard dim > 0 else { return }
                bestDeep.withLock { current in
                    if dim > current.dim {
                        current = (file, dim)
                    }
                }
            }
            if let deepURL = bestDeep.withLock({ $0.url }),
               let rawData = try? Data(contentsOf: deepURL, options: .mappedIfSafe) {
                chosenCG = Self.downsampleCGImage(from: rawData, maxPixelSize: 256)
            }
        }

        if let chosenCG {
            let memImg = NSImage(cgImage: chosenCG, size: NSSize(width: chosenCG.width, height: chosenCG.height))
            memoryIconCache.setObject(memImg, forKey: memKey)
            latestIconKeyByBaseKey.withLock { $0[baseKey] = fullKey }
            if let pngData = Self.encodePNG(from: chosenCG) {
                cache.write(data: pngData, forKey: dataKey)
                cache.write(string: fullKey, forKey: freshnessKey)
            }
            return chosenCG
        }
        invalidateLocalIcon(bundleIdentifier: bundleIdentifier)
        return nil
    }

    @MainActor
    func getLocalIcon(bundleId: String) -> NSImage? {
        if let app = appsVM?.apps.first(where: { $0.info.bundleIdentifier == bundleId }) {
            if let memImage = getCachedMemoryIcon(
                bundleIdentifier: app.info.bundleIdentifier,
                bundleVersion: app.info.bundleVersion
            ) {
                return memImage
            }
            return cache.readImage(forKey: Self.diskIconDataKey(bundleIdentifier: app.info.bundleIdentifier))
                ?? cache.readImage(forKey: app.info.bundleIdentifier)
        } else {
            return nil
        }
    }

}

nonisolated extension URLCache {
    static let iconCache = URLCache(memoryCapacity: 4*1024*1024, diskCapacity: 20*1024*1024) // 4MB and 20MB
}
