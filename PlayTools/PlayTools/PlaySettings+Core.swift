//
//  PlaySettings+Core.swift
//  PlayTools
//

import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Thread-safe unfair lock wrapper with deterministic cleanup on deinit.
public final class PTUnfairLock {
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock_s>

    public init() {
        lockPtr = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock_s())
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        return try body()
    }
}

@objc public final class PlaySettings: NSObject {
    @objc public static let shared = PlaySettings()

    @objc public let bundleIdentifier: String
    @objc public let settingsUrl: URL

    private let stateLock = PTUnfairLock()
    private let persistenceLock = PTUnfairLock()
    private var _settingsData: AppSettingsData

    var settingsData: AppSettingsData {
        get { stateLock.withLock { _settingsData } }
        set { stateLock.withLock { _settingsData = newValue } }
    }

    private static let internalOverlayTagObject = NSObject()

    @objc(pm_internalOverlayTagKeyAddress)
    public static var internalOverlayTagKeyAddress: UInt {
        UInt(bitPattern: Unmanaged.passUnretained(internalOverlayTagObject).toOpaque())
    }

    @objc public static func resolveHostUserRoot() -> String {
        let rawEnv = getenv("CFFIXED_USER_HOME") ?? getenv("HOME")
        if let rawEnv, let envStr = String(validatingUTF8: rawEnv), envStr.hasPrefix("/") {
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
           let overridePath = String(validatingUTF8: overridePtr),
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
               let cfHome = String(validatingUTF8: cfHomePtr),
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
           let cfHome = String(validatingUTF8: cfHomePtr),
           let marker = cfHome.range(of: "/Library/Containers/") {
            let tail = cfHome[marker.upperBound...]
            let cid = tail.prefix(while: { $0 != "/" })
            if !cid.isEmpty {
                return settingsDir.appendingPathComponent("\(cid).plist")
            }
        }
        return settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
    }

    private static func resolveOEMID(for iosDeviceModel: String) -> NSString {
        switch iosDeviceModel {
        case "iPad6,7":
            return "J98aAP"
        case "iPad8,6":
            return "J320xAP"
        case "iPad13,8":
            return "J522AP"
        case "iPad14,5":
            return "J620AP"
        case "iPad16,6":
            return "J720AP"
        case "iPad17,3":
            return "J820AP"
        case "iPhone12,5":
            return "D431AP"
        case "iPhone14,3":
            return "D64AP"
        case "iPhone15,3":
            return "D74AP"
        case "iPhone16,2":
            return "D84AP"
        case "iPhone17,2":
            return "D94AP"
        case "iPhone18,2":
            return "D94xAP"
        default:
            return "J522AP"
        }
    }

    convenience override init() {
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        self.init(
            settingsURL: Self.resolveSettingsURL(bundleIdentifier: bundleID),
            bundleIdentifier: bundleID
        )
    }

    init(settingsURL: URL, bundleIdentifier: String = "") {
        self.bundleIdentifier = bundleIdentifier
        self.settingsUrl = settingsURL

        let decoded: AppSettingsData
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? PropertyListDecoder().decode(AppSettingsData.self, from: data) {
            decoded = parsed
        } else {
            var defaults = AppSettingsData()
            defaults.bundleIdentifier = bundleIdentifier
            decoded = defaults
        }

        self._settingsData = decoded
        self.discordActivity = decoded.discordActivity
        self.keymapping = decoded.keymapping
        self.notch = decoded.notch
        self.sensitivity = decoded.sensitivity / 100
        self.bypass = decoded.bypass
        self._windowSizeHeight = CGFloat(decoded.windowHeight)
        self._windowSizeWidth = CGFloat(decoded.windowWidth)
        self.configuredInverseScreenValues = decoded.inverseScreenValues
        self.adaptiveDisplay = decoded.resolution != 0
        self.resizableWindow = decoded.resolution == 6
        self.deviceModel = decoded.iosDeviceModel as NSString
        self.oemID = Self.resolveOEMID(for: decoded.iosDeviceModel)
        self.playChain = decoded.playChain
        self.playChainDebugging = decoded.playChainDebugging
        self.configuredWindowFixMethod = decoded.windowFixMethod
        self.configuredCustomScaler = decoded.customScaler
        self.configuredFrameRateTarget = Self.normalizedFrameRateTarget(decoded.frameRateTarget)
        self.configuredReportedIOSVersion = Self.normalizedReportedIOSVersion(decoded.reportedIOSVersion)
        self.rootWorkDir = decoded.rootWorkDir
        self.noKMOnInput = decoded.noKMOnInput
        self.enableScrollWheel = decoded.enableScrollWheel
        self.rightClickLongPress = decoded.rightClickLongPress
        self.hideTitleBar = decoded.hideTitleBar
        self.floatingWindow = decoded.floatingWindow
        self.displayRotation = decoded.displayRotation
        self.checkMicPermissionSync = decoded.checkMicPermissionSync
        self.limitMotionUpdateFrequency = decoded.limitMotionUpdateFrequency
        self.disableBuiltinMouse = decoded.disableBuiltinMouse
        self.blockSleepSpamming = decoded.blockSleepSpamming
        self.ignoreUnityKeyboardInitializationError = decoded.ignoreUnityKeyboardInitializationError

        super.init()
    }

    let discordActivity: DiscordActivity

    @objc public var discordActivityEnabled: Bool {
        discordActivity.enable
    }

    @objc public let keymapping: Bool

    @objc public let notch: Bool

    @objc public let sensitivity: Float

    @objc public let bypass: Bool

    private var _windowSizeHeight: CGFloat
    @objc public var windowSizeHeight: CGFloat {
        get { stateLock.withLock { _windowSizeHeight } }
        set { stateLock.withLock { _windowSizeHeight = newValue } }
    }

    private var _windowSizeWidth: CGFloat
    @objc public var windowSizeWidth: CGFloat {
        get { stateLock.withLock { _windowSizeWidth } }
        set { stateLock.withLock { _windowSizeWidth = newValue } }
    }

    private let configuredInverseScreenValues: Bool
    @objc public var inverseScreenValues: Bool {
        PTSafeMode.isActive ? false : configuredInverseScreenValues
    }

    @objc public let adaptiveDisplay: Bool

    @objc public let resizableWindow: Bool

    @objc public let deviceModel: NSString

    @objc public let oemID: NSString

    @objc public var keymappingDisabledAt: Float {
        get {
            stateLock.withLock { _settingsData.keymappingDisabledAt }
        }
        set {
            let snapshot: AppSettingsData = stateLock.withLock {
                _settingsData.keymappingDisabledAt = newValue
                return _settingsData
            }
            saveKeymappingDisabledAt(newValue, fallbackSnapshot: snapshot)
        }
    }

    private func saveKeymappingDisabledAt(_ value: Float, fallbackSnapshot: AppSettingsData) {
        persistenceLock.withLock {
            let parentDir = settingsUrl.deletingLastPathComponent()
            let outData: Data
            if let data = try? Data(contentsOf: settingsUrl),
               var plistDict = (try? PropertyListSerialization.propertyList(
                   from: data, options: [], format: nil
               )) as? [String: Any] {
                plistDict["keymappingDisabledAt"] = NSNumber(value: value)
                guard let serialized = try? PropertyListSerialization.data(
                    fromPropertyList: plistDict, format: .xml, options: 0
                ) else {
                    return
                }
                outData = serialized
            } else {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .xml
                guard let encoded = try? encoder.encode(fallbackSnapshot) else {
                    return
                }
                outData = encoded
            }

            do {
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true
                    )
                }
                // Write to <BundleID>.plist.tmp + rename so host SBPL
                // `(prefix ".../App Settings/${BundleID}.plist")` permits atomic replacement
                // without Foundation `.dat.nosync` temp files.
                let tmpURL = settingsUrl.appendingPathExtension("tmp")
                try outData.write(to: tmpURL, options: [])
                if Darwin.rename(tmpURL.path, settingsUrl.path) != 0 {
                    try? FileManager.default.removeItem(at: tmpURL)
                    try outData.write(to: settingsUrl, options: [])
                }
            } catch {
                // Best-effort persistence inside PlayCover App Settings
            }
        }
    }

    @objc public let playChain: Bool

    @objc public let playChainDebugging: Bool

    private let configuredWindowFixMethod: Int
    @objc public var windowFixMethod: Int {
        PTSafeMode.isActive ? 0 : configuredWindowFixMethod
    }

    private let configuredCustomScaler: Double
    @objc public var customScaler: Double {
        PTSafeMode.isActive ? 1.0 : configuredCustomScaler
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

    private static func normalizedReportedIOSVersion(_ raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "followhost", "follow_host", "host":
            return "followHost"
        case "compat18_3", "18.3", "ios18_3":
            return "compat18_3"
        case "compat13_7", "13.7", "ios13_7":
            return "compat13_7"
        default:
            return "automatic"
        }
    }

    @objc public let rootWorkDir: Bool

    @objc public let noKMOnInput: Bool

    @objc public let enableScrollWheel: Bool

    @objc public let rightClickLongPress: Bool

    @objc public let hideTitleBar: Bool

    @objc public let floatingWindow: Bool

    @objc public let displayRotation: Int

    @objc public let checkMicPermissionSync: Bool

    @objc public let limitMotionUpdateFrequency: Bool

    @objc public let disableBuiltinMouse: Bool

    @objc public let blockSleepSpamming: Bool

    @objc public let ignoreUnityKeyboardInitializationError: Bool
}

