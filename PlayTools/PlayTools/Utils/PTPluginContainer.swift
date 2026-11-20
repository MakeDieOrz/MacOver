//
//  PTPluginContainer.swift
//  PlayTools
//
//  Declarative manifest validation, Safe Mode gating, dlerror() diagnostics,
//  and dynamic anti-detection registration for user plugins.
//

import Darwin
import Foundation
import MachO

public struct PTSemanticVersion: Comparable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ rawString: String) {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let core = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let maj = Int(parts[0]), maj >= 0 else {
            return nil
        }
        let minVal: Int
        if parts.count >= 2 {
            guard let parsedMin = Int(parts[1]), parsedMin >= 0 else { return nil }
            minVal = parsedMin
        } else {
            minVal = 0
        }
        let patVal: Int
        if parts.count == 3 {
            guard let parsedPat = Int(parts[2]), parsedPat >= 0 else { return nil }
            patVal = parsedPat
        } else {
            patVal = 0
        }
        self.major = maj
        self.minor = minVal
        self.patch = patVal
    }

    public static func < (lhs: PTSemanticVersion, rhs: PTSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct PTPluginManifest: Codable, Equatable {
    public let manifestVersion: String
    public let identifier: String
    public let name: String
    public let version: String
    public let minPlayToolsVersion: String
    public let targetBundleIdentifiers: [String]
    public let loadPriority: Int
    public let capabilities: [String]
    public let entrypoint: String

    enum CodingKeys: String, CodingKey {
        case manifestVersion
        case identifier
        case name
        case version
        case minPlayToolsVersion
        case targetBundleIdentifiers
        case loadPriority
        case capabilities
        case entrypoint
    }

    public init(
        manifestVersion: String,
        identifier: String,
        name: String,
        version: String,
        minPlayToolsVersion: String = "0.0.0",
        targetBundleIdentifiers: [String] = ["*"],
        loadPriority: Int = 100,
        capabilities: [String] = [],
        entrypoint: String
    ) {
        self.manifestVersion = manifestVersion
        self.identifier = identifier
        self.name = name
        self.version = version
        self.minPlayToolsVersion = minPlayToolsVersion
        self.targetBundleIdentifiers = targetBundleIdentifiers
        self.loadPriority = loadPriority
        self.capabilities = capabilities
        self.entrypoint = entrypoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try container.decode(String.self, forKey: .manifestVersion)
        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        minPlayToolsVersion = try container.decodeIfPresent(String.self, forKey: .minPlayToolsVersion) ?? "0.0.0"
        targetBundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .targetBundleIdentifiers
        ) ?? ["*"]
        loadPriority = try container.decodeIfPresent(Int.self, forKey: .loadPriority) ?? 100
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        entrypoint = try container.decode(String.self, forKey: .entrypoint)
    }
}

public typealias PluginManifest = PTPluginManifest

public enum PTPluginLoadStatus: Equatable {
    case loaded
    case blockedBySafeMode
    case skippedBundleMismatch
    case validationFailed(String)
    case failed(String)
}

public struct PTPluginDescriptor: Equatable {
    public let manifest: PTPluginManifest
    public let dylibURL: URL
    public let isLegacySynthesized: Bool
    public let registeredFragments: [String]
}

public struct PTPluginLoadRecord: Equatable {
    public let identifier: String
    public let dylibPath: String
    public let isLegacySynthesized: Bool
    public let status: PTPluginLoadStatus
}

public final class PTPluginContainer {
    public static let shared = PTPluginContainer()
    public static let defaultUserPluginsDirectoryName = "UserPlugins"
    public static let manifestFilename = "PluginManifest.json"

    public typealias DlopenHandler = (_ path: String, _ mode: Int32) -> UnsafeMutableRawPointer?
    public typealias DlerrorHandler = () -> String?

    private let dlopenHandler: DlopenHandler
    private let dlerrorHandler: DlerrorHandler
    private let lock = PTUnfairLock()
    private var _loadRecords: [PTPluginLoadRecord] = []

