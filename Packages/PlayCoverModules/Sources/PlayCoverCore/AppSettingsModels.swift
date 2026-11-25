//
//  AppSettingsModels.swift
//  PlayCoverCore
//

import Foundation

public enum WindowCompatibilityMode: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case invertedMetrics
    case invertedLegacyResize

    public init(inverseScreenValues: Bool, windowFixMethod: Int) {
        if !inverseScreenValues {
            self = .standard
        } else if windowFixMethod == 1 {
            self = .invertedLegacyResize
        } else {
            self = .invertedMetrics
        }
    }

    public var legacyValues: (inverseScreenValues: Bool, windowFixMethod: Int) {
        switch self {
        case .standard:
            return (false, 0)
        case .invertedMetrics:
            return (true, 0)
        case .invertedLegacyResize:
            return (true, 1)
        }
    }

    public var requiresAdaptiveResolutionOff: Bool {
        self == .invertedLegacyResize
    }
}

public enum StrictViewportOrientation: String, Codable, CaseIterable, Equatable, Sendable {
    case portrait
    case landscape

    public init(rawSetting: String?) {
        let normalized = (rawSetting ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "portrait":
            self = .portrait
        default:
            self = .landscape
        }
    }

    public var displayRotationTag: Int {
        switch self {
        case .landscape:
            return 0
        case .portrait:
            return 1
        }
    }
}

public enum StrictViewportScaleMode: String, Codable, CaseIterable, Equatable, Sendable {
    case native1x
    case fitScreen

    public init(rawSetting: String?) {
        let normalized = (rawSetting ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "native1x", "native", "1x":
            self = .native1x
        default:
            self = .fitScreen
        }
    }
}

public struct StrictDeviceDisplaySpec: Equatable, Sendable {
    public let model: String
    public let portraitPixelWidth: Int
    public let portraitPixelHeight: Int
    public let nativeScale: Double
    public let maxFrameRateHz: Int
    public let isIPad: Bool

    public init(
        model: String,
        portraitPixelWidth: Int,
        portraitPixelHeight: Int,
        nativeScale: Double,
        maxFrameRateHz: Int,
        isIPad: Bool
    ) {
        self.model = model
        self.portraitPixelWidth = portraitPixelWidth
        self.portraitPixelHeight = portraitPixelHeight
        self.nativeScale = nativeScale
        self.maxFrameRateHz = maxFrameRateHz
        self.isIPad = isIPad
    }

    public var portraitLogicalWidth: Int {
        Int((Double(portraitPixelWidth) / nativeScale).rounded())
    }

    public var portraitLogicalHeight: Int {
        Int((Double(portraitPixelHeight) / nativeScale).rounded())
    }

    public var isMSeriesIPad: Bool {
        Self.mSeriesIPadModels.contains(model)
    }

    public static let mSeriesIPadModels: Set<String> = [
        "iPad13,8",
        "iPad14,5",
        "iPad16,6",
        "iPad17,3"
    ]

    public func logicalSize(orientation: StrictViewportOrientation) -> (width: Int, height: Int) {
        switch orientation {
        case .portrait:
            return (portraitLogicalWidth, portraitLogicalHeight)
        case .landscape:
            return (portraitLogicalHeight, portraitLogicalWidth)
        }
    }

    public func pixelSize(orientation: StrictViewportOrientation) -> (width: Int, height: Int) {
        switch orientation {
        case .portrait:
            return (portraitPixelWidth, portraitPixelHeight)
        case .landscape:
            return (portraitPixelHeight, portraitPixelWidth)
        }
    }