struct AppSettingsData: Codable, Equatable {
    var bundleIdentifier: String = ""
    var originalBundleName: String?
    var originalMinimumOSVersion: String?

    var keymapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var displayRotation = 0
    var iosDeviceModel = "iPad13,8"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 1
    var aspectRatio = 1
    var notch = false
    var bypass = true
    var discordActivity = DiscordActivity()
    var version = "3.0.0"
    var playChain = true
    var playChainDebugging = false
    var inverseScreenValues = false
    var metalHUD = false
    var windowFixMethod = 0
    var injectIntrospection = false
    var rootWorkDir = true
    var noKMOnInput = true
    var enableScrollWheel = true
    var rightClickLongPress = true
    var hideTitleBar = false
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
    var ignoreUnityKeyboardInitializationError = false
    var enableNetworkRules = false
    var networkBlockMock200 = true
    var blockedURLPatterns: [String] = []
    var keymappingDisabledAt: Float = 0
    var frameRateTarget: String = "adaptive"
    var reportedIOSVersion: String = "automatic"

    init() {}

    private static func decodeDouble<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: Double
    ) -> Double {
        if let val = try? container.decodeIfPresent(Double.self, forKey: key) {
            return val
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intVal)
        }
        return defaultValue
    }

    private static func decodeFloat<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: Float
    ) -> Float {
        if let val = try? container.decodeIfPresent(Float.self, forKey: key) {
            return val
        }
        if let dblVal = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Float(dblVal)
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Float(intVal)
        }
        return defaultValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = (try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        originalBundleName = (try? container.decodeIfPresent(String.self, forKey: .originalBundleName)) ?? nil
        originalMinimumOSVersion = (try? container.decodeIfPresent(String.self, forKey: .originalMinimumOSVersion)) ?? nil
        keymapping = (try? container.decodeIfPresent(Bool.self, forKey: .keymapping)) ?? true
        sensitivity = Self.decodeFloat(from: container, forKey: .sensitivity, default: 50)
        disableTimeout = (try? container.decodeIfPresent(Bool.self, forKey: .disableTimeout)) ?? false
        displayRotation = (try? container.decodeIfPresent(Int.self, forKey: .displayRotation)) ?? 0
        iosDeviceModel = (try? container.decodeIfPresent(String.self, forKey: .iosDeviceModel)) ?? "iPad13,8"
        windowWidth = (try? container.decodeIfPresent(Int.self, forKey: .windowWidth)) ?? 1920
        windowHeight = (try? container.decodeIfPresent(Int.self, forKey: .windowHeight)) ?? 1080
        customScaler = Self.decodeDouble(from: container, forKey: .customScaler, default: 2.0)
        resolution = (try? container.decodeIfPresent(Int.self, forKey: .resolution)) ?? 1
        aspectRatio = (try? container.decodeIfPresent(Int.self, forKey: .aspectRatio)) ?? 1
        notch = (try? container.decodeIfPresent(Bool.self, forKey: .notch)) ?? false
        bypass = (try? container.decodeIfPresent(Bool.self, forKey: .bypass)) ?? true
        discordActivity = (try? container.decodeIfPresent(
            DiscordActivity.self,
            forKey: .discordActivity
        )) ?? DiscordActivity()
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? "3.0.0"
        playChain = (try? container.decodeIfPresent(Bool.self, forKey: .playChain)) ?? true
        playChainDebugging = (try? container.decodeIfPresent(Bool.self, forKey: .playChainDebugging)) ?? false
        inverseScreenValues = (try? container.decodeIfPresent(Bool.self, forKey: .inverseScreenValues)) ?? false
        metalHUD = (try? container.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? false
        windowFixMethod = (try? container.decodeIfPresent(Int.self, forKey: .windowFixMethod)) ?? 0
        injectIntrospection = (try? container.decodeIfPresent(Bool.self, forKey: .injectIntrospection)) ?? false
        rootWorkDir = (try? container.decodeIfPresent(Bool.self, forKey: .rootWorkDir)) ?? true
        noKMOnInput = (try? container.decodeIfPresent(Bool.self, forKey: .noKMOnInput)) ?? true
        enableScrollWheel = (try? container.decodeIfPresent(Bool.self, forKey: .enableScrollWheel)) ?? true
        rightClickLongPress = (try? container.decodeIfPresent(Bool.self, forKey: .rightClickLongPress)) ?? true
        hideTitleBar = (try? container.decodeIfPresent(Bool.self, forKey: .hideTitleBar)) ?? false
        floatingWindow = (try? container.decodeIfPresent(Bool.self, forKey: .floatingWindow)) ?? false
        checkMicPermissionSync = (try? container.decodeIfPresent(Bool.self, forKey: .checkMicPermissionSync)) ?? false
        limitMotionUpdateFrequency = (try? container.decodeIfPresent(
            Bool.self,
            forKey: .limitMotionUpdateFrequency
        )) ?? false
        disableBuiltinMouse = (try? container.decodeIfPresent(Bool.self, forKey: .disableBuiltinMouse)) ?? false
        resizableAspectRatioType = (try? container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioType)) ?? 0
        resizableAspectRatioWidth = (try? container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioWidth)) ?? 0
        resizableAspectRatioHeight = (try? container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioHeight)) ?? 0
        blockSleepSpamming = (try? container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming)) ?? false
        ignoreUnityKeyboardInitializationError = (try? container.decodeIfPresent(
            Bool.self,
            forKey: .ignoreUnityKeyboardInitializationError
        )) ?? false
        enableNetworkRules = (try? container.decodeIfPresent(Bool.self, forKey: .enableNetworkRules)) ?? false
        networkBlockMock200 = (try? container.decodeIfPresent(Bool.self, forKey: .networkBlockMock200)) ?? true
        blockedURLPatterns = (try? container.decodeIfPresent([String].self, forKey: .blockedURLPatterns)) ?? []
        keymappingDisabledAt = Self.decodeFloat(from: container, forKey: .keymappingDisabledAt, default: 0)
        frameRateTarget = (try? container.decodeIfPresent(String.self, forKey: .frameRateTarget)) ?? "adaptive"
        reportedIOSVersion = (try? container.decodeIfPresent(String.self, forKey: .reportedIOSVersion)) ?? "automatic"
    }
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
