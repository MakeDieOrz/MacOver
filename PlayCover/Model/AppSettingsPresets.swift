//
//  AppSettingsPresets.swift
//  PlayCover
//

import Foundation
import PlayCoverCore

nonisolated enum PlayAppSettingsPreset: String, CaseIterable, Identifiable {
    case balanced
    case crisp
    case eco
    case phone

    var id: String { rawValue }

    var titleKey: String { "preset.\(rawValue).title" }
    var subtitleKey: String { "preset.\(rawValue).subtitle" }

    var systemImage: String {
        switch self {
        case .balanced: return "sparkles.rectangle.stack"
        case .crisp: return "4k.tv"
        case .eco: return "leaf"
        case .phone: return "iphone"
        }
    }

    func apply(to data: inout AppSettingsData) {
        switch self {
        case .balanced:
            data.resolution = 2
            data.aspectRatio = 1
            data.windowWidth = 1920
            data.windowHeight = 1080
            data.customScaler = 2.0
            data.frameRateTargetMode = .adaptive
            data.iosDeviceModel = "iPad16,6"
        case .crisp:
            data.resolution = 3
            data.aspectRatio = 1
            data.windowWidth = 2560
            data.windowHeight = 1440
            data.customScaler = 1.5
            data.frameRateTargetMode = .fixed120
            data.iosDeviceModel = "iPad17,3"
        case .eco:
            data.resolution = 2
            data.aspectRatio = 1
            data.windowWidth = 1920
            data.windowHeight = 1080
            data.customScaler = 1.0
            data.frameRateTargetMode = .fixed30
            data.iosDeviceModel = "iPad13,8"
        case .phone:
            data.resolution = 2
            data.aspectRatio = 1
            data.windowWidth = 1920
            data.windowHeight = 1080
            data.customScaler = 2.0
            data.frameRateTargetMode = .adaptive
            data.iosDeviceModel = "iPhone18,2"
        }
    }

    func matches(_ data: AppSettingsData) -> Bool {
        guard !data.strictEmulationMode else { return false }
        var sample = data
        apply(to: &sample)
        return data.resolution == sample.resolution &&
            data.aspectRatio == sample.aspectRatio &&
            data.windowWidth == sample.windowWidth &&
            data.windowHeight == sample.windowHeight &&
            abs(data.customScaler - sample.customScaler) < 0.01 &&
            data.frameRateTargetMode == sample.frameRateTargetMode &&
            data.iosDeviceModel == sample.iosDeviceModel
    }
}

nonisolated struct DeviceProfileOption: Identifiable, Hashable {
    let model: String
    let label: String
    let isIPhone: Bool

    var id: String { model }

    static let modernIPads: [DeviceProfileOption] = [
        DeviceProfileOption(model: "iPad17,3", label: "iPad Pro 13-inch (M5 · 12GB)", isIPhone: false),
        DeviceProfileOption(model: "iPad16,6", label: "iPad Pro 13-inch (M4 · 8GB)", isIPhone: false),
        DeviceProfileOption(model: "iPad14,5", label: "iPad Pro 12.9-inch (M2 · 8GB)", isIPhone: false),
        DeviceProfileOption(model: "iPad13,8", label: "iPad Pro 12.9-inch (M1 · 8GB)", isIPhone: false)
    ]

    static let modernIPhones: [DeviceProfileOption] = [
        DeviceProfileOption(model: "iPhone18,2", label: "iPhone 17 Pro Max (A19 Pro · 12GB)", isIPhone: true),
        DeviceProfileOption(model: "iPhone17,2", label: "iPhone 16 Pro Max (A18 Pro · 8GB)", isIPhone: true),
        DeviceProfileOption(model: "iPhone16,2", label: "iPhone 15 Pro Max (A17 Pro · 8GB)", isIPhone: true),
        DeviceProfileOption(model: "iPhone15,3", label: "iPhone 14 Pro Max (A16 · 6GB)", isIPhone: true),
        DeviceProfileOption(model: "iPhone14,3", label: "iPhone 13 Pro Max (A15 · 6GB)", isIPhone: true)
    ]

    static let allModern: [DeviceProfileOption] = modernIPads + modernIPhones

    static let ios13CompatibleModels: [DeviceProfileOption] = [
        DeviceProfileOption(model: "iPad8,6", label: "iPad Pro 12.9-inch (3rd gen · A12X · 4GB)", isIPhone: false),
        DeviceProfileOption(model: "iPhone12,5", label: "iPhone 11 Pro Max (A13 · 4GB)", isIPhone: true)
    ]

    private static let legacyModels: [String: String] = [
        "iPad6,7": "iPad Pro 12.9-inch (1st gen · A9X · Legacy)",
        "iPad8,6": "iPad Pro 12.9-inch (3rd gen · A12X · Legacy)",
        "iPhone12,5": "iPhone 11 Pro Max (A13 · 4GB · Legacy)"
    ]

    static func isLegacyModel(_ model: String) -> Bool {
        legacyModels[model] != nil
    }

    static func supportsIOS13(_ model: String) -> Bool {
        ReportedIOSVersionMode.supportsIOS13(deviceModel: model)
    }

    static func recommendedIOS13Model(isIPhone: Bool) -> String {
        ReportedIOSVersionMode.recommendedIOS13Model(isIPhone: isIPhone)
    }

    static func isIPhone(_ model: String) -> Bool {
        model.hasPrefix("iPhone")
    }

    static func isMSeriesIPad(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return StrictDeviceDisplaySpec.mSeriesIPadModels.contains(normalized)
    }

    static func displayName(for model: String) -> String {
        if let modern = allModern.first(where: { $0.model == model }) {
            return modern.label
        }
        if let legacy = legacyModels[model] {
            return legacy
        }
        return model
    }
}

nonisolated extension AppSettingsData {
    static func computedDimensions(
        resolution: Int,
        aspectRatio: Int,
        customWidth: Int,
        customHeight: Int
    ) -> (width: Int, height: Int) {
        switch resolution {
        case 1:
            return AppSettings.autoResolution()
        case 2:
            return (widthForAspectRatio(aspectRatio, height: 1080), 1080)
        case 3:
            return (widthForAspectRatio(aspectRatio, height: 1440), 1440)
        case 4:
            return (widthForAspectRatio(aspectRatio, height: 2160), 2160)
        case 5:
            return (max(1, customWidth), max(1, customHeight))
        default:
            return (1920, 1080)
        }
    }

    private static func widthForAspectRatio(_ aspectRatio: Int, height: Int) -> Int {
        let ratio: (width: Int, height: Int)
        switch aspectRatio {
        case 0: ratio = (4, 3)
        case 2: ratio = (16, 10)
        default: ratio = (16, 9)
        }
        return (height / ratio.height) * ratio.width
    }

    func activeTroubleshootingCount(
        hasIntrospection: Bool,
        hasIosFrameworks: Bool,
        openWithLLDB: Bool
    ) -> Int {
        let flags: [Bool] = [
            effectivePlayChainDebugging,
            checkMicPermissionSync,
            blockSleepSpamming,
            !effectiveRootWorkDir,
            limitMotionUpdateFrequency,
            ignoreUnityKeyboardInitializationError,
            effectiveMetalHUD,
            effectiveHasIntrospection(hasIntrospection),
            hasIosFrameworks,
            effectiveOpenWithLLDB(openWithLLDB)
        ]
        return flags.filter { $0 }.count
    }
}
