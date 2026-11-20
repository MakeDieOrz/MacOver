//
//  AppSettings.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 07.12.2021.
//

import AppKit
import Combine
import Foundation
import PlayCoverCore
import UniformTypeIdentifiers

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
    var notch: Bool = NSScreen.hasNotch()
    var bypass = true
    var discordActivity = DiscordActivity()
    var version = "3.0.0"
    var playChain = true
    var playChainDebugging = false
    var inverseScreenValues = false
    var metalHUD = false
    var windowFixMethod = 0
    /// Deprecated/unused legacy plist key retained for Codable compatibility; actual
    /// introspection library injection uses `Info.plist` `LSEnvironment` (`PlayApp.introspection`).
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
    var frameRateTarget: String = FrameRateTarget.adaptive.rawValue
    var reportedIOSVersion: String = ReportedIOSVersionMode.automatic.rawValue

    init() {}

    // handle old 2.x settings where PlayChain did not exist yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = (try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        originalBundleName = try? container.decodeIfPresent(String.self, forKey: .originalBundleName)
        originalMinimumOSVersion = try? container.decodeIfPresent(String.self, forKey: .originalMinimumOSVersion)
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
        notch = (try? container.decodeIfPresent(Bool.self, forKey: .notch)) ?? NSScreen.hasNotch()
        bypass = (try? container.decodeIfPresent(Bool.self, forKey: .bypass)) ?? true
        discordActivity = (try? container.decodeIfPresent(
            DiscordActivity.self, forKey: .discordActivity
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
            Bool.self, forKey: .limitMotionUpdateFrequency
        )) ?? false
        disableBuiltinMouse = (try? container.decodeIfPresent(Bool.self, forKey: .disableBuiltinMouse)) ?? false
        resizableAspectRatioType = (try? container.decodeIfPresent(
            Int.self, forKey: .resizableAspectRatioType
        )) ?? 0
        resizableAspectRatioWidth = (try? container.decodeIfPresent(
            Int.self, forKey: .resizableAspectRatioWidth
        )) ?? 0
        resizableAspectRatioHeight = (try? container.decodeIfPresent(
            Int.self, forKey: .resizableAspectRatioHeight
        )) ?? 0
        blockSleepSpamming = (try? container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming)) ?? false
        ignoreUnityKeyboardInitializationError = (try? container.decodeIfPresent(
            Bool.self, forKey: .ignoreUnityKeyboardInitializationError
        )) ?? false
        enableNetworkRules = (try? container.decodeIfPresent(Bool.self, forKey: .enableNetworkRules)) ?? false
        networkBlockMock200 = (try? container.decodeIfPresent(Bool.self, forKey: .networkBlockMock200)) ?? true
        blockedURLPatterns = (try? container.decodeIfPresent([String].self, forKey: .blockedURLPatterns)) ?? []
        keymappingDisabledAt = Self.decodeFloat(from: container, forKey: .keymappingDisabledAt, default: 0)
        frameRateTarget = FrameRateTarget(
            rawSetting: try? container.decodeIfPresent(String.self, forKey: .frameRateTarget)
        ).rawValue
        reportedIOSVersion = ReportedIOSVersionMode(
            rawSetting: try? container.decodeIfPresent(String.self, forKey: .reportedIOSVersion)
        ).rawValue
    }

    private static func decodeFloat<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: Float
    ) -> Float {
        if let value = try? container.decodeIfPresent(Float.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Float(value)
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Float(value)
        }
        return defaultValue
    }

    private static func decodeDouble<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: Double
    ) -> Double {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Float.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        return defaultValue
    }

    var windowCompatibility: WindowCompatibilityMode {
        get {
            WindowCompatibilityMode(inverseScreenValues: inverseScreenValues, windowFixMethod: windowFixMethod)
        }
        set {
            let legacy = newValue.legacyValues
            inverseScreenValues = legacy.inverseScreenValues
            windowFixMethod = legacy.windowFixMethod
            if newValue.requiresAdaptiveResolutionOff {
                resolution = 0
            }
        }
    }

    var frameRateTargetMode: FrameRateTarget {
        get { FrameRateTarget(rawSetting: frameRateTarget) }
        set { frameRateTarget = newValue.rawValue }
    }

    var reportedIOSVersionMode: ReportedIOSVersionMode {
        get { ReportedIOSVersionMode(rawSetting: reportedIOSVersion) }
        set { reportedIOSVersion = newValue.rawValue }
    }

    var pixelBudget: PixelBudget {
        PixelBudget(width: windowWidth, height: windowHeight, scaler: customScaler)
    }

    func restartRequiredChanges(comparedTo snapshot: AppSettingsData) -> [PlayCoverRestartField] {
        var changed: [PlayCoverRestartField] = []
        if iosDeviceModel != snapshot.iosDeviceModel { changed.append(.iosDeviceModel) }
        if resolution != snapshot.resolution { changed.append(.resolution) }
        if windowWidth != snapshot.windowWidth ||
            windowHeight != snapshot.windowHeight ||
            resizableAspectRatioType != snapshot.resizableAspectRatioType ||
            resizableAspectRatioWidth != snapshot.resizableAspectRatioWidth ||
            resizableAspectRatioHeight != snapshot.resizableAspectRatioHeight {
            changed.append(.windowSize)
        }
        if aspectRatio != snapshot.aspectRatio { changed.append(.aspectRatio) }
        if customScaler != snapshot.customScaler { changed.append(.customScaler) }
        if windowCompatibility != snapshot.windowCompatibility { changed.append(.windowCompatibility) }
        if frameRateTargetMode != snapshot.frameRateTargetMode { changed.append(.frameRateTarget) }
        if reportedIOSVersionMode != snapshot.reportedIOSVersionMode { changed.append(.reportedIOSVersion) }
        if notch != snapshot.notch { changed.append(.notch) }
        if bypass != snapshot.bypass { changed.append(.bypass) }
        if playChain != snapshot.playChain { changed.append(.playChain) }
        if playChainDebugging != snapshot.playChainDebugging { changed.append(.playChainDebugging) }
        if metalHUD != snapshot.metalHUD { changed.append(.metalHUD) }
        // `injectIntrospection` is a deprecated/unused legacy plist field with no runtime consumer.
        if rootWorkDir != snapshot.rootWorkDir { changed.append(.rootWorkDir) }
        if hideTitleBar != snapshot.hideTitleBar { changed.append(.hideTitleBar) }
        if floatingWindow != snapshot.floatingWindow { changed.append(.floatingWindow) }
        if enableNetworkRules != snapshot.enableNetworkRules { changed.append(.enableNetworkRules) }
        if blockedURLPatterns != snapshot.blockedURLPatterns { changed.append(.blockedURLPatterns) }
        if keymapping != snapshot.keymapping || rightClickLongPress != snapshot.rightClickLongPress {
            changed.append(.keymapping)
        }
        if disableBuiltinMouse != snapshot.disableBuiltinMouse { changed.append(.disableBuiltinMouse) }
        if blockSleepSpamming != snapshot.blockSleepSpamming { changed.append(.blockSleepSpamming) }
        if ignoreUnityKeyboardInitializationError != snapshot.ignoreUnityKeyboardInitializationError {
            changed.append(.ignoreUnityKeyboardInitializationError)
        }
        return changed
    }
}