    public static let knownProfiles: [String: StrictDeviceDisplaySpec] = [
        "iPad6,7": StrictDeviceDisplaySpec(
            model: "iPad6,7", portraitPixelWidth: 2048, portraitPixelHeight: 2732,
            nativeScale: 2.0, maxFrameRateHz: 60, isIPad: true
        ),
        "iPad8,6": StrictDeviceDisplaySpec(
            model: "iPad8,6", portraitPixelWidth: 2048, portraitPixelHeight: 2732,
            nativeScale: 2.0, maxFrameRateHz: 120, isIPad: true
        ),
        "iPad13,8": StrictDeviceDisplaySpec(
            model: "iPad13,8", portraitPixelWidth: 2048, portraitPixelHeight: 2732,
            nativeScale: 2.0, maxFrameRateHz: 120, isIPad: true
        ),
        "iPad14,5": StrictDeviceDisplaySpec(
            model: "iPad14,5", portraitPixelWidth: 2048, portraitPixelHeight: 2732,
            nativeScale: 2.0, maxFrameRateHz: 120, isIPad: true
        ),
        "iPad16,6": StrictDeviceDisplaySpec(
            model: "iPad16,6", portraitPixelWidth: 2064, portraitPixelHeight: 2752,
            nativeScale: 2.0, maxFrameRateHz: 120, isIPad: true
        ),
        "iPad17,3": StrictDeviceDisplaySpec(
            model: "iPad17,3", portraitPixelWidth: 2064, portraitPixelHeight: 2752,
            nativeScale: 2.0, maxFrameRateHz: 120, isIPad: true
        ),
        "iPhone12,5": StrictDeviceDisplaySpec(
            model: "iPhone12,5", portraitPixelWidth: 1242, portraitPixelHeight: 2688,
            nativeScale: 3.0, maxFrameRateHz: 60, isIPad: false
        ),
        "iPhone14,3": StrictDeviceDisplaySpec(
            model: "iPhone14,3", portraitPixelWidth: 1284, portraitPixelHeight: 2778,
            nativeScale: 3.0, maxFrameRateHz: 120, isIPad: false
        ),
        "iPhone15,3": StrictDeviceDisplaySpec(
            model: "iPhone15,3", portraitPixelWidth: 1290, portraitPixelHeight: 2796,
            nativeScale: 3.0, maxFrameRateHz: 120, isIPad: false
        ),
        "iPhone16,2": StrictDeviceDisplaySpec(
            model: "iPhone16,2", portraitPixelWidth: 1290, portraitPixelHeight: 2796,
            nativeScale: 3.0, maxFrameRateHz: 120, isIPad: false
        ),
        "iPhone17,2": StrictDeviceDisplaySpec(
            model: "iPhone17,2", portraitPixelWidth: 1320, portraitPixelHeight: 2868,
            nativeScale: 3.0, maxFrameRateHz: 120, isIPad: false
        ),
        "iPhone18,2": StrictDeviceDisplaySpec(
            model: "iPhone18,2", portraitPixelWidth: 1320, portraitPixelHeight: 2868,
            nativeScale: 3.0, maxFrameRateHz: 120, isIPad: false
        )
    ]

    public static func resolve(for deviceModel: String) -> StrictDeviceDisplaySpec {
        let normalized = deviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = knownProfiles[normalized] {
            return exact
        }
        if normalized.hasPrefix("iPhone") {
            return StrictDeviceDisplaySpec(
                model: normalized,
                portraitPixelWidth: 1320,
                portraitPixelHeight: 2868,
                nativeScale: 3.0,
                maxFrameRateHz: 120,
                isIPad: false
            )
        }
        return StrictDeviceDisplaySpec(
            model: normalized.isEmpty ? "iPad13,8" : normalized,
            portraitPixelWidth: 2048,
            portraitPixelHeight: 2732,
            nativeScale: 2.0,
            maxFrameRateHz: 120,
            isIPad: true
        )
    }
}

public struct PixelBudget: Equatable, Sendable {
    public static let limit: Double = 2_621_440.0 * 2.0
    public static let maxTextureEdgePixels: Int = 4096

