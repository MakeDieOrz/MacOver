//
//  PlaySettings+Core.swift
//  PlayTools
//

import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import Security
import Synchronization

/// Thread-safe unfair lock wrapper backed by `Synchronization.Mutex`.
public final class PTUnfairLock: Sendable {
    private let mutex = Mutex<Void>(())

    public init() {}

    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try mutex.withLock { _ in try body() }
    }
}

@objc public final class PlaySettings: NSObject, @unchecked Sendable {
    @objc public static let shared = PlaySettings()

    @objc public let bundleIdentifier: String
    @objc public let settingsUrl: URL
    public let keymappingStateUrl: URL

    private let stateLock = PTUnfairLock()
    private let persistenceLock = PTUnfairLock()
    private var _settingsData: AppSettingsData

    var settingsData: AppSettingsData {
        get { stateLock.withLock { _settingsData } }
        set { stateLock.withLock { _settingsData = newValue } }
    }

    nonisolated(unsafe) private static let internalOverlayTagObject = NSObject()

    @objc(pm_internalOverlayTagKeyAddress)
    public static var internalOverlayTagKeyAddress: UInt {
        UInt(bitPattern: Unmanaged.passUnretained(internalOverlayTagObject).toOpaque())
    }

    @objc public static func resolveHostUserRoot() -> String {
        let rawEnv = getenv("CFFIXED_USER_HOME") ?? getenv("HOME")
        if let rawEnv, let envStr = String(validatingCString: rawEnv), envStr.hasPrefix("/") {
            var path = envStr
            if path.hasPrefix("/System/Volumes/Data/") {
                path.removeFirst("/System/Volumes/Data".count)
            }
            if let range = path.range(of: "/Library/Containers/"), range.lowerBound > path.startIndex {
                return String(path[..<range.lowerBound])
            }
            if path.hasPrefix("/Users/") {
                let afterUsers = path.index(path.startIndex, offsetBy: "/Users/".count)
                if let slash = path[afterUsers...].firstIndex(of: "/") {
                    return String(path[..<slash])
                }
                if afterUsers < path.endIndex {
                    return path
                }
            }
        }
        if let pw = getpwuid(getuid()), let dirPtr = pw.pointee.pw_dir {
            let dir = String(cString: dirPtr)
            if dir.hasPrefix("/") {
                return dir
            }
        }
        return "/Users/\(NSUserName())"
    }

    static func resolveSettingsURL(bundleIdentifier: String) -> URL {
        if let overridePtr = getenv("PLAYTOOLS_SETTINGS_PLIST"),
           let overridePath = String(validatingCString: overridePtr),
           overridePath.hasPrefix("/") {
            return URL(fileURLWithPath: overridePath)
        }
        let userRoot = resolveHostUserRoot()
        let settingsDir = URL(fileURLWithPath: userRoot)
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("app.makedie.MacOver")
            .appendingPathComponent("App Settings")
        if !bundleIdentifier.isEmpty {
            let primary = settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
            if FileManager.default.fileExists(atPath: primary.path) {
                return primary
            }
            if let cfHomePtr = getenv("CFFIXED_USER_HOME"),
               let cfHome = String(validatingCString: cfHomePtr),
               let marker = cfHome.range(of: "/Library/Containers/") {
                let tail = cfHome[marker.upperBound...]
                let cid = tail.prefix(while: { $0 != "/" })
                if !cid.isEmpty {
                    let alt = settingsDir.appendingPathComponent("\(cid).plist")
                    if FileManager.default.fileExists(atPath: alt.path) {
                        return alt
                    }
                }
            }
            return primary
        }
        if let cfHomePtr = getenv("CFFIXED_USER_HOME"),
           let cfHome = String(validatingCString: cfHomePtr),
           let marker = cfHome.range(of: "/Library/Containers/") {
            let tail = cfHome[marker.upperBound...]
            let cid = tail.prefix(while: { $0 != "/" })
            if !cid.isEmpty {
                return settingsDir.appendingPathComponent("\(cid).plist")
            }
        }
        return settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
    }

