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
import Security

private let ptPluginPendingPathsLock = PTUnfairLock()
nonisolated(unsafe) private var ptPluginPendingPaths = Set<String>()
nonisolated(unsafe) private var ptPluginDyldCallbackInstalled = false

private func ptPluginContainerDyldAddImageCallback(
    _ header: UnsafePointer<mach_header>?,
    _ vmaddrSlide: Int
) {
    _ = vmaddrSlide
    guard let header else { return }
    var info = Dl_info()
    guard dladdr(UnsafeRawPointer(header), &info) != 0,
          let fname = info.dli_fname else {
        return
    }
    if pt_is_registered_hidden_module(fname) {
        pt_register_hidden_image_header(UnsafeRawPointer(header))
        return
    }
    let pathStr = String(cString: fname)
    let matchesPending = ptPluginPendingPathsLock.withLock {
        ptPluginPendingPaths.contains(pathStr)
    }
    if matchesPending {
        pt_register_hidden_image_header(UnsafeRawPointer(header))
    }
}

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

public enum PTPluginLoadStatus: Equatable, Sendable {
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

public struct PTPluginLoadRecord: Equatable, Sendable {
    public let identifier: String
    public let dylibPath: String
    public let isLegacySynthesized: Bool
    public let status: PTPluginLoadStatus
}

public final class PTPluginContainer: @unchecked Sendable {
    public static let shared = PTPluginContainer()
    public static let defaultUserPluginsDirectoryName = "UserPlugins"
    public static let manifestFilename = "PluginManifest.json"

    public typealias DlopenHandler = (_ path: String, _ mode: Int32) -> UnsafeMutableRawPointer?
    public typealias DlerrorHandler = () -> String?
    public typealias CodeSignatureValidator = (_ url: URL) -> Bool

