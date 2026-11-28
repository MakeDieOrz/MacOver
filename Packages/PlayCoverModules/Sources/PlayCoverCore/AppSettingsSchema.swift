//
//  AppSettingsSchema.swift
//  PlayCoverCore
//
//  Single source of truth for per-app settings plist schema shared across
//  PlayCover (host), PlayTools (Catalyst runtime), AKInterface, and tests.
//  Keep this file pure Foundation with zero AppKit or UIKit imports.
//

import Foundation

public struct AppSettingsData: Codable, Equatable, Sendable {
    public var bundleIdentifier: String = ""
    public var originalBundleName: String?
    public var originalMinimumOSVersion: String?

    public var keymapping = true
    public var sensitivity: Float = 50

    public var disableTimeout = false
    public var displayRotation = 0
    public var iosDeviceModel = "iPad13,8"
    public var windowWidth = 1920
    public var windowHeight = 1080
    public var customScaler = 2.0
    public var resolution = 1
    public var aspectRatio = 1
    public var notch: Bool = false
    public var bypass = true
    public var discordActivity = DiscordActivity()
    public var version = "3.0.0"
    public var playChain = true
    public var playChainDebugging = false
    public var inverseScreenValues = false
    public var metalHUD = false
    public var windowFixMethod = 0
    /// Deprecated/unused legacy plist key retained for Codable compatibility; actual
    /// introspection library injection uses `Info.plist` `LSEnvironment` (`PlayApp.introspection`).
    public var injectIntrospection = false
    public var rootWorkDir = true
    public var noKMOnInput = true
    public var enableScrollWheel = true
    public var rightClickLongPress = true
    public var hideTitleBar = false
    public var floatingWindow = false
    public var quitOnWindowClose = false
    public var checkMicPermissionSync = false
    public var limitMotionUpdateFrequency = false
    public var disableBuiltinMouse = false
    public var resizableAspectRatioType = 0
    public var resizableAspectRatioWidth = 0
    public var resizableAspectRatioHeight = 0
    public var blockSleepSpamming = false
    public var ignoreUnityKeyboardInitializationError = false
    public var interceptInlineSyscalls = false
    public var enableAutomationBridge = false
    public var enableNetworkRules = false
    public var networkBlockMock200 = true
    public var blockedURLPatterns: [String] = []
    public var networkProxyMode: String = "direct"
    public var externalProxyProtocol: String = "http"
    public var externalProxyHost: String = "127.0.0.1"
    public var externalProxyPort: Int = 8888
    public var mitmPort: Int = 0
    public var mitmRuntimePort: Int = 0
    public var enableCustomCertificates: Bool = false
    public var mitmAllHosts: Bool = true
    public var mitmHostPatterns: [String] = []
    public var mitmAllowPinningBypass: Bool = false
    public var hideProxyFromApp: Bool = true
    public var mitmCaptureBodies: Bool = true
    public var keymappingDisabledAt: Float = 0
    public var frameRateTarget: String = FrameRateTarget.adaptive.rawValue
    public var reportedIOSVersion: String = ReportedIOSVersionMode.automatic.rawValue
    public var strictEmulationMode = false
    public var strictViewportOrientation: StrictViewportOrientation = .landscape
    public var strictViewportScaleMode: StrictViewportScaleMode = .fitScreen
    public var storedHasIntrospection = false
    public var storedHasIosFrameworks = false

    public init() {}