    static func resolveKeymappingStateURL(bundleIdentifier: String) -> URL {
        if let cfHomePtr = getenv("CFFIXED_USER_HOME"),
           let cfHome = String(validatingCString: cfHomePtr),
           cfHome.hasPrefix("/") {
            return URL(fileURLWithPath: cfHome, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("pm_keymapping_state.plist")
        }
        let baseDir: URL
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            baseDir = appSupport
        } else {
            baseDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        let sanitized = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
        let filename = sanitized.isEmpty
            ? "pm_keymapping_state.plist"
            : "pm_keymapping_state_\(sanitized).plist"
        return baseDir.appendingPathComponent(filename)
    }

    convenience override init() {
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        self.init(
            settingsURL: Self.resolveSettingsURL(bundleIdentifier: bundleID),
            bundleIdentifier: bundleID
        )
    }

    init(
        settingsURL: URL,
        bundleIdentifier: String = "",
        keymappingStateURL: URL? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.settingsUrl = settingsURL
        self.keymappingStateUrl = keymappingStateURL
            ?? Self.resolveKeymappingStateURL(bundleIdentifier: bundleIdentifier)

        var decoded: AppSettingsData
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? PropertyListDecoder().decode(AppSettingsData.self, from: data) {
            decoded = parsed
        } else {
            var defaults = AppSettingsData()
            defaults.bundleIdentifier = bundleIdentifier
            decoded = defaults
        }
        let shouldUseKeymappingState: Bool
        if let stateAttrs = try? FileManager.default.attributesOfItem(atPath: self.keymappingStateUrl.path),
           let stateMTime = stateAttrs[.modificationDate] as? Date {
            if let settingsAttrs = try? FileManager.default.attributesOfItem(atPath: settingsURL.path),
               let settingsMTime = settingsAttrs[.modificationDate] as? Date {
                shouldUseKeymappingState = stateMTime >= settingsMTime
            } else {
                shouldUseKeymappingState = true
            }
        } else {
            shouldUseKeymappingState = false
        }
        if shouldUseKeymappingState,
           let stateData = try? Data(contentsOf: self.keymappingStateUrl),
           let stateDict = (try? PropertyListSerialization.propertyList(
               from: stateData, options: [], format: nil
           )) as? [String: Any],
           let savedAt = stateDict["keymappingDisabledAt"] as? NSNumber {
            decoded.keymappingDisabledAt = savedAt.floatValue
        }

        self._settingsData = decoded
        self.discordActivity = decoded.discordActivity
        self.keymapping = decoded.keymapping
        self.configuredNotch = decoded.notch
        self.sensitivity = decoded.sensitivity / 100
        self.configuredBypass = decoded.bypass
        self._windowSizeHeight = CGFloat(decoded.windowHeight)
        self._windowSizeWidth = CGFloat(decoded.windowWidth)
        self.configuredInverseScreenValues = decoded.inverseScreenValues
        self.configuredResolution = decoded.resolution
        let normalizedIOSVersion = PTWindowGeometryMath.StrictDeviceDisplaySpec.normalizedReportedIOSVersion(
            decoded.reportedIOSVersion
        )
        let trimmedModel = decoded.iosDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDeviceModel = trimmedModel.isEmpty ? "iPad13,8" : trimmedModel
        self.configuredDeviceModel = baseDeviceModel
        self.coercedDeviceModel = PTWindowGeometryMath.StrictDeviceDisplaySpec.effectiveModel(
            for: baseDeviceModel,
            normalizedReportedIOSVersion: normalizedIOSVersion
        )
        self.playChain = decoded.playChain
        self.configuredPlayChainDebugging = decoded.playChainDebugging
        self.configuredMetalHUD = decoded.metalHUD
        self.configuredWindowFixMethod = decoded.windowFixMethod
        self.configuredCustomScaler = decoded.customScaler
        self.configuredFrameRateTarget = Self.normalizedFrameRateTarget(decoded.frameRateTarget)
        self.configuredReportedIOSVersion = normalizedIOSVersion
        self.configuredRootWorkDir = decoded.rootWorkDir
        self.noKMOnInput = decoded.noKMOnInput
        self.enableScrollWheel = decoded.enableScrollWheel
        self.rightClickLongPress = decoded.rightClickLongPress
        self.hideTitleBar = decoded.hideTitleBar
        self.floatingWindow = decoded.floatingWindow
        self.quitOnWindowClose = decoded.quitOnWindowClose
        self.configuredDisplayRotation = decoded.displayRotation
        self.checkMicPermissionSync = decoded.checkMicPermissionSync
        self.limitMotionUpdateFrequency = decoded.limitMotionUpdateFrequency
        self.disableBuiltinMouse = decoded.disableBuiltinMouse
        self.blockSleepSpamming = decoded.blockSleepSpamming
        self.ignoreUnityKeyboardInitializationError = decoded.ignoreUnityKeyboardInitializationError
        self.configuredInterceptInlineSyscalls = decoded.interceptInlineSyscalls
        self.configuredStrictEmulationMode = decoded.strictEmulationMode
        self.configuredStrictViewportOrientation = decoded.strictViewportOrientation.rawValue
        self.configuredStrictViewportScaleMode = decoded.strictViewportScaleMode.rawValue

        super.init()
    }

    let discordActivity: DiscordActivity

    @objc public var discordActivityEnabled: Bool {
        guard !PTSafeMode.isActive, !isStrictEmulationActive, !bypass else {
            return false
        }
        return discordActivity.enable
    }

    @objc public let keymapping: Bool

    private let configuredNotch: Bool
    @objc public var notch: Bool {
        isStrictEmulationActive ? false : configuredNotch
    }

    @objc public let sensitivity: Float

    private let configuredBypass: Bool
    @objc public var bypass: Bool {
        isStrictEmulationActive ? true : configuredBypass
    }

    private var _windowSizeHeight: CGFloat
    @objc public var windowSizeHeight: CGFloat {
        get {
            if isStrictEmulationActive {
                return strictLogicalSize.height
            }
            return stateLock.withLock { _windowSizeHeight }
        }
        set { stateLock.withLock { _windowSizeHeight = newValue } }
    }

    private var _windowSizeWidth: CGFloat
    @objc public var windowSizeWidth: CGFloat {
        get {
            if isStrictEmulationActive {
                return strictLogicalSize.width
            }
            return stateLock.withLock { _windowSizeWidth }
        }
        set { stateLock.withLock { _windowSizeWidth = newValue } }
    }

    private let configuredInverseScreenValues: Bool
    @objc public var inverseScreenValues: Bool {
        (PTSafeMode.isActive || configuredStrictEmulationMode) ? false : configuredInverseScreenValues
    }

    private let configuredInterceptInlineSyscalls: Bool
    @objc public var interceptInlineSyscalls: Bool {
        if PTSafeMode.isActive {
            return false
        }
        return configuredStrictEmulationMode ? true : configuredInterceptInlineSyscalls
    }

    private let configuredResolution: Int
    @objc public var adaptiveDisplay: Bool {
        isStrictEmulationActive ? true : (configuredResolution != 0)
    }

    @objc public var resizableWindow: Bool {
        isStrictEmulationActive ? false : (configuredResolution == 6)
    }

    private let configuredStrictEmulationMode: Bool
    private let configuredStrictViewportOrientation: String
    private let configuredStrictViewportScaleMode: String

    private var isStrictEmulationActive: Bool {
        !PTSafeMode.isActive && configuredStrictEmulationMode
    }

    private var strictDisplaySpec: PTWindowGeometryMath.StrictDeviceDisplaySpec {
        PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: coercedDeviceModel)
    }