    private let dlopenHandler: DlopenHandler
    private let dlerrorHandler: DlerrorHandler
    private let codeSignatureValidator: CodeSignatureValidator
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
        },
        codeSignatureValidator: @escaping CodeSignatureValidator = { url in
            PTPluginContainer.verifyCodeSignature(at: url)
        }
    ) {
        self.dlopenHandler = dlopenHandler
        self.dlerrorHandler = dlerrorHandler
        self.codeSignatureValidator = codeSignatureValidator
    }

    private typealias SecStaticCodeCreateWithPathFn = @convention(c) (
        CFURL,
        UInt32,
        UnsafeMutablePointer<UnsafeRawPointer?>
    ) -> OSStatus
    private typealias SecStaticCodeCheckValidityFn = @convention(c) (
        UnsafeRawPointer,
        UInt32,
        UnsafeRawPointer?
    ) -> OSStatus

    /// Verifies static Mach-O / bundle code signature via Security.framework `SecStaticCodeCheckValidity`,
    /// accepting validly signed or ad-hoc signed binaries while rejecting unsigned or corrupted files.
    public static func verifyCodeSignature(at url: URL, doNotValidateResources: Bool = false) -> Bool {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let createSym = dlsym(rtldDefault, "SecStaticCodeCreateWithPath"),
              let checkSym = dlsym(rtldDefault, "SecStaticCodeCheckValidity") else {
            return false
        }
        let createFn = unsafeBitCast(createSym, to: SecStaticCodeCreateWithPathFn.self)
        let checkFn = unsafeBitCast(checkSym, to: SecStaticCodeCheckValidityFn.self)

        var staticCodeRaw: UnsafeRawPointer?
        let createStatus = createFn(url as CFURL, 0, &staticCodeRaw)
        guard createStatus == errSecSuccess, let codeRef = staticCodeRaw else {
            return false
        }
        defer {
            _ = Unmanaged<AnyObject>.fromOpaque(codeRef).takeRetainedValue()
        }
        // kSecCSDoNotValidateResources = 0x4; default flags = 0.
        let checkFlags: UInt32 = doNotValidateResources ? 0x4 : 0
        return checkFn(codeRef, checkFlags, nil) == errSecSuccess
    }

    private static func isNonSymlinkRegularFile(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func ensureDyldAddImageCallbackInstalled() {
        let shouldInstall = ptPluginPendingPathsLock.withLock { () -> Bool in
            guard !ptPluginDyldCallbackInstalled else { return false }
            ptPluginDyldCallbackInstalled = true
            return true
        }
        if shouldInstall {
            _dyld_register_func_for_add_image(ptPluginContainerDyldAddImageCallback)
        }
    }

    public static func defaultPlayToolsVersion() -> String {
        (Bundle(for: PTPluginContainer.self).infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.10"
    }

    public static func defaultUserPluginsDirectory() -> URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent(defaultUserPluginsDirectoryName, isDirectory: true)
    }

    private static func directoryHasEntries(at directory: URL) -> Bool {
        guard let dir = opendir(directory.path) else {
            return false
        }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let nameIsDot = ent.pointee.d_name.0 == CChar(bitPattern: UInt8(ascii: "."))
                && (ent.pointee.d_name.1 == 0
                    || (ent.pointee.d_name.1 == CChar(bitPattern: UInt8(ascii: ".")) && ent.pointee.d_name.2 == 0))
            if !nameIsDot {
                return true
            }
        }
        return false
    }

    public static func defaultBuiltInAutomationBridgeDirectory() -> URL {
        var dirBuf = [CChar](repeating: 0, count: 1024)
        if pt_copy_automation_bootstrap_bridge_dir(&dirBuf, dirBuf.count) {
            let str = dirBuf.withUnsafeBufferPointer { buf -> String in
                guard let base = buf.baseAddress else { return "" }
                return String(cString: base)
            }
            if str.hasPrefix("/") {
                return URL(fileURLWithPath: str, isDirectory: true)
            }
        }
        #if DEBUG
        if let envPtr = getenv("MACOVER_AUTOMATION_BRIDGE_DIR"),
           let envPath = String(validatingCString: envPtr),
           envPath.hasPrefix("/") {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: PlaySettings.resolveHostUserRoot(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("app.makedie.MacOver", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("BuiltInPlugins", isDirectory: true)
            .appendingPathComponent("CoverUseBridge", isDirectory: true)
    }

    public func initialize() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let playToolsVersion = Self.defaultPlayToolsVersion()
        let safeMode = PTSafeMode.isActive

        var combinedRecords: [PTPluginLoadRecord] = []
        if let dir = Self.defaultUserPluginsDirectory(), Self.directoryHasEntries(at: dir) {
            combinedRecords = loadPlugins(
                in: dir,
                currentBundleIdentifier: bundleID,
                currentPlayToolsVersion: playToolsVersion,
                isSafeModeActive: safeMode
            )
        }

        let alreadyLoadedBridge = combinedRecords.contains { record in
            record.status == .loaded && (
                record.identifier.localizedCaseInsensitiveContains("coverusebridge")
                    || record.dylibPath.hasSuffix("/CoverUseBridge.dylib")
            )
        }
        if !safeMode && !alreadyLoadedBridge && pt_has_automation_bootstrap() {
            let builtInDir = Self.defaultBuiltInAutomationBridgeDirectory()
            if Self.directoryHasEntries(at: builtInDir) {
                let extraRecords = loadPlugins(
                    in: builtInDir,
                    currentBundleIdentifier: bundleID,
                    currentPlayToolsVersion: playToolsVersion,
                    isSafeModeActive: safeMode,
                    appendToRecords: true
                )
                combinedRecords.append(contentsOf: extraRecords)
            }
        }

        lock.withLock { _loadRecords = combinedRecords }
    }

    @discardableResult
    public func loadPlugins(
        in directory: URL?,
        currentBundleIdentifier: String,
        currentPlayToolsVersion: String = PTPluginContainer.defaultPlayToolsVersion(),
        isSafeModeActive: Bool,
        diagnosticLogURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appendToRecords: Bool = false
    ) -> [PTPluginLoadRecord] {
        var records: [PTPluginLoadRecord] = []
        guard let directory else {
            if !appendToRecords {
                lock.withLock { _loadRecords = [] }
            }
            return []
        }

        let fm = FileManager.default
        let resolvedDir = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirPrefix = resolvedDir.path.hasSuffix("/") ? resolvedDir.path : (resolvedDir.path + "/")
        let directManifest = directory.appendingPathComponent(Self.manifestFilename)
        var manifestRoots: [(root: URL, manifestURL: URL)] = []
        var bareDylibs: [URL] = []

        if Self.isNonSymlinkRegularFile(atPath: directManifest.path) {
            manifestRoots.append((directory, directManifest))
        } else {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                if !appendToRecords {
                    lock.withLock { _loadRecords = [] }
                }
                return []
            }

            let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in sortedEntries {
                var entrySt = Darwin.stat()
                guard Darwin.lstat(entry.path, &entrySt) == 0 else { continue }
                let entryType = entrySt.st_mode & S_IFMT
                if entryType == S_IFLNK {
                    if entry.pathExtension == "dylib" {
                        PTDiagnosticLogger.log(
                            "Skipping symlink bare plugin at \(entry.lastPathComponent)",
                            bundleIdentifier: currentBundleIdentifier,
                            environment: environment,
                            explicitLogURL: diagnosticLogURL
                        )
                    }
                    continue
                }
                if entryType == S_IFDIR {
                    let candidate = entry.appendingPathComponent(Self.manifestFilename)
                    if Self.isNonSymlinkRegularFile(atPath: candidate.path) {
                        manifestRoots.append((entry, candidate))
                    }
                } else if entryType == S_IFREG {
                    if entry.pathExtension == "json" && entry.lastPathComponent.hasSuffix(".manifest.json") {
                        manifestRoots.append((directory, entry))
                    } else if entry.pathExtension == "dylib" {
                        bareDylibs.append(entry)
                    }
                }
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
                    claimedPaths.insert(dylibURL.resolvingSymlinksInPath().standardizedFileURL.path)
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
                    claimedPaths.insert(dylibURL.resolvingSymlinksInPath().standardizedFileURL.path)
                    records.append(PTPluginLoadRecord(
                        identifier: manifest.identifier,
                        dylibPath: dylibURL.path,
                        isLegacySynthesized: false,
                        status: .skippedBundleMismatch
                    ))
                case .invalid(let reason):
                    let rawTarget = item.root.appendingPathComponent(manifest.entrypoint).path
                    if !manifest.entrypoint.isEmpty {
                        claimedPaths.insert(
                            URL(fileURLWithPath: rawTarget).resolvingSymlinksInPath().standardizedFileURL.path
                        )
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
            let resolvedDylib = dylibURL.resolvingSymlinksInPath().standardizedFileURL
            if claimedPaths.contains(resolvedDylib.path) || claimedPaths.contains(dylibURL.standardizedFileURL.path) {
                continue
            }
            guard Self.isNonSymlinkRegularFile(atPath: dylibURL.path),
                  resolvedDylib.path.hasPrefix(resolvedDirPrefix) else {
                let stem = dylibURL.deletingPathExtension().lastPathComponent
                records.append(PTPluginLoadRecord(
                    identifier: "legacy.\(stem)",
                    dylibPath: dylibURL.path,
                    isLegacySynthesized: true,
                    status: .validationFailed("Bare plugin escapes root or is a symlink")
                ))
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
            if !appendToRecords {
                lock.withLock { _loadRecords = records }
            } else {
                lock.withLock { _loadRecords.append(contentsOf: records) }
            }
            return records
        }

        Self.ensureDyldAddImageCallbackInstalled()

        for descriptor in readyDescriptors {
            let resolvedURL = descriptor.dylibURL.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isNonSymlinkRegularFile(atPath: descriptor.dylibURL.path),
                  codeSignatureValidator(resolvedURL) else {
                let reason = "Code signature validation failed for '\(descriptor.dylibURL.lastPathComponent)'"
                records.append(PTPluginLoadRecord(
                    identifier: descriptor.manifest.identifier,
                    dylibPath: descriptor.dylibURL.path,
                    isLegacySynthesized: descriptor.isLegacySynthesized,
                    status: .validationFailed(reason)
                ))
                PTDiagnosticLogger.log(
                    "Plugin validation failed [\(descriptor.manifest.identifier)]: \(reason)",
                    bundleIdentifier: currentBundleIdentifier,
                    force: true,
                    environment: environment,
                    explicitLogURL: diagnosticLogURL
                )
                continue
            }

            for fragment in descriptor.registeredFragments {
                fragment.withCString { cstr in
                    pt_register_hidden_module(cstr)
                }
            }

            let rawPath = descriptor.dylibURL.path
            let resolvedPath = resolvedURL.path
            ptPluginPendingPathsLock.withLock {
                ptPluginPendingPaths.insert(rawPath)
                ptPluginPendingPaths.insert(resolvedPath)
            }
            defer {
                ptPluginPendingPathsLock.withLock {
                    ptPluginPendingPaths.remove(rawPath)
                    ptPluginPendingPaths.remove(resolvedPath)
                }
            }

            // Drain any stale dlerror before dlopen.
            _ = dlerrorHandler()
            if dlopenHandler(rawPath, RTLD_NOW | RTLD_LOCAL) != nil {
                registerLoadedHeader(matchingPath: rawPath)
                records.append(PTPluginLoadRecord(
                    identifier: descriptor.manifest.identifier,
                    dylibPath: rawPath,
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
                    dylibPath: rawPath,
                    isLegacySynthesized: descriptor.isLegacySynthesized,
                    status: .failed(errMsg)
                ))
                PTDiagnosticLogger.log(
                    "Failed to dlopen plugin \(descriptor.manifest.identifier) at "
                        + "\(rawPath): \(errMsg)",
                    bundleIdentifier: currentBundleIdentifier,
                    force: true,
                    environment: environment,
                    explicitLogURL: diagnosticLogURL
                )
            }
        }

        if !appendToRecords {
            lock.withLock { _loadRecords = records }
        } else {
            lock.withLock { _loadRecords.append(contentsOf: records) }
        }
        return records
    }

    private enum ValidationResult {
        case valid(URL)
        case bundleMismatch(URL)
        case invalid(String)
    }

    public static func isCompatiblePlayToolsVersion(
        required minVer: PTSemanticVersion,
        current curVer: PTSemanticVersion
    ) -> Bool {
        if minVer <= curVer {
            return true
        }
        // MacOver rebranded PlayTools versions from 4.x/5.x to 1.x while preserving 4.0.0...5.1.0 plugin ABI.
        let macOverBase = PTSemanticVersion(major: 1, minor: 0, patch: 0)
        let playCoverEraFloor = PTSemanticVersion(major: 4, minor: 0, patch: 0)
        let playCoverEraCeiling = PTSemanticVersion(major: 5, minor: 1, patch: 0)
        return curVer >= macOverBase
            && curVer < playCoverEraFloor
            && minVer >= playCoverEraFloor
            && minVer <= playCoverEraCeiling
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

        let rootResolved = pluginRoot.resolvingSymlinksInPath().standardizedFileURL
        let rawCandidateURL = pluginRoot.standardizedFileURL.appendingPathComponent(entry)
        let candidateResolved = rawCandidateURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : (rootResolved.path + "/")

        guard let minVer = PTSemanticVersion(manifest.minPlayToolsVersion),
              let curVer = PTSemanticVersion(currentPlayToolsVersion) else {
            return .invalid("Invalid version string '\(manifest.minPlayToolsVersion)'")
        }
        guard Self.isCompatiblePlayToolsVersion(required: minVer, current: curVer) else {
            return .invalid(
                "Requires PlayTools >= \(manifest.minPlayToolsVersion), current is \(currentPlayToolsVersion)"
            )
        }

        var st = Darwin.stat()
        guard Darwin.lstat(rawCandidateURL.path, &st) == 0 else {
            return .invalid("Entrypoint file missing at \(rawCandidateURL.path)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .invalid("Entrypoint '\(entry)' must be a non-symlink regular file")
        }
        guard candidateResolved.path.hasPrefix(rootPrefix) else {
            return .invalid("Entrypoint '\(entry)' escapes plugin root")
        }

        if !manifest.targetBundleIdentifiers.contains("*") &&
            !manifest.targetBundleIdentifiers.contains(currentBundleIdentifier) {
            return .bundleMismatch(rawCandidateURL)
        }

        return .valid(rawCandidateURL)
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
