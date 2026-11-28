//
//  AppInfo.swift
//  PlayCover
//

import Foundation
import Synchronization

public class AppInfo: @unchecked Sendable {
    public struct CachedFields: Sendable {
        public let bundleIdentifier: String
        public let bundleName: String
        public let displayName: String
        public let bundleVersion: String
        public let cfBundleVersion: String
        public let executableName: String
        public let installGeneration: String
        public let primaryIconName: String

        public init(
            bundleIdentifier: String,
            bundleName: String,
            displayName: String,
            bundleVersion: String,
            cfBundleVersion: String,
            executableName: String,
            installGeneration: String,
            primaryIconName: String
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.bundleName = bundleName
            self.displayName = displayName
            self.bundleVersion = bundleVersion
            self.cfBundleVersion = cfBundleVersion
            self.executableName = executableName
            self.installGeneration = installGeneration
            self.primaryIconName = primaryIconName
        }
    }

    private final class StorageState: @unchecked Sendable {
        var rawStorage: NSMutableDictionary
        var wasBinaryPlist: Bool
        var isHydrated: Bool
        var cachedPrimaryIconName: String?

        init(
            rawStorage: NSMutableDictionary,
            wasBinaryPlist: Bool,
            isHydrated: Bool,
            cachedPrimaryIconName: String?
        ) {
            self.rawStorage = rawStorage
            self.wasBinaryPlist = wasBinaryPlist
            self.isHydrated = isHydrated
            self.cachedPrimaryIconName = cachedPrimaryIconName
        }
    }

    public let url: URL
    private let stateLock: Mutex<StorageState>
    private let unhydratedStringKeys: Set<String>