    private var strictLogicalSize: CGSize {
        strictDisplaySpec.logicalSize(orientation: configuredStrictViewportOrientation)
    }

    @objc public var strictEmulationMode: Bool {
        isStrictEmulationActive
    }

    @objc public var rawConfiguredStrictEmulationMode: Bool {
        configuredStrictEmulationMode
    }

    @objc public var strictViewportOrientation: NSString {
        configuredStrictViewportOrientation as NSString
    }

    @objc public var strictViewportScaleMode: NSString {
        configuredStrictViewportScaleMode as NSString
    }

    @objc public var isStrictPortraitOrientation: Bool {
        configuredStrictViewportOrientation == "portrait"
    }

    private let configuredDeviceModel: String
    private let coercedDeviceModel: String

    @objc public var rawConfiguredDeviceModel: NSString {
        configuredDeviceModel as NSString
    }

    @objc public var deviceModel: NSString {
        (PTSafeMode.isActive ? configuredDeviceModel : coercedDeviceModel) as NSString
    }

    @objc public var oemID: NSString {
        let model = PTSafeMode.isActive ? configuredDeviceModel : coercedDeviceModel
        return StrictDeviceDisplaySpec.oemID(for: model) as NSString
    }

    @objc public var keymappingDisabledAt: Float {
        get {
            stateLock.withLock { _settingsData.keymappingDisabledAt }
        }
        set {
            stateLock.withLock {
                _settingsData.keymappingDisabledAt = newValue
            }
            saveKeymappingDisabledAt(newValue)
        }
    }