class AppSettings: ObservableObject {
    static var appSettingsDir: URL {
        let settingsFolder =
            PlayTools.playCoverContainer.appendingPathComponent("App Settings")
        if !FileManager.default.fileExists(atPath: settingsFolder.path) {
            do {
                try FileManager.default.createDirectory(at: settingsFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
        return settingsFolder
    }

    let info: AppInfo
    let settingsUrl: URL
    var openWithLLDB: Bool = false {
        didSet { notifyChangedOnMain() }
    }
    var openLLDBWithTerminal: Bool = true {
        didSet { notifyChangedOnMain() }
    }
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "app.makedie.MacOver.AppSettings.io", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var hasPendingWrite = false
    let debounceInterval: TimeInterval
    private var suppressPersistence = false
    private var isResetting = false
    private var _settings: AppSettingsData

    private func notifyChangedOnMain() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    var settings: AppSettingsData {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _settings
        }
        set {
            var didChange = false
            var metalHUDToApply: (bundleID: String, enabled: Bool)?
            lock.lock()
            let previous = _settings
            _settings = newValue
            if newValue != previous {
                didChange = true
                if !suppressPersistence {
                    if previous.metalHUD != newValue.metalHUD && !newValue.bundleIdentifier.isEmpty {
                        metalHUDToApply = (newValue.bundleIdentifier, newValue.metalHUD)
                    }
                    scheduleDebouncedWriteLocked()
                }
            }
            lock.unlock()

            if didChange {
                notifyChangedOnMain()
            }
            if let hud = metalHUDToApply {
                Task.detached(priority: .utility) {
                    do {
                        try Shell.setMetalHUD(hud.bundleID, enabled: hud.enabled)
                    } catch {
                        PlayCoverDiagnostics.reportError(error)
                    }
                }
            }
        }
    }

    convenience init(_ info: AppInfo) {
        let url = AppSettings.appSettingsDir
            .appendingEscapedPathComponent(info.bundleIdentifier)
            .appendingPathExtension("plist")
        self.init(settingsUrl: url, info: info, debounceInterval: 0.5)
    }

    init(settingsUrl: URL, info: AppInfo, debounceInterval: TimeInterval = 0.5) {
        self.info = info
        self.settingsUrl = settingsUrl
        self.debounceInterval = debounceInterval
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        _settings = defaults

        if !decode() {
            preserveUnreadableSettingsIfPresent()
            encode()
        } else if settings.bundleIdentifier != info.bundleIdentifier {
            update { $0.bundleIdentifier = info.bundleIdentifier }
            _ = flush()
        }
    }

    deinit {
        _ = flush()
    }

    func update(_ mutate: (inout AppSettingsData) -> Void) {
        var metalHUDToApply: (bundleID: String, enabled: Bool)?
        lock.lock()
        let previous = _settings
        var updated = _settings
        mutate(&updated)
        guard updated != previous else {
            lock.unlock()
            return
        }
        _settings = updated
        if !suppressPersistence {
            if previous.metalHUD != updated.metalHUD && !updated.bundleIdentifier.isEmpty {
                metalHUDToApply = (updated.bundleIdentifier, updated.metalHUD)
            }
            scheduleDebouncedWriteLocked()
        }
        lock.unlock()

        notifyChangedOnMain()

        if let hud = metalHUDToApply {
            Task.detached(priority: .utility) {
                do {
                    try Shell.setMetalHUD(hud.bundleID, enabled: hud.enabled)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }
        }
    }

    private func scheduleDebouncedWriteLocked() {
        hasPendingWrite = true
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performScheduledWrite()
        }
        pendingSaveWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func performScheduledWrite() {
        lock.lock()
        defer { lock.unlock() }
        guard hasPendingWrite else { return }
        pendingSaveWorkItem = nil
        _ = encodeLocked()
        hasPendingWrite = false
    }

    @discardableResult
    public func flush() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard hasPendingWrite else { return true }
        let ok = encodeLocked()
        hasPendingWrite = false
        return ok
    }

    public func sync() {
        let hasNotch = NSScreen.hasNotch()
        let autoRes = AppSettings.autoResolution()
        update { updatedSettings in
            updatedSettings.notch = hasNotch
            if updatedSettings.resolution == 1 {
                updatedSettings.windowWidth = autoRes.width
                updatedSettings.windowHeight = autoRes.height
            }
        }
    }

    static func autoResolution() -> (width: Int, height: Int) {
        let width = Int(NSScreen.main?.frame.width ?? 1920)
        let height = Int(NSScreen.main?.frame.height ?? 1080)
        let wFloat = Float(width)
        let hFloat = Float(height)
        if NSScreen.hasNotch() && (hFloat/wFloat)*16.0 > 10.3 && (hFloat/wFloat)*16.0 < 10.4 {
            return (width, Int((wFloat / 16) * 10))
        } else {
            return (width, height)
        }
    }

    public func reset() {
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        var metalHUDToApply: (bundleID: String, enabled: Bool)?
        lock.lock()
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        hasPendingWrite = false
        let previous = _settings
        isResetting = true
        defer { isResetting = false }
        _settings = defaults
        if previous.metalHUD != defaults.metalHUD && !defaults.bundleIdentifier.isEmpty {
            metalHUDToApply = (defaults.bundleIdentifier, defaults.metalHUD)
        }
        _ = encodeLocked()
        lock.unlock()

        notifyChangedOnMain()

        if let hud = metalHUDToApply {
            Task.detached(priority: .utility) {
                do {
                    try Shell.setMetalHUD(hud.bundleID, enabled: hud.enabled)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }
        }
    }

    @discardableResult
    public func decode() -> Bool {
        lock.lock()
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        hasPendingWrite = false
        do {
            let data = try Data(contentsOf: settingsUrl)
            let decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
            suppressPersistence = true
            _settings = decoded
            suppressPersistence = false
            lock.unlock()
            notifyChangedOnMain()
            return true
        } catch {
            suppressPersistence = false
            lock.unlock()
            if FileManager.default.fileExists(atPath: settingsUrl.path) {
                PlayCoverDiagnostics.log(
                    "App settings decode failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                    isError: true
                )
            }
            return false
        }
    }

    @discardableResult
    public func encode() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        hasPendingWrite = false
        return encodeLocked()
    }

    @discardableResult
    private func encodeLocked() -> Bool {
        var snapshot = _settings
        var diskDict: [String: Any]?

        if !isResetting,
           let diskData = try? Data(contentsOf: settingsUrl),
           let plist = try? PropertyListSerialization.propertyList(
               from: diskData, options: [], format: nil
           ) as? [String: Any] {
            diskDict = plist
            if let diskDisabledAt = plist["keymappingDisabledAt"] as? NSNumber {
                let diskValue = diskDisabledAt.floatValue
                if snapshot.keymappingDisabledAt != diskValue {
                    snapshot.keymappingDisabledAt = diskValue
                    _settings.keymappingDisabledAt = diskValue
                }
            }
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let encodedData = try encoder.encode(snapshot)
            let outputData: Data
            if !isResetting,
               var merged = diskDict,
               let encodedDict = try PropertyListSerialization.propertyList(
                   from: encodedData, options: [], format: nil
               ) as? [String: Any] {
                for (key, value) in encodedDict {
                    merged[key] = value
                }
                if snapshot.originalBundleName == nil {
                    merged.removeValue(forKey: "originalBundleName")
                }
                if snapshot.originalMinimumOSVersion == nil {
                    merged.removeValue(forKey: "originalMinimumOSVersion")
                }
                outputData = try PropertyListSerialization.data(
                    fromPropertyList: merged, format: .xml, options: 0
                )
            } else {
                outputData = encodedData
            }
            try outputData.write(to: settingsUrl, options: .atomic)
            return true
        } catch {
            PlayCoverDiagnostics.log(
                "App settings write failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    private func preserveUnreadableSettingsIfPresent() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsUrl.path) else { return }
        let backupURL = settingsUrl.appendingPathExtension("bak")
        do {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: settingsUrl, to: backupURL)
            PlayCoverDiagnostics.log("Preserved unreadable app settings at \(backupURL.path)", isError: true)
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to preserve unreadable app settings for \(info.bundleIdentifier): " +
                    error.localizedDescription,
                isError: true
            )
        }
    }
}

extension NSScreen {
    public static func hasNotch() -> Bool {
        // check if any of the connected screens contains a notch
        return NSScreen.screens.contains { $0.safeAreaInsets.top != 0 }
    }

    private static func getMacModel() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var modelIdentifier: String?

        if let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)
            .takeRetainedValue() as? Data {
            if let modelIdentifierCString = String(data: modelData, encoding: .utf8)?.cString(using: .utf8) {
                modelIdentifier = String(cString: modelIdentifierCString)
            }
        }
        IOObjectRelease(service)
        return modelIdentifier
    }
}