    public init(contentsOf url: URL) {
        self.unhydratedStringKeys = []
        do {
            let data = try Data(contentsOf: url)
            var format: PropertyListSerialization.PropertyListFormat = .xml
            let parsed = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format
            )
            if let dict = parsed as? NSMutableDictionary {
                self.url = url
                self.stateLock = Mutex(StorageState(
                    rawStorage: dict,
                    wasBinaryPlist: format == .binary,
                    isHydrated: true,
                    cachedPrimaryIconName: nil
                ))
            } else {
                self.url = URL(fileURLWithPath: "")
                self.stateLock = Mutex(StorageState(
                    rawStorage: NSMutableDictionary(),
                    wasBinaryPlist: false,
                    isHydrated: true,
                    cachedPrimaryIconName: nil
                ))
            }
        } catch {
            PlayCoverDiagnostics.reportError(error)
            self.url = URL(fileURLWithPath: "")
            self.stateLock = Mutex(StorageState(
                rawStorage: NSMutableDictionary(),
                wasBinaryPlist: false,
                isHydrated: true,
                cachedPrimaryIconName: nil
            ))
        }
    }

    public init(
        cachedPlistURL url: URL,
        cachedFields: CachedFields,
        installGenerationKey: String = "PCInstallGeneration"
    ) {
        let storage = NSMutableDictionary()
        storage["CFBundleIdentifier"] = cachedFields.bundleIdentifier
        storage["CFBundleName"] = cachedFields.bundleName
        storage["CFBundleDisplayName"] = cachedFields.displayName
        storage["CFBundleShortVersionString"] = cachedFields.bundleVersion
        storage["CFBundleVersion"] = cachedFields.cfBundleVersion
        storage["CFBundleExecutable"] = cachedFields.executableName
        storage[installGenerationKey] = cachedFields.installGeneration
        self.url = url
        self.stateLock = Mutex(StorageState(
            rawStorage: storage,
            wasBinaryPlist: false,
            isHydrated: false,
            cachedPrimaryIconName: cachedFields.primaryIconName
        ))
        self.unhydratedStringKeys = [
            "CFBundleIdentifier",
            "CFBundleName",
            "CFBundleDisplayName",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "CFBundleExecutable",
            installGenerationKey
        ]
    }

    private init(url: URL, rawStorage: NSMutableDictionary, wasBinaryPlist: Bool = false) {
        self.url = url
        self.stateLock = Mutex(StorageState(
            rawStorage: rawStorage,
            wasBinaryPlist: wasBinaryPlist,
            isHydrated: true,
            cachedPrimaryIconName: nil
        ))
        self.unhydratedStringKeys = []
    }

    private func hydrateLocked(_ state: StorageState) {
        guard !state.isHydrated else { return }
        defer { state.isHydrated = true }
        state.cachedPrimaryIconName = nil
        guard !url.path.isEmpty else { return }
        do {
            let data = try Data(contentsOf: url)
            var format: PropertyListSerialization.PropertyListFormat = .xml
            let parsed = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format
            )
            if let dict = parsed as? NSMutableDictionary {
                state.wasBinaryPlist = (format == .binary)
                state.rawStorage = dict
            }
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    public func retargeted(toURL url: URL) -> AppInfo {
        let (copy, wasBinary) = stateLock.withLock { state -> (NSMutableDictionary, Bool) in
            hydrateLocked(state)
            guard let cloned = state.rawStorage.mutableCopy() as? NSMutableDictionary else {
                fatalError("Failed to copy rawStorage")
            }
            return (cloned, state.wasBinaryPlist)
        }
        return AppInfo(url: url, rawStorage: copy, wasBinaryPlist: wasBinary)
    }

    /// Write a serialized representation of this info to the given URL, preserving binary format if originally binary
    public func write(toURL url: URL) throws {
        let data = try stateLock.withLock { state -> Data in
            hydrateLocked(state)
            let format: PropertyListSerialization.PropertyListFormat = state.wasBinaryPlist ? .binary : .xml
            return try PropertyListSerialization.data(
                fromPropertyList: state.rawStorage,
                format: format,
                options: 0
            )
        }
        try data.write(to: url, options: .atomic)
    }

    /// Overwrites the file this AppInfo was loaded from
    public func write() throws {
        try write(toURL: url)
    }

    public subscript(string index: String) -> String? {
        get {
            stateLock.withLock { state in
                if !unhydratedStringKeys.contains(index) {
                    hydrateLocked(state)
                }
                return state.rawStorage[index] as? String
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public subscript(object index: String) -> NSObject? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                let raw = state.rawStorage[index] as? NSObject
                return (raw as? NSCopying)?.copy(with: nil) as? NSObject ?? raw
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public subscript(dictionary index: String) -> NSMutableDictionary? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return (state.rawStorage[index] as? NSMutableDictionary)?.mutableCopy() as? NSMutableDictionary
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue?.mutableCopy() as? NSMutableDictionary
            }
        }
    }

    public subscript(strings index: String) -> [String]? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return state.rawStorage[index] as? [String]
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public subscript(array index: String) -> NSMutableArray? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return (state.rawStorage[index] as? NSMutableArray)?.mutableCopy() as? NSMutableArray
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue?.mutableCopy() as? NSMutableArray
            }
        }
    }

    public subscript(numbers index: String) -> [NSNumber]? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return state.rawStorage[index] as? [NSNumber]
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public subscript(ints index: String) -> [Int]? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return state.rawStorage[index] as? [Int]
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public subscript(doubles index: String) -> [Double]? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return state.rawStorage[index] as? [Double]
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public subscript(bool index: String) -> Bool? {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return state.rawStorage[index] as? Bool
            }
        }
        set {
            stateLock.withLock { state in
                hydrateLocked(state)
                state.rawStorage[index] = newValue
            }
        }
    }

    public func setApplicationCategoryType(_ newValue: LSApplicationCategoryType, persist: Bool) {
        let changed = stateLock.withLock { state -> Bool in
            hydrateLocked(state)
            let current = state.rawStorage["LSApplicationCategoryType"] as? String
            if newValue == .none {
                guard current != nil else { return false }
                state.rawStorage.removeObject(forKey: "LSApplicationCategoryType")
                return true
            }
            guard current != newValue.rawValue else { return false }
            state.rawStorage["LSApplicationCategoryType"] = newValue.rawValue
            return true
        }
        if changed && persist {
            do {
                try write()
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
    }

    public var applicationCategoryType: LSApplicationCategoryType {
        get {
            LSApplicationCategoryType(
                rawValue: self[string: "LSApplicationCategoryType"] ?? ""
            ) ?? LSApplicationCategoryType.none
        }
        set {
            setApplicationCategoryType(newValue, persist: true)
        }
    }

    public var minimumOSVersion: String {
        get {
            self[string: "MinimumOSVersion"] ?? ""
        }
        set {
            self[string: "MinimumOSVersion"] = newValue
        }
    }

    public var bundleName: String {
        if self[string: "CFBundleName"] == nil || self[string: "CFBundleName"] == "" {
            return self[string: "CFBundleDisplayName"] ?? ""
        } else {
            return self[string: "CFBundleName"] ?? ""
        }
    }

    public var displayName: String {
        if self[string: "CFBundleDisplayName"] == nil || self[string: "CFBundleDisplayName"] == "" {
            return self[string: "CFBundleName"] ?? ""
        } else {
            return self[string: "CFBundleDisplayName"] ?? ""
        }
    }

    public var bundleIdentifier: String {
        self[string: "CFBundleIdentifier"] ?? ""
    }

    public var executableName: String {
        self[string: "CFBundleExecutable"] ?? ""
    }

    public var bundleVersion: String {
        self[string: "CFBundleShortVersionString"] ?? ""
    }

    public var primaryIconName: String {
        stateLock.withLock { state in
            if !state.isHydrated, let cached = state.cachedPrimaryIconName, !cached.isEmpty {
                return cached
            }
            hydrateLocked(state)

            if let bundleIconDict = state.rawStorage["CFBundleIcons~ipad"] as? [String: Any],
               let primaryBundleIconDict = bundleIconDict["CFBundlePrimaryIcon"] as? [String: Any],
               let bundleIconFiles = primaryBundleIconDict["CFBundleIconFiles"] as? [String],
               let primaryIconName = bundleIconFiles.last {
                return primaryIconName
            }

            if let bundleIconDict = state.rawStorage["CFBundleIcons"] as? [String: Any],
               let primaryBundleIconDict = bundleIconDict["CFBundlePrimaryIcon"] as? [String: Any],
               let bundleIconFiles = primaryBundleIconDict["CFBundleIconFiles"] as? [String],
               let primaryIconName = bundleIconFiles.last {
                return primaryIconName
            }

            if let bundleIconFiles = state.rawStorage["CFBundleIconFiles"] as? [String],
               let primaryIconName = bundleIconFiles.last {
                return primaryIconName
            }

            return "AppIcon"
        }
    }

    public var lsEnvironment: [String: String] {
        get {
            stateLock.withLock { state in
                hydrateLocked(state)
                return state.rawStorage["LSEnvironment"] as? [String: String] ?? [:]
            }
        }
        set {
            let changed = stateLock.withLock { state -> Bool in
                hydrateLocked(state)
                var filtered = newValue
                if let dyldPath = filtered["DYLD_LIBRARY_PATH"], dyldPath.isEmpty {
                    filtered.removeValue(forKey: "DYLD_LIBRARY_PATH")
                }
                if filtered.isEmpty {
                    guard state.rawStorage["LSEnvironment"] != nil else { return false }
                    state.rawStorage.removeObject(forKey: "LSEnvironment")
                    return true
                }
                state.rawStorage["LSEnvironment"] = NSMutableDictionary(dictionary: filtered)
                return true
            }
            guard changed else { return }
            do {
                try write()
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
    }

    public func assert(minimumVersion: Double) {
        let components = minimumOSVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
        guard let major = components.first.flatMap({ Int($0) }) else {
            return
        }
        let minor = components.count > 1 ? (Int(components[1]) ?? 0) : 0
        let patch = components.count > 2 ? (Int(components[2]) ?? 0) : 0

        let formattedMin = String(format: "%.1f", minimumVersion)
        let minComponents = formattedMin.split(separator: ".")
        let minMajor = minComponents.first.flatMap { Int($0) } ?? Int(minimumVersion)
        let minMinor = minComponents.count > 1 ? (Int(minComponents[1]) ?? 0) : 0

        if (major, minor, patch) > (minMajor, minMinor, 0) {
            minimumOSVersion = formattedMin
        }
    }
}