    private func saveKeymappingDisabledAt(_ value: Float) {
        persistenceLock.withLock {
            let stateURL = keymappingStateUrl
            let parentDir = stateURL.deletingLastPathComponent()
            let plistDict: [String: Any] = ["keymappingDisabledAt": NSNumber(value: value)]
            guard let outData = try? PropertyListSerialization.data(
                fromPropertyList: plistDict, format: .xml, options: 0
            ) else {
                return
            }

            do {
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true
                    )
                }
                let tmpURL = stateURL.appendingPathExtension("tmp")
                try outData.write(to: tmpURL, options: [])
                if Darwin.rename(tmpURL.path, stateURL.path) != 0 {
                    try? FileManager.default.removeItem(at: tmpURL)
                    try outData.write(to: stateURL, options: [])
                }
            } catch {
                // Best-effort persistence inside guest app container
            }
        }
    }

    @objc public let playChain: Bool

    private let configuredPlayChainDebugging: Bool
    @objc public var playChainDebugging: Bool {
        isStrictEmulationActive ? false : configuredPlayChainDebugging
    }

    private let configuredMetalHUD: Bool
    @objc public var metalHUD: Bool {
        isStrictEmulationActive ? false : configuredMetalHUD
    }

    private let configuredWindowFixMethod: Int
    @objc public var windowFixMethod: Int {
        (PTSafeMode.isActive || configuredStrictEmulationMode) ? 0 : configuredWindowFixMethod
    }

    private let configuredCustomScaler: Double
    @objc public var customScaler: Double {
        if PTSafeMode.isActive {
            return 1.0
        }
        if configuredStrictEmulationMode {
            return strictDisplaySpec.nativeScale
        }
        return configuredCustomScaler
    }

    private let configuredFrameRateTarget: String
    @objc public var frameRateTarget: NSString {
        (PTSafeMode.isActive ? "adaptive" : configuredFrameRateTarget) as NSString
    }

    @objc public var targetFrameRateHz: Int {
        guard !PTSafeMode.isActive else { return 0 }
        switch configuredFrameRateTarget {
        case "fixed120":
            return 120
        case "fixed60":
            return 60
        case "fixed30":
            return 30
        default:
            return 0
        }
    }

    private let configuredReportedIOSVersion: String
    @objc public var reportedIOSVersion: NSString {
        (PTSafeMode.isActive ? "automatic" : configuredReportedIOSVersion) as NSString
    }

    private static func normalizedFrameRateTarget(_ raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fixed120", "120", "120hz":
            return "fixed120"
        case "fixed60", "60", "60hz":
            return "fixed60"
        case "fixed30", "30", "30hz":
            return "fixed30"
        default:
            return "adaptive"
        }
    }

    private let configuredRootWorkDir: Bool
    @objc public var rootWorkDir: Bool {
        isStrictEmulationActive ? true : configuredRootWorkDir
    }

    @objc public let noKMOnInput: Bool

    @objc public let enableScrollWheel: Bool

    @objc public let rightClickLongPress: Bool

    @objc public let hideTitleBar: Bool

    @objc public let floatingWindow: Bool

    @objc public let quitOnWindowClose: Bool

    @objc public func currentQuitOnWindowClose() -> Bool {
        if let data = try? Data(contentsOf: settingsUrl),
           let parsed = try? PropertyListDecoder().decode(AppSettingsData.self, from: data) {
            return parsed.quitOnWindowClose
        }
        return quitOnWindowClose
    }

    private let configuredDisplayRotation: Int
    @objc public var hasUserConfiguredDisplayRotation: Bool {
        configuredDisplayRotation != 0
    }
    @objc public var displayRotation: Int {
        if isStrictEmulationActive {
            return configuredStrictViewportOrientation == "portrait" ? 1 : 0
        }
        return configuredDisplayRotation
    }

    @objc public let checkMicPermissionSync: Bool

    @objc public let limitMotionUpdateFrequency: Bool

    @objc public let disableBuiltinMouse: Bool

    @objc public let blockSleepSpamming: Bool

    @objc public let ignoreUnityKeyboardInitializationError: Bool
}

