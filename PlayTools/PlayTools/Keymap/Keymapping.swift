//
//  Keymapping.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/08/29.
//

import Darwin
import Foundation

let keymap = Keymapping.shared

private struct CachedKeymapEntry {
    let dev: dev_t
    let ino: ino_t
    let mtimeSec: Int
    let mtimeNSec: Int
    let size: off_t
    let map: KeymappingData
}

final class Keymapping: @unchecked Sendable {
    static let shared = Keymapping()

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""

    private var keymapIdx: Int
    public var currentKeymap: KeymappingData {
        get {
            getKeymap(path: currentKeymapURL)
        }
        set {
            setKeymap(path: currentKeymapURL, map: newValue)
        }
    }

    private let lock = PTUnfairLock()
    private let baseKeymapURL: URL
    private let configURL: URL
    private var orderedKeymapURLs: [URL] = []
    private var keymapCache: [URL: CachedKeymapEntry] = [:]

    public var keymapConfig: KeymapConfig {
        get { lock.withLock { readConfigLocked() } }
        set { lock.withLock { writeConfigLocked(newValue) } }
    }

    private static let maxKeymapFileBytes = 4 * 1024 * 1024

    private func ensureBaseDirectoryIsNonSymlinkLocked() -> Bool {
        var dirSt = Darwin.stat()
        if Darwin.lstat(baseKeymapURL.path, &dirSt) != 0 {
            try? FileManager.default.createDirectory(
                atPath: baseKeymapURL.path,
                withIntermediateDirectories: true,
                attributes: [:]
            )
            guard Darwin.lstat(baseKeymapURL.path, &dirSt) == 0 else {
                return false
            }
        }
        return (dirSt.st_mode & S_IFMT) == S_IFDIR
    }

    private func rebasedKeymapURL(for rawURL: URL) -> URL? {
        let last = rawURL.lastPathComponent
        guard !last.isEmpty,
              last != ".",
              last != "..",
              !last.hasPrefix("."),
              !last.contains("/"),
              rawURL.pathExtension.lowercased() == "plist" else {
            return nil
        }
        return baseKeymapURL.appendingPathComponent(last)
    }