    // handle old 2.x settings where PlayChain did not exist yet
    public init(from decoder: Decoder) throws {
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
        notch = (try? container.decodeIfPresent(Bool.self, forKey: .notch)) ?? false
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
        quitOnWindowClose = (try? container.decodeIfPresent(Bool.self, forKey: .quitOnWindowClose)) ?? false
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
        enableAutomationBridge = (try? container.decodeIfPresent(
            Bool.self, forKey: .enableAutomationBridge
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

    public var windowCompatibility: WindowCompatibilityMode {
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

    public var frameRateTargetMode: FrameRateTarget {
        get { FrameRateTarget(rawSetting: frameRateTarget) }
        set { frameRateTarget = newValue.rawValue }
    }

    public var reportedIOSVersionMode: ReportedIOSVersionMode {
        get { ReportedIOSVersionMode(rawSetting: reportedIOSVersion) }
        set { reportedIOSVersion = newValue.rawValue }
    }

    public var effectiveIOSDeviceModel: String {
        ReportedIOSVersionMode.effectiveDeviceModel(iosDeviceModel, for: reportedIOSVersionMode)
    }

    public var strictDeviceDisplaySpec: StrictDeviceDisplaySpec {
        StrictDeviceDisplaySpec.resolve(for: effectiveIOSDeviceModel)
    }

    public var effectiveBypass: Bool {
        strictEmulationMode ? true : bypass
    }

    public var effectiveInterceptInlineSyscalls: Bool {
        strictEmulationMode ? true : interceptInlineSyscalls
    }

    public var effectiveRootWorkDir: Bool {
        strictEmulationMode ? true : rootWorkDir
    }

    public var effectiveMetalHUD: Bool {
        strictEmulationMode ? false : metalHUD
    }

    public var effectivePlayChainDebugging: Bool {
        strictEmulationMode ? false : playChainDebugging
    }

    public var effectiveNotch: Bool {
        strictEmulationMode ? false : notch
    }

    public func effectiveHasIntrospection(_ storedHasIntrospection: Bool) -> Bool {
        strictEmulationMode ? false : storedHasIntrospection
    }

    public func effectiveHasIosFrameworks(_ storedHasIosFrameworks: Bool) -> Bool {
        strictEmulationMode ? false : storedHasIosFrameworks
    }

    public func effectiveOpenWithLLDB(_ storedOpenWithLLDB: Bool) -> Bool {
        strictEmulationMode ? false : storedOpenWithLLDB
    }

    public var effectiveCustomScaler: Double {
        strictEmulationMode ? strictDeviceDisplaySpec.nativeScale : customScaler
    }

    public var effectiveLogicalWindowSize: (width: Int, height: Int) {
        if strictEmulationMode {
            return strictDeviceDisplaySpec.logicalSize(orientation: strictViewportOrientation)
        }
        return (windowWidth, windowHeight)
    }

    public var effectiveWindowWidth: Int {
        effectiveLogicalWindowSize.width
    }

    public var effectiveWindowHeight: Int {
        effectiveLogicalWindowSize.height
    }

    public var effectiveResolution: Int {
        strictEmulationMode ? 5 : resolution
    }

    public var effectiveWindowCompatibility: WindowCompatibilityMode {
        strictEmulationMode ? .standard : windowCompatibility
    }

    public var effectiveDisplayRotation: Int {
        strictEmulationMode ? strictViewportOrientation.displayRotationTag : displayRotation
    }

    public func effectivePixelBudget(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> PixelBudget {
        PixelBudget(
            width: effectiveWindowWidth,
            height: effectiveWindowHeight,
            scaler: effectiveCustomScaler,
            physicalMemoryBytes: physicalMemoryBytes
        )
    }

    public var pixelBudget: PixelBudget {
        effectivePixelBudget()
    }

    public static func normalizedDimensions(
        resolution: Int,
        aspectRatio: Int,
        customWidth: Int,
        customHeight: Int,
        autoResolution: (width: Int, height: Int) = (1920, 1080)
    ) -> (width: Int, height: Int) {
        func widthForAspect(_ ratioTag: Int, height: Int) -> Int {
            let ratio: (width: Int, height: Int)
            switch ratioTag {
            case 0: ratio = (4, 3)
            case 2: ratio = (16, 10)
            default: ratio = (16, 9)
            }
            return (height / ratio.height) * ratio.width
        }
        switch resolution {
        case 1:
            return autoResolution
        case 2:
            return (widthForAspect(aspectRatio, height: 1080), 1080)
        case 3:
            return (widthForAspect(aspectRatio, height: 1440), 1440)
        case 4:
            return (widthForAspect(aspectRatio, height: 2160), 2160)
        case 5:
            return (max(1, customWidth), max(1, customHeight))
        default:
            return (max(1, customWidth), max(1, customHeight))
        }
    }

    public static func normalizedResizableAspectRatio(
        type: Int,
        customWidth: Int,
        customHeight: Int
    ) -> (width: Int, height: Int) {
        switch type {
        case 0:
            return (0, 0)
        case 1:
            return (max(1, customWidth), max(1, customHeight))
        case 2:
            return (4, 3)
        case 3:
            return (16, 9)
        case 4:
            return (16, 10)
        default:
            return (16, 9)
        }
    }

    public mutating func normalizeDisplaySettings(
        previous: AppSettingsData? = nil,
        autoResolution: (width: Int, height: Int)? = nil
    ) {
        guard !strictEmulationMode else { return }

        let resolutionChanged = previous == nil || resolution != previous?.resolution
        let aspectRatioChanged = previous == nil || aspectRatio != previous?.aspectRatio
        let sizeExplicitlyChanged = previous != nil && (
            windowWidth != previous?.windowWidth || windowHeight != previous?.windowHeight
        )
        if (resolutionChanged || aspectRatioChanged) && !sizeExplicitlyChanged {
            switch resolution {
            case 1:
                if let autoResolution {
                    windowWidth = autoResolution.width
                    windowHeight = autoResolution.height
                }
            case 2, 3, 4:
                let dims = Self.normalizedDimensions(
                    resolution: resolution,
                    aspectRatio: aspectRatio,
                    customWidth: windowWidth,
                    customHeight: windowHeight
                )
                windowWidth = dims.width
                windowHeight = dims.height
            case 5:
                windowWidth = max(1, windowWidth)
                windowHeight = max(1, windowHeight)
            default:
                break
            }
        } else if resolution == 5 {
            windowWidth = max(1, windowWidth)
            windowHeight = max(1, windowHeight)
        }

        let resizableTypeChanged = previous == nil || resizableAspectRatioType != previous?.resizableAspectRatioType
        if resizableTypeChanged {
            let pair = Self.normalizedResizableAspectRatio(
                type: resizableAspectRatioType,
                customWidth: resizableAspectRatioWidth,
                customHeight: resizableAspectRatioHeight
            )
            resizableAspectRatioWidth = pair.width
            resizableAspectRatioHeight = pair.height
        } else if resizableAspectRatioType == 0 {
            resizableAspectRatioWidth = 0
            resizableAspectRatioHeight = 0
        }
    }

    public func restartRequiredChanges(comparedTo snapshot: AppSettingsData) -> [PlayCoverRestartField] {
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
        if effectiveHasIosFrameworks(storedHasIosFrameworks)
            != snapshot.effectiveHasIosFrameworks(snapshot.storedHasIosFrameworks) {
            changed.append(.injectIosFrameworks)
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
        if enableCustomCertificates != snapshot.enableCustomCertificates {
            changed.append(.enableCustomCertificates)
        }
        if mitmAllowPinningBypass != snapshot.mitmAllowPinningBypass {
            changed.append(.mitmAllowPinningBypass)
        }
        if hideProxyFromApp != snapshot.hideProxyFromApp {
            changed.append(.hideProxyFromApp)
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
        if enableAutomationBridge != snapshot.enableAutomationBridge {
            changed.append(.enableAutomationBridge)
        }
        return changed
    }
}