public struct PTFrameRateRangeValues: Equatable {
    public let minimum: Float
    public let maximum: Float
    public let preferred: Float

    public init(minimum: Float, maximum: Float, preferred: Float) {
        self.minimum = minimum
        self.maximum = maximum
        self.preferred = preferred
    }

    public func clamped(toMaxHz maxHz: Int) -> PTFrameRateRangeValues {
        guard maxHz > 0 else { return self }
        let cap = Float(maxHz)
        let clippedMax = (!maximum.isFinite || maximum <= 0) ? cap : min(maximum, cap)
        let clippedMin = (!minimum.isFinite || minimum <= 0) ? clippedMax : min(minimum, clippedMax)
        let clippedPref = (!preferred.isFinite || preferred <= 0)
            ? clippedMax
            : min(max(preferred, clippedMin), clippedMax)
        return PTFrameRateRangeValues(minimum: clippedMin, maximum: clippedMax, preferred: clippedPref)
    }

    public static func clampedLegacyFPS(_ requestedFPS: Int, maxHz: Int) -> Int {
        guard maxHz > 0 else { return requestedFPS }
        if requestedFPS <= 0 {
            return maxHz
        }
        return min(requestedFPS, maxHz)
    }
}

public enum PTPlayChainPersistentRef {
    public static let iosBinaryLength = 12
    public static let binaryLength = 12
    public static let legacyBinaryLength = 20
    private static let binaryHeader: [UInt8] = [0x8A, 0x9F, 0xC4]
    private static let legacyPrefix = "PCPR1:"

    private static let iosTagToTable: [String: String] = [
        kSecClassGenericPassword as String: kSecClassGenericPassword as String,
        kSecClassInternetPassword as String: kSecClassInternetPassword as String,
        kSecClassCertificate as String: kSecClassCertificate as String,
        kSecClassKey as String: kSecClassKey as String,
        kSecClassIdentity as String: kSecClassIdentity as String
    ]

    private static let tableToTag: [String: UInt8] = [
        kSecClassGenericPassword as String: 0x91,
        kSecClassInternetPassword as String: 0x92,
        kSecClassCertificate as String: 0x93,
        kSecClassKey as String: 0x94,
        kSecClassIdentity as String: 0x95
    ]

