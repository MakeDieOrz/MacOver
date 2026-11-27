//
//  AppInfo.swift
//  PlayCover
//

import Foundation
import Synchronization

public class AppInfo {
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

    public let url: URL
    fileprivate var rawStorage: NSMutableDictionary
    private var wasBinaryPlist: Bool = false
    private let hydrationLock: Mutex<Bool>
    private let unhydratedStringKeys: Set<String>
    private var cachedPrimaryIconName: String?

    public init(contentsOf url: URL) {
        self.hydrationLock = Mutex(true)
        self.unhydratedStringKeys = []
        self.cachedPrimaryIconName = nil
        do {
            let data = try Data(contentsOf: url)
            var format: PropertyListSerialization.PropertyListFormat = .xml
            let parsed = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format
            )
            if let dict = parsed as? NSMutableDictionary {
                wasBinaryPlist = (format == .binary)
                rawStorage = dict
                self.url = url
            } else {
                wasBinaryPlist = false
                rawStorage = NSMutableDictionary()
                self.url = URL(fileURLWithPath: "")
            }
        } catch {
            PlayCoverDiagnostics.reportError(error)
            wasBinaryPlist = false
            rawStorage = NSMutableDictionary()
            self.url = URL(fileURLWithPath: "")
        }
    }

    public init(
        cachedPlistURL url: URL,
        cachedFields: CachedFields,
        installGenerationKey: String = "MacOverInstallGeneration"
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
        self.rawStorage = storage
        self.wasBinaryPlist = false
        self.hydrationLock = Mutex(false)
        self.unhydratedStringKeys = [
            "CFBundleIdentifier",
            "CFBundleName",
            "CFBundleDisplayName",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "CFBundleExecutable",
            installGenerationKey
        ]
        self.cachedPrimaryIconName = cachedFields.primaryIconName
    }

    private init(url: URL, rawStorage: NSMutableDictionary, wasBinaryPlist: Bool = false) {
        self.url = url
        self.rawStorage = rawStorage
        self.wasBinaryPlist = wasBinaryPlist
        self.hydrationLock = Mutex(true)
        self.unhydratedStringKeys = []
        self.cachedPrimaryIconName = nil
    }

    private func ensureHydratedFromDisk() {
        hydrationLock.withLock { isHydrated in
            guard !isHydrated else { return }
            defer { isHydrated = true }
            cachedPrimaryIconName = nil
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
                    wasBinaryPlist = (format == .binary)
                    rawStorage = dict
                }
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
    }

    public func retargeted(toURL url: URL) -> AppInfo {
        ensureHydratedFromDisk()
        guard let copy = rawStorage.mutableCopy() as? NSMutableDictionary
        else { fatalError("Failed to copy rawStorage") }
        return AppInfo(url: url, rawStorage: copy, wasBinaryPlist: wasBinaryPlist)
    }

    /// Write a serialized representation of this info to the given URL, preserving binary format if originally binary
    public func write(toURL url: URL) throws {
        ensureHydratedFromDisk()
        let format: PropertyListSerialization.PropertyListFormat = wasBinaryPlist ? .binary : .xml
        let data = try PropertyListSerialization.data(
            fromPropertyList: rawStorage,
            format: format,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// Overwrites the file this AppInfo was loaded from
    public func write() throws {
        try write(toURL: url)
    }

    public subscript(string index: String) -> String? {
        get {
            if !unhydratedStringKeys.contains(index) {
                ensureHydratedFromDisk()
            }
            return rawStorage[index] as? String
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(object index: String) -> NSObject? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? NSObject
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(dictionary index: String) -> NSMutableDictionary? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? NSMutableDictionary
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(strings index: String) -> [String]? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? [String]
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(array index: String) -> NSMutableArray? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? NSMutableArray
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(numbers index: String) -> [NSNumber]? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? [NSNumber]
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(ints index: String) -> [Int]? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? [Int]
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(doubles index: String) -> [Double]? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? [Double]
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public subscript(bool index: String) -> Bool? {
        get {
            ensureHydratedFromDisk()
            return rawStorage[index] as? Bool
        }
        set {
            ensureHydratedFromDisk()
            rawStorage[index] = newValue
        }
    }

    public func setApplicationCategoryType(_ newValue: LSApplicationCategoryType, persist: Bool) {
        ensureHydratedFromDisk()
        let current = self[string: "LSApplicationCategoryType"]
        if newValue == .none {
            guard current != nil else { return }
            rawStorage.removeObject(forKey: "LSApplicationCategoryType")
        } else {
            guard current != newValue.rawValue else { return }
            self[string: "LSApplicationCategoryType"] = newValue.rawValue
        }
        if persist {
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
        let unhydratedCached = hydrationLock.withLock { isHydrated -> String? in
            guard !isHydrated else { return nil }
            return cachedPrimaryIconName
        }
        if let unhydratedCached, !unhydratedCached.isEmpty {
            return unhydratedCached
        }

        if let bundleIconDict = self[dictionary: "CFBundleIcons~ipad"],
           let primaryBundleIconDict = bundleIconDict["CFBundlePrimaryIcon"] as? [String: Any],
           let bundleIconFiles = primaryBundleIconDict["CFBundleIconFiles"] as? [String],
           let primaryIconName = bundleIconFiles.last {
            return primaryIconName
        }

        if let bundleIconDict = self[dictionary: "CFBundleIcons"],
           let primaryBundleIconDict = bundleIconDict["CFBundlePrimaryIcon"] as? [String: Any],
           let bundleIconFiles = primaryBundleIconDict["CFBundleIconFiles"] as? [String],
           let primaryIconName = bundleIconFiles.last {
            return primaryIconName
        }

        if let bundleIconFiles = self[strings: "CFBundleIconFiles"],
           let primaryIconName = bundleIconFiles.last {
            return primaryIconName
        }

        return "AppIcon"
    }

    public var lsEnvironment: [String: String] {
        get {
            self[dictionary: "LSEnvironment"] as? [String: String] ?? [:]
        }
        set {
            ensureHydratedFromDisk()
            var filtered = newValue
            if let dyldPath = filtered["DYLD_LIBRARY_PATH"], dyldPath.isEmpty {
                filtered.removeValue(forKey: "DYLD_LIBRARY_PATH")
            }
            if filtered.isEmpty {
                guard rawStorage["LSEnvironment"] != nil else { return }
                rawStorage.removeObject(forKey: "LSEnvironment")
            } else {
                self[dictionary: "LSEnvironment"] = NSMutableDictionary(dictionary: filtered)
            }
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