    public var loadRecords: [PTPluginLoadRecord] {
        lock.withLock { _loadRecords }
    }

    public init(
        dlopenHandler: @escaping DlopenHandler = { path, mode in dlopen(path, mode) },
        dlerrorHandler: @escaping DlerrorHandler = {
            guard let ptr = dlerror() else { return nil }
            return String(cString: ptr)
        }
    ) {
        self.dlopenHandler = dlopenHandler
        self.dlerrorHandler = dlerrorHandler
    }

    public static func defaultPlayToolsVersion() -> String {
        (Bundle(for: PTPluginContainer.self).infoDictionary?["CFBundleShortVersionString"] as? String) ?? "5.1.0"
    }

    public static func defaultUserPluginsDirectory() -> URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent(defaultUserPluginsDirectoryName, isDirectory: true)
    }

    public func initialize() {
        let dir = Self.defaultUserPluginsDirectory()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        _ = loadPlugins(
            in: dir,
            currentBundleIdentifier: bundleID,
            currentPlayToolsVersion: Self.defaultPlayToolsVersion(),
            isSafeModeActive: PTSafeMode.isActive
        )
    }

    @discardableResult
    public func loadPlugins(
        in directory: URL?,
        currentBundleIdentifier: String,
        currentPlayToolsVersion: String = PTPluginContainer.defaultPlayToolsVersion(),
        isSafeModeActive: Bool,
        diagnosticLogURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [PTPluginLoadRecord] {
        var records: [PTPluginLoadRecord] = []
        guard let directory else {
            lock.withLock { _loadRecords = [] }
            return []
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            lock.withLock { _loadRecords = [] }
            return []
        }

        let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var manifestRoots: [(root: URL, manifestURL: URL)] = []
        var bareDylibs: [URL] = []

        for entry in sortedEntries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let candidate = entry.appendingPathComponent(Self.manifestFilename)
                if fm.fileExists(atPath: candidate.path) {
                    manifestRoots.append((entry, candidate))
                }
            } else if entry.pathExtension == "json" && entry.lastPathComponent.hasSuffix(".manifest.json") {
                manifestRoots.append((directory, entry))
            } else if entry.pathExtension == "dylib" {
                bareDylibs.append(entry)
            }
        }

        var claimedPaths = Set<String>()
        var readyDescriptors: [PTPluginDescriptor] = []

        for item in manifestRoots {
            let fallbackId = item.manifestURL.lastPathComponent
            do {
                let data = try Data(contentsOf: item.manifestURL)
                let manifest = try JSONDecoder().decode(PTPluginManifest.self, from: data)
                let resolution = validate(
                    manifest: manifest,
                    pluginRoot: item.root,
                    currentBundleIdentifier: currentBundleIdentifier,
                    currentPlayToolsVersion: currentPlayToolsVersion
                )
                switch resolution {
                case .valid(let dylibURL):
                    claimedPaths.insert(dylibURL.standardizedFileURL.path)
                    readyDescriptors.append(PTPluginDescriptor(
                        manifest: manifest,
                        dylibURL: dylibURL,
                        isLegacySynthesized: false,
                        registeredFragments: antiDetectionFragments(
                            manifest: manifest,
                            dylibURL: dylibURL,
                            isLegacy: false
                        )
                    ))
                case .bundleMismatch(let dylibURL):
                    claimedPaths.insert(dylibURL.standardizedFileURL.path)
                    records.append(PTPluginLoadRecord(
                        identifier: manifest.identifier,
                        dylibPath: dylibURL.path,
                        isLegacySynthesized: false,
                        status: .skippedBundleMismatch
                    ))
                case .invalid(let reason):
                    let rawTarget = item.root.appendingPathComponent(manifest.entrypoint).path
                    if !manifest.entrypoint.isEmpty {
                        claimedPaths.insert(URL(fileURLWithPath: rawTarget).standardizedFileURL.path)
                    }
                    records.append(PTPluginLoadRecord(
                        identifier: manifest.identifier,
                        dylibPath: rawTarget,
                        isLegacySynthesized: false,
                        status: .validationFailed(reason)
                    ))
                    PTDiagnosticLogger.log(
                        "Plugin validation failed [\(manifest.identifier)]: \(reason)",
                        bundleIdentifier: currentBundleIdentifier,
                        force: true,
                        environment: environment,
                        explicitLogURL: diagnosticLogURL
                    )
                }
            } catch {
                let msg = "Manifest decode failed (\(fallbackId)): \(error.localizedDescription)"
                records.append(PTPluginLoadRecord(
                    identifier: fallbackId,
                    dylibPath: item.manifestURL.path,
                    isLegacySynthesized: false,
                    status: .validationFailed(msg)
                ))
                PTDiagnosticLogger.log(
                    msg,
                    bundleIdentifier: currentBundleIdentifier,
                    force: true,
                    environment: environment,
                    explicitLogURL: diagnosticLogURL
                )
            }
        }

        for dylibURL in bareDylibs {
            if claimedPaths.contains(dylibURL.standardizedFileURL.path) {
                continue
            }
            let manifest = synthesizeLegacyManifest(for: dylibURL)
            readyDescriptors.append(PTPluginDescriptor(
                manifest: manifest,
                dylibURL: dylibURL,
                isLegacySynthesized: true,
                registeredFragments: antiDetectionFragments(
                    manifest: manifest,
                    dylibURL: dylibURL,
                    isLegacy: true
                )
            ))
        }

        readyDescriptors.sort { lhs, rhs in
            if lhs.manifest.loadPriority != rhs.manifest.loadPriority {
                return lhs.manifest.loadPriority < rhs.manifest.loadPriority
            }
            if lhs.manifest.identifier != rhs.manifest.identifier {
                return lhs.manifest.identifier < rhs.manifest.identifier
            }
            return lhs.dylibURL.path < rhs.dylibURL.path
        }

        if isSafeModeActive {
            for descriptor in readyDescriptors {
                records.append(PTPluginLoadRecord(
                    identifier: descriptor.manifest.identifier,
                    dylibPath: descriptor.dylibURL.path,
                    isLegacySynthesized: descriptor.isLegacySynthesized,
                    status: .blockedBySafeMode
                ))
            }
            if !readyDescriptors.isEmpty {
                PTDiagnosticLogger.log(
                    "Safe Mode active: skipped loading \(readyDescriptors.count) user plugin(s)",
                    bundleIdentifier: currentBundleIdentifier,
                    force: true,
                    environment: environment,
                    explicitLogURL: diagnosticLogURL
                )
            }
            lock.withLock { _loadRecords = records }
            return records
        }

        for descriptor in readyDescriptors {
            for fragment in descriptor.registeredFragments {
                fragment.withCString { cstr in
                    pt_register_hidden_module(cstr)
                }
            }

            // Drain any stale dlerror before dlopen.
            _ = dlerrorHandler()
            if dlopenHandler(descriptor.dylibURL.path, RTLD_NOW) != nil {
                registerLoadedHeader(matchingPath: descriptor.dylibURL.path)
                records.append(PTPluginLoadRecord(
                    identifier: descriptor.manifest.identifier,
                    dylibPath: descriptor.dylibURL.path,
                    isLegacySynthesized: descriptor.isLegacySynthesized,
                    status: .loaded
                ))
                PTDiagnosticLogger.log(
                    "Loaded plugin \(descriptor.manifest.identifier) (\(descriptor.manifest.version))",
                    bundleIdentifier: currentBundleIdentifier,
                    force: false,
                    environment: environment,
                    explicitLogURL: diagnosticLogURL
                )
            } else {
                let errMsg = dlerrorHandler() ?? "unknown dlerror"
                records.append(PTPluginLoadRecord(
                    identifier: descriptor.manifest.identifier,
                    dylibPath: descriptor.dylibURL.path,
                    isLegacySynthesized: descriptor.isLegacySynthesized,
                    status: .failed(errMsg)
                ))
                PTDiagnosticLogger.log(
                    "Failed to dlopen plugin \(descriptor.manifest.identifier) at \(descriptor.dylibURL.path): \(errMsg)",
                    bundleIdentifier: currentBundleIdentifier,
                    force: true,
                    environment: environment,
                    explicitLogURL: diagnosticLogURL
                )
            }
        }

        lock.withLock { _loadRecords = records }
        return records
    }

    private enum ValidationResult {
        case valid(URL)
        case bundleMismatch(URL)
        case invalid(String)
    }

    private func validate(
        manifest: PTPluginManifest,
        pluginRoot: URL,
        currentBundleIdentifier: String,
        currentPlayToolsVersion: String
    ) -> ValidationResult {
        guard !manifest.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Plugin identifier is empty")
        }
        guard let manifestVer = PTSemanticVersion(manifest.manifestVersion), manifestVer.major == 1 else {
            return .invalid("Unsupported manifestVersion '\(manifest.manifestVersion)'")
        }

        let entry = manifest.entrypoint
        guard !entry.isEmpty,
              entry.hasSuffix(".dylib"),
              !entry.contains(".."),
              !entry.contains("/"),
              !entry.contains("\\") else {
            return .invalid("Unsafe or invalid entrypoint '\(entry)'")
        }

        let rootStd = pluginRoot.standardizedFileURL
        let candidateURL = rootStd.appendingPathComponent(entry).standardizedFileURL
        let rootPrefix = rootStd.path.hasSuffix("/") ? rootStd.path : (rootStd.path + "/")
        guard candidateURL.path.hasPrefix(rootPrefix) else {
            return .invalid("Entrypoint '\(entry)' escapes plugin root")
        }

        guard let minVer = PTSemanticVersion(manifest.minPlayToolsVersion),
              let curVer = PTSemanticVersion(currentPlayToolsVersion) else {
            return .invalid("Invalid version string '\(manifest.minPlayToolsVersion)'")
        }
        guard minVer <= curVer else {
            return .invalid(
                "Requires PlayTools >= \(manifest.minPlayToolsVersion), current is \(currentPlayToolsVersion)"
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return .invalid("Entrypoint file missing at \(candidateURL.path)")
        }

        if !manifest.targetBundleIdentifiers.contains("*") &&
            !manifest.targetBundleIdentifiers.contains(currentBundleIdentifier) {
            return .bundleMismatch(candidateURL)
        }

        return .valid(candidateURL)
    }

    private func synthesizeLegacyManifest(for dylibURL: URL) -> PTPluginManifest {
        let filename = dylibURL.lastPathComponent
        let stem = dylibURL.deletingPathExtension().lastPathComponent
        return PTPluginManifest(
            manifestVersion: "1.0",
            identifier: "legacy.\(stem)",
            name: stem,
            version: "0.0.0",
            minPlayToolsVersion: "0.0.0",
            targetBundleIdentifiers: ["*"],
            loadPriority: 100,
            capabilities: ["legacy-dylib"],
            entrypoint: filename
        )
    }

    private func antiDetectionFragments(
        manifest: PTPluginManifest,
        dylibURL: URL,
        isLegacy: Bool
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func appendUnique(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            result.append(trimmed)
        }

        let filename = dylibURL.lastPathComponent
        let stem = dylibURL.deletingPathExtension().lastPathComponent
        appendUnique(filename)
        appendUnique(stem)
        if stem.hasPrefix("lib") && stem.count > 3 {
            appendUnique(String(stem.dropFirst(3)))
        }
        if !isLegacy {
            appendUnique(manifest.identifier)
        }
        return result
    }

    private func registerLoadedHeader(matchingPath path: String) {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let count = _dyld_image_count()
        for idx in 0..<count {
            guard let namePtr = _dyld_get_image_name(idx) else { continue }
            let imagePath = String(cString: namePtr)
            if imagePath == path || imagePath == resolvedPath {
                if let hdr = _dyld_get_image_header(idx) {
                    pt_register_hidden_image_header(UnsafeRawPointer(hdr))
                }
                break
            }
        }
    }
}