    private static let tagToTable: [UInt8: String] = [
        0x91: kSecClassGenericPassword as String,
        0x92: kSecClassInternetPassword as String,
        0x93: kSecClassCertificate as String,
        0x94: kSecClassKey as String,
        0x95: kSecClassIdentity as String
    ]

    private static func decodeIOSRowID(from data: Data) -> Int64? {
        guard data.count == iosBinaryLength else { return nil }
        let base = data.startIndex
        var rawLE: Int64 = 0
        _ = withUnsafeMutableBytes(of: &rawLE) { dst in
            data[(base + 4)..<(base + iosBinaryLength)].copyBytes(to: dst)
        }
        let rowID = Int64(littleEndian: rawLE)
        return rowID > 0 ? rowID : nil
    }

    public static func encode(tableName: String, rowID: Int64 = 1) -> Data {
        let effectiveRowID = rowID > 0 ? rowID : 1
        let tagUTF8 = Array(tableName.utf8)
        if iosTagToTable[tableName] != nil && tagUTF8.count == 4 {
            var bytes = [UInt8]()
            bytes.reserveCapacity(iosBinaryLength)
            bytes.append(contentsOf: tagUTF8)
            var leRowID = effectiveRowID.littleEndian
            withUnsafeBytes(of: &leRowID) { buf in
                bytes.append(contentsOf: buf)
            }
            return Data(bytes)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(legacyBinaryLength)
        bytes.append(contentsOf: binaryHeader)
        bytes.append(tableToTag[tableName] ?? 0x90)
        var leRowID = effectiveRowID.littleEndian
        withUnsafeBytes(of: &leRowID) { buf in
            bytes.append(contentsOf: buf)
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return Data(bytes)
    }

    public static func decodeTableName(from data: Data) -> String? {
        if data.count == iosBinaryLength {
            let base = data.startIndex
            if let prefix = String(bytes: data[base..<(base + 4)], encoding: .ascii),
               let table = iosTagToTable[prefix],
               decodeIOSRowID(from: data) != nil {
                return table
            }
        }
        if data.count == legacyBinaryLength {
            let base = data.startIndex
            if data[base] == binaryHeader[0],
               data[base + 1] == binaryHeader[1],
               data[base + 2] == binaryHeader[2] {
                return tagToTable[data[base + 3]]
            }
        }
        if let legacyStr = String(data: data, encoding: .utf8), legacyStr.hasPrefix(legacyPrefix) {
            let tail = legacyStr.dropFirst(legacyPrefix.count)
            if let colonIndex = tail.firstIndex(of: ":") {
                let parsed = String(tail[..<colonIndex])
                if tableToTag[parsed] != nil {
                    return parsed
                }
            }
        }
        return nil
    }

    public static func isPersistentRef(_ data: Data) -> Bool {
        if decodeTableName(from: data) != nil {
            return true
        }
        if data.count == legacyBinaryLength {
            let base = data.startIndex
            if data[base] == binaryHeader[0],
               data[base + 1] == binaryHeader[1],
               data[base + 2] == binaryHeader[2],
               (data[base + 3] & 0xF0) == 0x90 {
                return true
            }
        }
        if let legacyStr = String(data: data, encoding: .utf8), legacyStr.hasPrefix(legacyPrefix) {
            return true
        }
        return false
    }
}

public enum PTPlayChainAccessGroupPolicy {
    private static func extractStringValues(from raw: Any?) -> [String] {
        if let arr = raw as? [String] { return arr }
        if let arr = raw as? [Any] { return arr.compactMap { $0 as? String } }
        if let single = raw as? String { return [single] }
        return []
    }

    private static func isValidApplicationGroup(_ group: String) -> Bool {
        guard group.hasPrefix("group."), group.count > "group.".count,
              !group.contains("/"), !group.contains(".."), !group.contains("*"),
              !group.contains("\0"), !group.contains("\n"), !group.contains("\r") else {
            return false
        }
        return !group.contains(where: { $0.isWhitespace })
    }

    public static func expandAccessGroupPatterns(
        fromEntitlements entitlements: [String: Any]?,
        teamID: String,
        bundleID: String
    ) -> [String] {
        let cleanTeam = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        var ordered = [String]()
        var seen = Set<String>()

        func appendUnique(_ candidate: String) {
            if seen.insert(candidate).inserted {
                ordered.append(candidate)
            }
        }

        func appendExpanded(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var expanded = trimmed
            var preserveFakeTeamOriginal = false
            if !cleanTeam.isEmpty {
                expanded = expanded
                    .replacingOccurrences(of: "$(AppIdentifierPrefix)", with: "\(cleanTeam).")
                    .replacingOccurrences(of: "$(TeamIdentifierPrefix)", with: "\(cleanTeam).")
                if expanded.hasPrefix("FAKETEAMID.") {
                    let suffix = expanded.dropFirst("FAKETEAMID.".count)
                    guard !suffix.isEmpty else { return }
                    expanded = "\(cleanTeam).\(suffix)"
                    preserveFakeTeamOriginal = true
                }
            }
            appendUnique(expanded)
            if preserveFakeTeamOriginal {
                appendUnique(trimmed)
            }
        }

        for item in extractStringValues(from: entitlements?["keychain-access-groups"]) {
            appendExpanded(item)
        }
        for appID in extractStringValues(from: entitlements?["application-identifier"]) {
            appendExpanded(appID)
        }
        if !cleanTeam.isEmpty, !cleanBundle.isEmpty {
            appendExpanded("\(cleanTeam).\(cleanBundle)")
        }
        for rawGroup in extractStringValues(from: entitlements?["com.apple.security.application-groups"]) {
            let trimmed = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidApplicationGroup(trimmed) {
                appendUnique(trimmed)
            }
        }
        return ordered
    }

    public static func validate(
        requestedGroup: Any?,
        allowedPatterns: [String],
        isReadOnlyQuery: Bool
    ) -> OSStatus {
        guard let requestedGroup else { return errSecSuccess }
        guard let group = requestedGroup as? String else { return errSecParam }
        if group.isEmpty { return errSecMissingEntitlement }
        if isReadOnlyQuery && group == (kSecAttrAccessGroupToken as String) { return errSecSuccess }
        for rawPattern in allowedPatterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            if pattern == group { return errSecSuccess }
            if pattern.hasSuffix(".*") {
                let prefix = String(pattern.dropLast(1))
                if group.hasPrefix(prefix), group.count > prefix.count { return errSecSuccess }
            }
        }
        return errSecMissingEntitlement
    }
}

public enum PTPlayChainKeyUpdatePolicy {
    public static func isUpdatableColumn(_ column: String, internalTokenIDColumn: String) -> Bool {
        column != internalTokenIDColumn
            && column != (kSecValuePersistentRef as String)
            && column != (kSecAttrCreationDate as String)
    }
}

public struct PTStrictViewportFocusKey: Equatable, Sendable {
    public let sceneID: ObjectIdentifier?
    public let deviceModel: String
    public let scaleMode: String
    public let targetSize: CGSize
    public let screenFrame: CGRect