    public enum MemoryTier: Equatable, Sendable {
        case tier8GB
        case tier16GB
        case tier24GB
        case tierHighMemory

        public var budgetPixels: Double {
            switch self {
            case .tier8GB: return 4_500_000
            case .tier16GB: return 6_000_000
            case .tier24GB: return 9_000_000
            case .tierHighMemory: return 12_000_000
            }
        }

        public var label: String {
            switch self {
            case .tier8GB: return "≤8 GB"
            case .tier16GB: return "≤16 GB"
            case .tier24GB: return "≤24 GB"
            case .tierHighMemory: return ">24 GB"
            }
        }
    }

    public enum Level: String, Equatable, Sendable {
        case ok
        case caution
        case over
    }

    public let width: Int
    public let height: Int
    public let scaler: Double
    public let physicalMemoryBytes: UInt64

    public init(
        width: Int,
        height: Int,
        scaler: Double,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.width = width
        self.height = height
        self.scaler = scaler
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public static func memoryTier(forPhysicalMemoryBytes bytes: UInt64) -> MemoryTier {
        let gib: UInt64 = 1_073_741_824
        if bytes <= 8 * gib {
            return .tier8GB
        }
        if bytes <= 16 * gib {
            return .tier16GB
        }
        if bytes <= 24 * gib {
            return .tier24GB
        }
        return .tierHighMemory
    }

    public static func adaptiveLimit(forPhysicalMemoryBytes bytes: UInt64) -> Double {
        memoryTier(forPhysicalMemoryBytes: bytes).budgetPixels
    }

    public static var currentHostLimit: Double {
        adaptiveLimit(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public var memoryTier: MemoryTier {
        Self.memoryTier(forPhysicalMemoryBytes: physicalMemoryBytes)
    }

    public var adaptiveLimit: Double {
        memoryTier.budgetPixels
    }

    public var weightedPixels: Double {
        guard width > 0, height > 0, scaler.isFinite, scaler > 0 else { return 0 }
        return Double(width) * Double(height) * scaler * scaler
    }

    public var renderedWidth: Int {
        guard width > 0, scaler.isFinite, scaler > 0 else { return 0 }
        return Int((Double(width) * scaler).rounded())
    }

    public var renderedHeight: Int {
        guard height > 0, scaler.isFinite, scaler > 0 else { return 0 }
        return Int((Double(height) * scaler).rounded())
    }

    public var renderedDimensions: (width: Int, height: Int) {
        (renderedWidth, renderedHeight)
    }

    public var exceedsMaxTextureEdge: Bool {
        max(renderedWidth, renderedHeight) > Self.maxTextureEdgePixels
    }

    public var ratio: Double {
        let budgetLimit = adaptiveLimit
        guard budgetLimit > 0 else { return 0 }
        return weightedPixels / budgetLimit
    }

    public var level: Level {
        let currentRatio = ratio
        if currentRatio >= 1.0 {
            return .over
        }
        if currentRatio >= 0.75 {
            return .caution
        }
        return .ok
    }

    public var fittedScaler: Double {
        guard width > 0, height > 0 else { return 1.0 }
        let pixelArea = Double(width) * Double(height)
        let budgetLimit = adaptiveLimit
        guard budgetLimit > 0 else { return 0.5 }
        let raw = sqrt(budgetLimit / pixelArea)
        let clampedTenths = Int(min(30.0, max(5.0, (raw * 10.0).rounded(.down))))
        var tenths = min(30, max(5, clampedTenths))
        while tenths > 5 {
            let candidate = Double(tenths) / 10.0
            if (pixelArea * candidate * candidate) / budgetLimit < 1.0 {
                break
            }
            tenths -= 1
        }
        return Double(tenths) / 10.0
    }
}

public enum FrameRateTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case adaptive
    case fixed120
    case fixed60
    case fixed30

    public init(rawSetting: String?) {
        let normalized = (rawSetting ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "fixed120", "120", "120hz":
            self = .fixed120
        case "fixed60", "60", "60hz":
            self = .fixed60
        case "fixed30", "30", "30hz":
            self = .fixed30
        default:
            self = .adaptive
        }
    }

    public var targetHz: Int? {
        switch self {
        case .adaptive:
            return nil
        case .fixed120:
            return 120
        case .fixed60:
            return 60
        case .fixed30:
            return 30
        }
    }
}

public enum ReportedIOSVersionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case followHost
    case compat18_3
    case compat13_7

    public static let compat18_3Version = "18.3"
    public static let compat18_3Build = "22D63"
    public static let compat18_3KernelRelease = "24.3.0"
    public static let compat13_7Version = "13.7"
    public static let compat13_7Build = "17H35"
    public static let compat13_7KernelRelease = "19.6.0"
    public static let ios13CompatibleModels: Set<String> = ["iPad6,7", "iPad8,6", "iPhone12,5"]

    public static func supportsIOS13(deviceModel: String) -> Bool {
        let normalized = deviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return ios13CompatibleModels.contains(normalized)
    }

    public static func recommendedIOS13Model(isIPhone: Bool) -> String {
        isIPhone ? "iPhone12,5" : "iPad8,6"
    }

    public static func recommendedIOS13Model(for deviceModel: String) -> String {
        let normalized = deviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return recommendedIOS13Model(isIPhone: normalized.hasPrefix("iPhone"))
    }

    public static func effectiveDeviceModel(_ deviceModel: String, for mode: ReportedIOSVersionMode) -> String {
        let normalized = deviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = normalized.isEmpty ? "iPad13,8" : normalized
        guard mode == .compat13_7, !supportsIOS13(deviceModel: base) else {
            return base
        }
        return recommendedIOS13Model(for: base)
    }

    public init(rawSetting: String?) {
        let normalized = (rawSetting ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "followhost", "follow_host", "host":
            self = .followHost
        case "compat18_3", "18.3", "ios18_3":
            self = .compat18_3
        case "compat13_7", "13.7", "ios13_7":
            self = .compat13_7
        default:
            self = .automatic
        }
    }

    public static func isMinimumOSVersion(
        _ raw: String?,
        higherThan major: Int,
        minor: Int
    ) -> Bool {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let parsedMajor = Int(first) else {
            return false
        }
        let parsedMinor: Int
        if parts.count > 1 {
            guard let second = Int(parts[1]) else {
                return false
            }
            parsedMinor = second
        } else {
            parsedMinor = 0
        }
        let parsedPatch: Int
        if parts.count > 2 {
            guard let third = Int(parts[2]) else {
                return false
            }
            parsedPatch = third
        } else {
            parsedPatch = 0
        }
        if parsedMajor != major {
            return parsedMajor > major
        }
        if parsedMinor != minor {
            return parsedMinor > minor
        }
        return parsedPatch > 0
    }
}

public enum PlayCoverRestartField: String, CaseIterable, Equatable, Hashable, Sendable {
    case iosDeviceModel
    case resolution
    case windowSize
    case aspectRatio
    case customScaler
    case windowCompatibility
    case frameRateTarget
    case reportedIOSVersion
    case notch
    case bypass
    case playChain
    case playChainDebugging
    case metalHUD
    /// Legacy field retained for enum/Codable compatibility; introspection injection uses
    /// `Info.plist` `LSEnvironment` (`PlayApp.introspection`) rather than `AppSettingsData`.
    case injectIntrospection
    case rootWorkDir
    case hideTitleBar
    case floatingWindow
    case enableNetworkRules
    case blockedURLPatterns
    case networkProxy
    case keymapping
    case disableBuiltinMouse
    case blockSleepSpamming
    case ignoreUnityKeyboardInitializationError
    case interceptInlineSyscalls
    case strictEmulationMode
    case strictViewportOrientation
    case strictViewportScaleMode
}