    private func readRegularFileNoFollowLocked(at url: URL) -> Data? {
        guard ensureBaseDirectoryIsNonSymlinkLocked() else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0,
              st.st_size <= off_t(Self.maxKeymapFileBytes) else {
            return nil
        }
        let byteCount = Int(st.st_size)
        guard byteCount > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: byteCount)
        var offset = 0
        while offset < byteCount {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), byteCount - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 {
                break
            }
            offset += n
        }
        return Data(buf.prefix(offset))
    }

    @discardableResult
    private func writeRegularFileNoFollowLocked(_ data: Data, to url: URL) -> Bool {
        guard ensureBaseDirectoryIsNonSymlinkLocked() else { return false }
        var existingSt = Darwin.stat()
        if Darwin.lstat(url.path, &existingSt) == 0,
           (existingSt.st_mode & S_IFMT) != S_IFREG {
            return false
        }
        let tmpName = ".\(url.lastPathComponent).tmp.\(Darwin.getpid()).\(UUID().uuidString)"
        let tmpURL = baseKeymapURL.appendingPathComponent(tmpName)
        let fd = Darwin.open(tmpURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        var writeOK = true
        var offset = 0
        let total = data.count
        while offset < total {
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), total - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                writeOK = false
                break
            }
            offset += n
        }
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
        guard writeOK else {
            _ = Darwin.unlink(tmpURL.path)
            return false
        }
        if Darwin.rename(tmpURL.path, url.path) != 0 {
            _ = Darwin.unlink(tmpURL.path)
            return false
        }
        return true
    }

    private func isRegularFileNoFollowLocked(at url: URL) -> Bool {
        var st = Darwin.stat()
        return Darwin.lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink > 0
    }

    private func readConfigLocked() -> KeymapConfig {
        guard let data = readRegularFileNoFollowLocked(at: configURL),
              let decoded = try? PropertyListDecoder().decode(KeymapConfig.self, from: data) else {
            return resetConfigLocked()
        }
        let defaultFallback = constructKeymapPath(name: "default")
        let safeDefault = rebasedKeymapURL(for: decoded.defaultKm) ?? defaultFallback
        var safeOrder: [URL] = []
        for entry in decoded.keymapOrder {
            if let rebased = rebasedKeymapURL(for: entry), !safeOrder.contains(rebased) {
                safeOrder.append(rebased)
            }
        }
        if safeOrder.isEmpty {
            safeOrder.append(safeDefault)
        }
        return KeymapConfig(defaultKm: safeDefault, keymapOrder: safeOrder)
    }

    private func writeConfigLocked(_ newValue: KeymapConfig) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        do {
            let data = try encoder.encode(newValue)
            _ = writeRegularFileNoFollowLocked(data, to: configURL)
        } catch {
            // Best-effort keymap config persistence without leaking host paths
        }
    }

    public var currentKeymapURL: URL {
        lock.withLock {
            let order = orderedKeymapURLs.isEmpty ? readConfigLocked().keymapOrder : orderedKeymapURLs
            guard keymapIdx >= 0 && keymapIdx < order.count else {
                return constructKeymapPath(name: "default")
            }
            return order[keymapIdx]
        }
    }

    public var currentKeymapName: String {
        currentKeymapURL.deletingPathExtension().lastPathComponent
    }

    init() {
        baseKeymapURL = URL(fileURLWithPath: PlaySettings.resolveHostUserRoot())
            .appendingPathComponent("Library/Containers/app.makedie.MacOver")
            .appendingPathComponent("Keymapping")
            .appendingPathComponent(bundleIdentifier)

        configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        keymapIdx = 0

        loadKeymapData()
    }

    private func constructKeymapPath(name: String) -> URL {
        baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
    }

    private func loadKeymapData() {
        lock.withLock {
            guard ensureBaseDirectoryIsNonSymlinkLocked() else { return }

            orderedKeymapURLs.removeAll()
            keymapCache.removeAll()

            let config = readConfigLocked()
            let defaultURL = constructKeymapPath(name: "default")
            for url in config.keymapOrder {
                guard let rebased = rebasedKeymapURL(for: url) else { continue }
                if rebased != defaultURL && !isRegularFileNoFollowLocked(at: rebased) {
                    continue
                }
                if !orderedKeymapURLs.contains(rebased) {
                    orderedKeymapURLs.append(rebased)
                }
                _ = getKeymapLocked(path: rebased)
            }

            let targetDefault = rebasedKeymapURL(for: config.defaultKm) ?? defaultURL
            if let defaultKmIdx = orderedKeymapURLs.firstIndex(of: targetDefault) {
                keymapIdx = defaultKmIdx
            } else if targetDefault == defaultURL || isRegularFileNoFollowLocked(at: targetDefault) {
                let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
                setKeymapLocked(path: targetDefault, map: fallback)
                keymapIdx = orderedKeymapURLs.firstIndex(of: targetDefault) ?? 0
            } else {
                if !orderedKeymapURLs.contains(defaultURL) {
                    let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
                    setKeymapLocked(path: defaultURL, map: fallback)
                }
                keymapIdx = orderedKeymapURLs.firstIndex(of: defaultURL) ?? 0
            }
        }
    }

    @discardableResult
    private func writeKeymap(_ map: KeymappingData, to path: URL) -> Bool {
        guard let rebased = rebasedKeymapURL(for: path) else { return false }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(map)
            return writeRegularFileNoFollowLocked(data, to: rebased)
        } catch {
            return false
        }
    }

    private static func makeCacheEntry(for path: URL, map: KeymappingData) -> CachedKeymapEntry? {
        var st = Darwin.stat()
        guard Darwin.lstat(path.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink > 0 else {
            return nil
        }
        return CachedKeymapEntry(
            dev: st.st_dev,
            ino: st.st_ino,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNSec: st.st_mtimespec.tv_nsec,
            size: st.st_size,
            map: map
        )
    }

    private func getKeymap(path: URL) -> KeymappingData {
        lock.withLock { getKeymapLocked(path: path) }
    }

    private func getKeymapLocked(path: URL) -> KeymappingData {
        guard let rebased = rebasedKeymapURL(for: path) else {
            return KeymappingData(bundleIdentifier: bundleIdentifier)
        }
        var st = Darwin.stat()
        let statOK = (Darwin.lstat(rebased.path, &st) == 0)
        if statOK && (st.st_mode & S_IFMT) != S_IFREG {
            keymapCache.removeValue(forKey: rebased)
            return KeymappingData(bundleIdentifier: bundleIdentifier)
        }
        let fileExists = statOK && st.st_nlink > 0
        if fileExists,
           let cached = keymapCache[rebased],
           cached.dev == st.st_dev,
           cached.ino == st.st_ino,
           cached.mtimeSec == st.st_mtimespec.tv_sec,
           cached.mtimeNSec == st.st_mtimespec.tv_nsec,
           cached.size == st.st_size {
            return cached.map
        }
        if !fileExists {
            keymapCache.removeValue(forKey: rebased)
            let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
            // Do not resurrect empty .plist files on ENOENT for non-default keymaps.
            if rebased == constructKeymapPath(name: "default") {
                _ = writeKeymap(fallback, to: rebased)
                keymapCache[rebased] = Self.makeCacheEntry(for: rebased, map: fallback)
            }
            return fallback
        }
        guard let data = readRegularFileNoFollowLocked(at: rebased) else {
            return KeymappingData(bundleIdentifier: bundleIdentifier)
        }
        do {
            let map = try PropertyListDecoder().decode(KeymappingData.self, from: data)
            keymapCache[rebased] = Self.makeCacheEntry(for: rebased, map: map)
            return map
        } catch {
            let backupURL = rebased.appendingPathExtension("bak")
            _ = writeRegularFileNoFollowLocked(data, to: backupURL)
            let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
            _ = writeKeymap(fallback, to: rebased)
            keymapCache[rebased] = Self.makeCacheEntry(for: rebased, map: fallback)
            return fallback
        }
    }

    private func setKeymap(path: URL, map: KeymappingData) {
        lock.withLock { setKeymapLocked(path: path, map: map) }
    }

    private func setKeymapLocked(path: URL, map: KeymappingData) {
        guard let rebased = rebasedKeymapURL(for: path),
              writeKeymap(map, to: rebased) else {
            return
        }
        keymapCache[rebased] = Self.makeCacheEntry(for: rebased, map: map)
        if !orderedKeymapURLs.contains(rebased) {
            orderedKeymapURLs.append(rebased)
            var config = readConfigLocked()
            if !config.keymapOrder.contains(rebased) {
                config.keymapOrder.append(rebased)
                writeConfigLocked(config)
            }
        }
    }

    private func pruneMissingNonDefaultLocked() {
        let defaultURL = constructKeymapPath(name: "default")
        orderedKeymapURLs.removeAll { url in
            url != defaultURL && !isRegularFileNoFollowLocked(at: url)
        }
        if orderedKeymapURLs.isEmpty {
            orderedKeymapURLs.append(defaultURL)
        }
        if keymapIdx < 0 || keymapIdx >= orderedKeymapURLs.count {
            keymapIdx = 0
        }
    }

    public func nextKeymap() {
        lock.withLock {
            pruneMissingNonDefaultLocked()
            guard !orderedKeymapURLs.isEmpty else { return }
            let count = orderedKeymapURLs.count
            let currentIdx = (keymapIdx >= 0 && keymapIdx < count) ? keymapIdx : 0
            keymapIdx = (currentIdx + 1) % count
        }
    }

    public func previousKeymap() {
        lock.withLock {
            pruneMissingNonDefaultLocked()
            guard !orderedKeymapURLs.isEmpty else { return }
            let count = orderedKeymapURLs.count
            let currentIdx = (keymapIdx >= 0 && keymapIdx < count) ? keymapIdx : 0
            keymapIdx = (currentIdx - 1 + count) % count
        }
    }

    @discardableResult
    public func resetKeymap(path: URL) -> KeymappingData {
        let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
        setKeymap(path: path, map: fallback)
        return fallback
    }

    @discardableResult
    private func resetConfigLocked() -> KeymapConfig {
        let defaultURL = constructKeymapPath(name: "default")
        let defaultConfig = KeymapConfig(defaultKm: defaultURL, keymapOrder: [defaultURL])
        writeConfigLocked(defaultConfig)
        return defaultConfig
    }

}