    public init(
        sceneID: ObjectIdentifier?,
        deviceModel: String,
        scaleMode: String,
        targetSize: CGSize,
        screenFrame: CGRect
    ) {
        self.sceneID = sceneID
        self.deviceModel = deviceModel
        self.scaleMode = scaleMode
        self.targetSize = targetSize
        self.screenFrame = screenFrame
    }
}

public enum PTStrictViewportFocusPolicy {
    public static func shouldApplyContentSizeOnFocus(
        isStrictEmulationMode: Bool,
        lastAppliedFitScreenKey: PTStrictViewportFocusKey?,
        currentKey: PTStrictViewportFocusKey
    ) -> (shouldApply: Bool, nextAppliedFitScreenKey: PTStrictViewportFocusKey?) {
        guard isStrictEmulationMode,
              PTWindowGeometryMath.normalizedStrictScaleMode(currentKey.scaleMode) == "fitScreen" else {
            return (true, nil)
        }
        if lastAppliedFitScreenKey == currentKey {
            return (false, lastAppliedFitScreenKey)
        }
        return (true, currentKey)
    }
}

public enum PTPlayChainMutationFilterPolicy {
    public static func shouldRejectMutation(
        droppedNonMetaFilterKey: Bool,
        hasEffectiveFilter: Bool,
        hasExplicitSecClass: Bool
    ) -> Bool {
        droppedNonMetaFilterKey || (!hasEffectiveFilter && !hasExplicitSecClass)
    }
}

@objc public final class PTPlayChainPolicyBridge: NSObject {
    @objc public static func expandAccessGroupPatterns(
        fromEntitlements entitlements: NSDictionary?,
        teamID: String,
        bundleID: String
    ) -> [String] {
        PTPlayChainAccessGroupPolicy.expandAccessGroupPatterns(
            fromEntitlements: entitlements as? [String: Any],
            teamID: teamID,
            bundleID: bundleID
        )
    }

