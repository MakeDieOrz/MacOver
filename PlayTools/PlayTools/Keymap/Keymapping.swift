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

class Keymapping {
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

    private let lock = NSLock()
    private let baseKeymapURL: URL
    private let configURL: URL
    private var orderedKeymapURLs: [URL] = []
    private var keymapCache: [URL: CachedKeymapEntry] = [:]

    public var keymapConfig: KeymapConfig {
        get {
            lock.lock()
            defer { lock.unlock() }
            return readConfigLocked()
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            writeConfigLocked(newValue)
        }
    }

    private func readConfigLocked() -> KeymapConfig {
        do {
            let data = try Data(contentsOf: configURL)
            return try PropertyListDecoder().decode(KeymapConfig.self, from: data)
        } catch {
            return resetConfigLocked()
        }
    }

    private func writeConfigLocked(_ newValue: KeymapConfig) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        do {
            let data = try encoder.encode(newValue)
            try data.write(to: configURL, options: .atomic)
        } catch {
            // Best-effort keymap config persistence without leaking host paths
        }
    }

    public var currentKeymapURL: URL {
        lock.lock()
        defer { lock.unlock() }
        let order = orderedKeymapURLs.isEmpty ? readConfigLocked().keymapOrder : orderedKeymapURLs
        guard keymapIdx >= 0 && keymapIdx < order.count else {
            return constructKeymapPath(name: "default")
        }
        return order[keymapIdx]
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
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: baseKeymapURL.path) {
            try? FileManager.default.createDirectory(
                atPath: baseKeymapURL.path,
                withIntermediateDirectories: true,
                attributes: [:])
        }

        orderedKeymapURLs.removeAll()
        keymapCache.removeAll()

        let config = readConfigLocked()
        for url in config.keymapOrder {
            if !orderedKeymapURLs.contains(url) {
                orderedKeymapURLs.append(url)
            }
            _ = getKeymapLocked(path: url)
        }

        if let defaultKmIdx = orderedKeymapURLs.firstIndex(of: config.defaultKm) {
            keymapIdx = defaultKmIdx
        } else {
            let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
            setKeymapLocked(path: config.defaultKm, map: fallback)
            keymapIdx = orderedKeymapURLs.firstIndex(of: config.defaultKm) ?? 0
        }
    }

    @discardableResult
    private func writeKeymap(_ map: KeymappingData, to path: URL) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(map)
            try data.write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func makeCacheEntry(for path: URL, map: KeymappingData) -> CachedKeymapEntry? {
        var st = Darwin.stat()
        guard stat(path.path, &st) == 0, st.st_nlink > 0 else {
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
        lock.lock()
        defer { lock.unlock() }
        return getKeymapLocked(path: path)
    }

    private func getKeymapLocked(path: URL) -> KeymappingData {
        var st = Darwin.stat()
        let fileExists = (stat(path.path, &st) == 0 && st.st_nlink > 0)
        if fileExists,
           let cached = keymapCache[path],
           cached.dev == st.st_dev,
           cached.ino == st.st_ino,
           cached.mtimeSec == st.st_mtimespec.tv_sec,
           cached.mtimeNSec == st.st_mtimespec.tv_nsec,
           cached.size == st.st_size {
            return cached.map
        }
        do {
            let data = try Data(contentsOf: path)
            let map = try PropertyListDecoder().decode(KeymappingData.self, from: data)
            keymapCache[path] = Self.makeCacheEntry(for: path, map: map)
            return map
        } catch {
            if fileExists {
                let backupURL = path.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: path, to: backupURL)
            }
            let fallback = KeymappingData(bundleIdentifier: bundleIdentifier)
            _ = writeKeymap(fallback, to: path)
            keymapCache[path] = Self.makeCacheEntry(for: path, map: fallback)
            return fallback
        }
    }

    private func setKeymap(path: URL, map: KeymappingData) {
        lock.lock()
        defer { lock.unlock() }
        setKeymapLocked(path: path, map: map)
    }

    private func setKeymapLocked(path: URL, map: KeymappingData) {
        guard writeKeymap(map, to: path) else {
            return
        }
        keymapCache[path] = Self.makeCacheEntry(for: path, map: map)
        if !orderedKeymapURLs.contains(path) {
            orderedKeymapURLs.append(path)
            var config = readConfigLocked()
            if !config.keymapOrder.contains(path) {
                config.keymapOrder.append(path)
                writeConfigLocked(config)
            }
        }
    }

    public func nextKeymap() {
        lock.lock()
        defer { lock.unlock() }
        guard !orderedKeymapURLs.isEmpty else { return }
        let count = orderedKeymapURLs.count
        let currentIdx = (keymapIdx >= 0 && keymapIdx < count) ? keymapIdx : 0
        keymapIdx = (currentIdx + 1) % count
    }

    public func previousKeymap() {
        lock.lock()
        defer { lock.unlock() }
        guard !orderedKeymapURLs.isEmpty else { return }
        let count = orderedKeymapURLs.count
        let currentIdx = (keymapIdx >= 0 && keymapIdx < count) ? keymapIdx : 0
        keymapIdx = (currentIdx - 1 + count) % count
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