private struct SkipDecodableElement: Decodable {}

struct KeymappingData: Codable {
    var buttonModels: [Button] = []
    var draggableButtonModels: [Button] = []
    var joystickModel: [Joystick] = []
    var mouseAreaModel: [MouseArea] = []
    var bundleIdentifier: String
    var version = "2.0.0"

    init(
        buttonModels: [Button] = [],
        draggableButtonModels: [Button] = [],
        joystickModel: [Joystick] = [],
        mouseAreaModel: [MouseArea] = [],
        bundleIdentifier: String = "",
        version: String = "2.0.0"
    ) {
        self.buttonModels = buttonModels
        self.draggableButtonModels = draggableButtonModels
        self.joystickModel = joystickModel
        self.mouseAreaModel = mouseAreaModel
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    private static func decodeLossyArray<T: Decodable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> [T] {
        if let decoded = try? container.decodeIfPresent([T].self, forKey: key) {
            return decoded
        }
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }
        var items: [T] = []
        while !unkeyed.isAtEnd {
            if let item = try? unkeyed.decode(T.self) {
                items.append(item)
            } else {
                _ = try? unkeyed.decode(SkipDecodableElement.self)
            }
        }
        return items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttonModels = Self.decodeLossyArray(Button.self, from: container, forKey: .buttonModels)
        draggableButtonModels = Self.decodeLossyArray(Button.self, from: container, forKey: .draggableButtonModels)
        joystickModel = Self.decodeLossyArray(Joystick.self, from: container, forKey: .joystickModel)
        mouseAreaModel = Self.decodeLossyArray(MouseArea.self, from: container, forKey: .mouseAreaModel)
        bundleIdentifier = (try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? "2.0.0"
    }
}

struct KeymapConfig: Codable {
    var defaultKm: URL
    var keymapOrder: [URL]
}
