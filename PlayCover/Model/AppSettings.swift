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
    var interceptInlineSyscalls = false
    var enableNetworkRules = false
    var networkBlockMock200 = true
    var blockedURLPatterns: [String] = []
    var networkProxyMode: String = "direct"
    var externalProxyProtocol: String = "http"
    var externalProxyHost: String = "127.0.0.1"
    var externalProxyPort: Int = 8888
    var mitmPort: Int = 0
    var mitmRuntimePort: Int = 0
    var enableCustomCertificates: Bool = false
    var mitmAllHosts: Bool = true
    var mitmHostPatterns: [String] = []
    var mitmAllowPinningBypass: Bool = false
    var hideProxyFromApp: Bool = true
    var mitmCaptureBodies: Bool = true
    var keymappingDisabledAt: Float = 0
    var frameRateTarget: String = FrameRateTarget.adaptive.rawValue
    var reportedIOSVersion: String = ReportedIOSVersionMode.automatic.rawValue
    var strictEmulationMode = false
    var strictViewportOrientation: StrictViewportOrientation = .landscape
    var strictViewportScaleMode: StrictViewportScaleMode = .fitScreen
    var storedHasIntrospection = false
    var storedHasIosFrameworks = false

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
        interceptInlineSyscalls = (try? container.decodeIfPresent(
            Bool.self, forKey: .interceptInlineSyscalls
        )) ?? false
        enableNetworkRules = (try? container.decodeIfPresent(Bool.self, forKey: .enableNetworkRules)) ?? false
        networkBlockMock200 = (try? container.decodeIfPresent(Bool.self, forKey: .networkBlockMock200)) ?? true
        blockedURLPatterns = (try? container.decodeIfPresent([String].self, forKey: .blockedURLPatterns)) ?? []
        networkProxyMode = (try? container.decodeIfPresent(String.self, forKey: .networkProxyMode)) ?? "direct"
        externalProxyProtocol = (try? container.decodeIfPresent(String.self, forKey: .externalProxyProtocol)) ?? "http"
        externalProxyHost = (try? container.decodeIfPresent(String.self, forKey: .externalProxyHost)) ?? "127.0.0.1"
        externalProxyPort = (try? container.decodeIfPresent(Int.self, forKey: .externalProxyPort)) ?? 8888
        mitmPort = (try? container.decodeIfPresent(Int.self, forKey: .mitmPort)) ?? 0
        mitmRuntimePort = (try? container.decodeIfPresent(Int.self, forKey: .mitmRuntimePort)) ?? 0
        enableCustomCertificates = (try? container.decodeIfPresent(
            Bool.self, forKey: .enableCustomCertificates
        )) ?? false
        mitmAllHosts = (try? container.decodeIfPresent(Bool.self, forKey: .mitmAllHosts)) ?? true
        mitmHostPatterns = (try? container.decodeIfPresent([String].self, forKey: .mitmHostPatterns)) ?? []
        mitmAllowPinningBypass = (try? container.decodeIfPresent(
            Bool.self, forKey: .mitmAllowPinningBypass
        )) ?? false
        hideProxyFromApp = (try? container.decodeIfPresent(Bool.self, forKey: .hideProxyFromApp)) ?? true
        mitmCaptureBodies = (try? container.decodeIfPresent(Bool.self, forKey: .mitmCaptureBodies)) ?? true
        keymappingDisabledAt = Self.decodeFloat(from: container, forKey: .keymappingDisabledAt, default: 0)
        frameRateTarget = FrameRateTarget(
            rawSetting: try? container.decodeIfPresent(String.self, forKey: .frameRateTarget)
        ).rawValue
        reportedIOSVersion = ReportedIOSVersionMode(
            rawSetting: try? container.decodeIfPresent(String.self, forKey: .reportedIOSVersion)
        ).rawValue
        strictEmulationMode = (try? container.decodeIfPresent(Bool.self, forKey: .strictEmulationMode)) ?? false
        strictViewportOrientation = StrictViewportOrientation(
            rawSetting: try? container.decodeIfPresent(String.self, forKey: .strictViewportOrientation)
        )
        strictViewportScaleMode = StrictViewportScaleMode(
            rawSetting: try? container.decodeIfPresent(String.self, forKey: .strictViewportScaleMode)
        )
        storedHasIntrospection = (try? container.decodeIfPresent(Bool.self, forKey: .storedHasIntrospection)) ?? false
        storedHasIosFrameworks = (try? container.decodeIfPresent(Bool.self, forKey: .storedHasIosFrameworks)) ?? false
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

    var effectiveIOSDeviceModel: String {
        ReportedIOSVersionMode.effectiveDeviceModel(iosDeviceModel, for: reportedIOSVersionMode)
    }

    var strictDeviceDisplaySpec: StrictDeviceDisplaySpec {
        StrictDeviceDisplaySpec.resolve(for: effectiveIOSDeviceModel)
    }

    var effectiveBypass: Bool {
        strictEmulationMode ? true : bypass
    }

    var effectiveInterceptInlineSyscalls: Bool {
        strictEmulationMode ? true : interceptInlineSyscalls
    }

    var effectiveRootWorkDir: Bool {
        strictEmulationMode ? true : rootWorkDir
    }

    var effectiveMetalHUD: Bool {
        strictEmulationMode ? false : metalHUD
    }

    var effectivePlayChainDebugging: Bool {
        strictEmulationMode ? false : playChainDebugging
    }

    var effectiveNotch: Bool {
        strictEmulationMode ? false : notch
    }

    func effectiveHasIntrospection(_ storedHasIntrospection: Bool) -> Bool {
        strictEmulationMode ? false : storedHasIntrospection
    }

    func effectiveOpenWithLLDB(_ storedOpenWithLLDB: Bool) -> Bool {
        strictEmulationMode ? false : storedOpenWithLLDB
    }

    var effectiveCustomScaler: Double {
        strictEmulationMode ? strictDeviceDisplaySpec.nativeScale : customScaler
    }

    var effectiveLogicalWindowSize: (width: Int, height: Int) {
        if strictEmulationMode {
            return strictDeviceDisplaySpec.logicalSize(orientation: strictViewportOrientation)
        }
        return (windowWidth, windowHeight)
    }

    var effectiveWindowWidth: Int {
        effectiveLogicalWindowSize.width
    }

    var effectiveWindowHeight: Int {
        effectiveLogicalWindowSize.height
    }

    var effectiveResolution: Int {
        strictEmulationMode ? 5 : resolution
    }

    var effectiveWindowCompatibility: WindowCompatibilityMode {
        strictEmulationMode ? .standard : windowCompatibility
    }

    var effectiveDisplayRotation: Int {
        strictEmulationMode ? strictViewportOrientation.displayRotationTag : displayRotation
    }

    func effectivePixelBudget(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> PixelBudget {
        PixelBudget(
            width: effectiveWindowWidth,
            height: effectiveWindowHeight,
            scaler: effectiveCustomScaler,
            physicalMemoryBytes: physicalMemoryBytes
        )
    }

    var pixelBudget: PixelBudget {
        effectivePixelBudget()
    }

    func restartRequiredChanges(comparedTo snapshot: AppSettingsData) -> [PlayCoverRestartField] {
        var changed: [PlayCoverRestartField] = []
        if iosDeviceModel != snapshot.iosDeviceModel { changed.append(.iosDeviceModel) }
        if effectiveResolution != snapshot.effectiveResolution { changed.append(.resolution) }
        if strictEmulationMode != snapshot.strictEmulationMode {
            changed.append(.strictEmulationMode)
        }
        if strictEmulationMode || snapshot.strictEmulationMode {
            if strictViewportOrientation != snapshot.strictViewportOrientation {
                changed.append(.strictViewportOrientation)
            }
            if strictViewportScaleMode != snapshot.strictViewportScaleMode {
                changed.append(.strictViewportScaleMode)
            }
        }
        if effectiveWindowWidth != snapshot.effectiveWindowWidth ||
            effectiveWindowHeight != snapshot.effectiveWindowHeight ||
            (!strictEmulationMode && !snapshot.strictEmulationMode && (
                resizableAspectRatioType != snapshot.resizableAspectRatioType ||
                resizableAspectRatioWidth != snapshot.resizableAspectRatioWidth ||
                resizableAspectRatioHeight != snapshot.resizableAspectRatioHeight
            )) {
            changed.append(.windowSize)
        }
        if !strictEmulationMode && !snapshot.strictEmulationMode && aspectRatio != snapshot.aspectRatio {
            changed.append(.aspectRatio)
        }
        if effectiveCustomScaler != snapshot.effectiveCustomScaler { changed.append(.customScaler) }
        if effectiveWindowCompatibility != snapshot.effectiveWindowCompatibility {
            changed.append(.windowCompatibility)
        }
        if frameRateTargetMode != snapshot.frameRateTargetMode { changed.append(.frameRateTarget) }
        if reportedIOSVersionMode != snapshot.reportedIOSVersionMode { changed.append(.reportedIOSVersion) }
        if effectiveNotch != snapshot.effectiveNotch { changed.append(.notch) }
        if effectiveBypass != snapshot.effectiveBypass { changed.append(.bypass) }
        if playChain != snapshot.playChain { changed.append(.playChain) }
        if effectivePlayChainDebugging != snapshot.effectivePlayChainDebugging {
            changed.append(.playChainDebugging)
        }
        if effectiveMetalHUD != snapshot.effectiveMetalHUD { changed.append(.metalHUD) }
        if effectiveHasIntrospection(storedHasIntrospection)
            != snapshot.effectiveHasIntrospection(snapshot.storedHasIntrospection) {
            changed.append(.injectIntrospection)
        }
        if effectiveRootWorkDir != snapshot.effectiveRootWorkDir { changed.append(.rootWorkDir) }
        if hideTitleBar != snapshot.hideTitleBar { changed.append(.hideTitleBar) }
        if floatingWindow != snapshot.floatingWindow { changed.append(.floatingWindow) }
        if enableNetworkRules != snapshot.enableNetworkRules { changed.append(.enableNetworkRules) }
        if blockedURLPatterns != snapshot.blockedURLPatterns { changed.append(.blockedURLPatterns) }
        if networkProxyMode != snapshot.networkProxyMode ||
            externalProxyProtocol != snapshot.externalProxyProtocol ||
            externalProxyHost != snapshot.externalProxyHost ||
            externalProxyPort != snapshot.externalProxyPort ||
            mitmPort != snapshot.mitmPort {
            changed.append(.networkProxy)
        }
        if keymapping != snapshot.keymapping || rightClickLongPress != snapshot.rightClickLongPress {
            changed.append(.keymapping)
        }
        if disableBuiltinMouse != snapshot.disableBuiltinMouse { changed.append(.disableBuiltinMouse) }
        if blockSleepSpamming != snapshot.blockSleepSpamming { changed.append(.blockSleepSpamming) }
        if ignoreUnityKeyboardInitializationError != snapshot.ignoreUnityKeyboardInitializationError {
            changed.append(.ignoreUnityKeyboardInitializationError)
        }
        if effectiveInterceptInlineSyscalls != snapshot.effectiveInterceptInlineSyscalls {
            changed.append(.interceptInlineSyscalls)
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
    var effectiveOpenWithLLDB: Bool {
        settings.effectiveOpenWithLLDB(openWithLLDB)
    }
    private static let metalHUDQueue = DispatchQueue(
        label: "app.makedie.MacOver.AppSettings.metalHUD",
        qos: .utility
    )
    private static let metalHUDGenerationLock = NSLock()
    private static var metalHUDGenerations: [String: UInt64] = [:]

    private struct PendingMetalHUDUpdate {
        let bundleID: String
        let enabled: Bool
        let generation: UInt64
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "app.makedie.MacOver.AppSettings.io", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var hasPendingWrite = false
    let debounceInterval: TimeInterval
    private let metalHUDExecutor: (String, Bool) throws -> Void
    private var suppressPersistence = false
    private var isResetting = false
    private var _settings: AppSettingsData

    private static func reserveMetalHUDGeneration(for bundleID: String) -> UInt64 {
        metalHUDGenerationLock.lock()
        defer { metalHUDGenerationLock.unlock() }
        let next = (metalHUDGenerations[bundleID] ?? 0) &+ 1
        metalHUDGenerations[bundleID] = next
        return next
    }

    private static func isLatestMetalHUDGeneration(_ generation: UInt64, for bundleID: String) -> Bool {
        metalHUDGenerationLock.lock()
        defer { metalHUDGenerationLock.unlock() }
        return metalHUDGenerations[bundleID] == generation
    }

    private static func enqueueMetalHUDUpdate(
        _ pending: PendingMetalHUDUpdate,
        executor: @escaping (String, Bool) throws -> Void
    ) {
        metalHUDQueue.async {
            guard isLatestMetalHUDGeneration(pending.generation, for: pending.bundleID) else { return }
            do {
                try executor(pending.bundleID, pending.enabled)
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
    }

    static func syncMetalHUD(
        bundleID: String,
        enabled: Bool,
        executor: @escaping (String, Bool) throws -> Void = { try Shell.setMetalHUD($0, enabled: $1) }
    ) async {
        guard !bundleID.isEmpty else { return }
        let generation = reserveMetalHUDGeneration(for: bundleID)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            metalHUDQueue.async {
                defer { continuation.resume() }
                guard isLatestMetalHUDGeneration(generation, for: bundleID) else { return }
                try? executor(bundleID, enabled)
            }
        }
    }

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
            update { $0 = newValue }
        }
    }

    static func settingsURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        appSettingsDir
            .appendingEscapedPathComponent(bundleIdentifier)
            .appendingPathExtension("plist")
    }

    convenience init(_ info: AppInfo) {
        let url = AppSettings.settingsURL(forBundleIdentifier: info.bundleIdentifier)
        self.init(settingsUrl: url, info: info, debounceInterval: 0.5)
    }

    init(
        settingsUrl: URL,
        info: AppInfo,
        debounceInterval: TimeInterval = 0.5,
        metalHUDExecutor: @escaping (String, Bool) throws -> Void = { try Shell.setMetalHUD($0, enabled: $1) }
    ) {
        self.info = info
        self.settingsUrl = settingsUrl
        self.debounceInterval = debounceInterval
        self.metalHUDExecutor = metalHUDExecutor
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

    private func reserveMetalHUDIfNeededLocked(
        from previous: AppSettingsData,
        to current: AppSettingsData
    ) -> PendingMetalHUDUpdate? {
        guard previous.effectiveMetalHUD != current.effectiveMetalHUD,
              !current.bundleIdentifier.isEmpty else {
            return nil
        }
        let generation = Self.reserveMetalHUDGeneration(for: current.bundleIdentifier)
        return PendingMetalHUDUpdate(
            bundleID: current.bundleIdentifier,
            enabled: current.effectiveMetalHUD,
            generation: generation
        )
    }

    func update(_ mutate: (inout AppSettingsData) -> Void) {
        var pendingHUD: PendingMetalHUDUpdate?
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
            pendingHUD = reserveMetalHUDIfNeededLocked(from: previous, to: updated)
            scheduleDebouncedWriteLocked()
        }
        lock.unlock()

        notifyChangedOnMain()

        if let pendingHUD {
            Self.enqueueMetalHUDUpdate(pendingHUD, executor: metalHUDExecutor)
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
            guard !updatedSettings.strictEmulationMode else { return }
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
        var pendingHUD: PendingMetalHUDUpdate?
        lock.lock()
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        hasPendingWrite = false
        let previous = _settings
        isResetting = true
        defer { isResetting = false }
        _settings = defaults
        pendingHUD = reserveMetalHUDIfNeededLocked(from: previous, to: defaults)
        _ = encodeLocked()
        lock.unlock()

        notifyChangedOnMain()

        if let pendingHUD {
            Self.enqueueMetalHUDUpdate(pendingHUD, executor: metalHUDExecutor)
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
