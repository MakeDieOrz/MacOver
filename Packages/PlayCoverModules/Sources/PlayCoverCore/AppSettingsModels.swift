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

public struct PixelBudget: Equatable, Sendable {
    public static let limit: Double = 2_621_440.0 * 2.0

    public enum Level: String, Equatable, Sendable {
        case ok
        case caution
        case over
    }

    public let width: Int
    public let height: Int
    public let scaler: Double

    public init(width: Int, height: Int, scaler: Double) {
        self.width = width
        self.height = height
        self.scaler = scaler
    }

    public var weightedPixels: Double {
        guard width > 0, height > 0, scaler.isFinite, scaler > 0 else { return 0 }
        return Double(width) * Double(height) * scaler
    }

    public var ratio: Double {
        weightedPixels / Self.limit
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
        let raw = Self.limit / (Double(width) * Double(height))
        let floored = (raw * 10.0).rounded(.down) / 10.0
        return min(3.0, max(0.5, floored))
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
        let base = normalized.isEmpty ? deviceModel : normalized
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
    case keymapping
    case disableBuiltinMouse
    case blockSleepSpamming
    case ignoreUnityKeyboardInitializationError
}