    @objc public static func validateAccessGroup(
        _ requestedGroup: Any?,
        allowedPatterns: [String],
        isReadOnlyQuery: Bool
    ) -> OSStatus {
        PTPlayChainAccessGroupPolicy.validate(
            requestedGroup: requestedGroup,
            allowedPatterns: allowedPatterns,
            isReadOnlyQuery: isReadOnlyQuery
        )
    }
}

@objc public final class PTPlayChainSecureEnclaveRegistry: NSObject {
    nonisolated(unsafe) private static let seTagObject = NSObject()
    nonisolated(unsafe) private static let seAttrsTagObject = NSObject()

    private static var associationKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(seTagObject).toOpaque())
    }

    private static var persistedAssociationKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(seAttrsTagObject).toOpaque())
    }

    @objc public static func parametersRequestSecureEnclave(_ parameters: NSDictionary?) -> Bool {
        guard let parameters else { return false }
        let seToken = kSecAttrTokenIDSecureEnclave as String
        if let topToken = parameters[kSecAttrTokenID as String] as? String, topToken == seToken {
            return true
        }
        if let privAttrs = parameters[kSecPrivateKeyAttrs as String] as? NSDictionary,
           let privToken = privAttrs[kSecAttrTokenID as String] as? String,
           privToken == seToken {
            return true
        }
        return false
    }

    private static func isPublicKey(_ key: SecKey) -> Bool {
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              let keyClass = attrs[kSecAttrKeyClass as String] as? String else {
            return false
        }
        return keyClass == (kSecAttrKeyClassPublic as String)
    }

    @objc public static func markSecureEnclaveKey(_ key: SecKey?) {
        guard let key, !isPublicKey(key) else { return }
        objc_setAssociatedObject(key, associationKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc public static func isSecureEnclaveKey(_ key: SecKey?) -> Bool {
        guard let key else { return false }
        guard let marked = objc_getAssociatedObject(key, associationKey) as? NSNumber, marked.boolValue else {
            return false
        }
        return !isPublicKey(key)
    }

    @objc(setPersistedAttributes:forKey:)
    public static func setPersistedAttributes(_ attributes: NSDictionary?, for key: SecKey?) {
        guard let key else { return }
        let copied = attributes?.copy() as? NSDictionary
        objc_setAssociatedObject(key, persistedAssociationKey, copied, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc(persistedAttributesForKey:)
    public static func persistedAttributes(for key: SecKey?) -> NSDictionary? {
        guard let key else { return nil }
        return objc_getAssociatedObject(key, persistedAssociationKey) as? NSDictionary
    }
}
