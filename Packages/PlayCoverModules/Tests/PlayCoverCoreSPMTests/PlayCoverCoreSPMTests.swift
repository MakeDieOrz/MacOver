import Foundation
import XCTest
@testable import PlayCoverCore

final class PlayCoverCoreSPMTests: XCTestCase {
    func testNetworkRuleParserAndPlayRules() {
        XCTAssertTrue(NetworkRuleParser.isRuleEnabled("example.com"))
        XCTAssertFalse(NetworkRuleParser.isRuleEnabled("#!OFF example.com"))
        XCTAssertTrue(NetworkRuleParser.isImportableRuleLine("DOMAIN-SUFFIX,example.com"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("   # comment"))

        let blockMeta = NetworkRuleParser.classifyRule("api.tracker.example # telemetry")
        XCTAssertTrue(blockMeta.isEnabled)
        XCTAssertFalse(blockMeta.isAllow)
        XCTAssertEqual(NetworkRuleParser.stripInlineComment(blockMeta.body), "api.tracker.example")

        let allowMeta = NetworkRuleParser.classifyRule("!https://allowed.example/path")
        XCTAssertTrue(allowMeta.isAllow)
        XCTAssertEqual(NetworkRuleParser.normalizedAllowRule("allowed.example"), "@@allowed.example")

        let built = PlayRules.buildRules(rules: ["host-a", "HOST-B"], bundleID: "com.example.game")
        XCTAssertFalse(built.isEmpty)
        let template = RuleTemplate(data: ["bundle": "com.example.game"])
        XCTAssertEqual(template.render(template: "id=${bundle}"), "id=com.example.game")
    }

    func testURLExtensionsAndAppInfoRoundTrip() throws {
        XCTAssertEqual("hello world".esc, "hello\\ world")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverCoreSPMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let escaped = tmpDir.appendingEscapedPathComponent("a/b")
        XCTAssertEqual(escaped.lastPathComponent, "a:b")

        let sampleFile = tmpDir.appendingPathComponent("sample.bin")
        try Data("playcover".utf8).write(to: sampleFile)
        XCTAssertEqual(sampleFile.sha256?.count, 64)

        let plistURL = tmpDir.appendingPathComponent("Info.plist")
        let initial: [String: Any] = [
            "CFBundleIdentifier": "com.example.spm",
            "CFBundleExecutable": "SampleApp",
            "CFBundleShortVersionString": "1.2.3",
            "MinimumOSVersion": "16.0"
        ]
        let binData = try PropertyListSerialization.data(fromPropertyList: initial, format: .binary, options: 0)
        try binData.write(to: plistURL)

        let info = AppInfo(contentsOf: plistURL)
        XCTAssertEqual(info.bundleIdentifier, "com.example.spm")
        XCTAssertEqual(info.executableName, "SampleApp")
        info.setApplicationCategoryType(.games, persist: true)
        info.assert(minimumVersion: 14.0)
        try info.write()

        let reloaded = AppInfo(contentsOf: plistURL)
        XCTAssertEqual(reloaded.applicationCategoryType, .games)
        XCTAssertEqual(reloaded.minimumOSVersion, "14.0")
    }

    func testPlayCoverDiagnosticsThreadSafeHooksAndReset() {
        defer { PlayCoverDiagnostics.reset() }
        var capturedLogs: [(String, Bool)] = []
        var capturedErrors: [String] = []
        var capturedMessages: [String] = []
        var capturedToasts: [(PlayCoverDiagnosticToastKind, String)] = []

        PlayCoverDiagnostics.configure(
            logHandler: { capturedLogs.append(($0, $1)) },
            errorHandler: { capturedErrors.append($0) },
            messageHandler: { capturedMessages.append($0) },
            toastHandler: { kind, msg, _ in capturedToasts.append((kind, msg)) },
            activeToastChecker: { $0 == .network }
        )

        PlayCoverDiagnostics.log("hello", isError: false)
        PlayCoverDiagnostics.reportError(PlayCoverError.infoPlistNotFound)
        PlayCoverDiagnostics.reportMessage("done")
        PlayCoverDiagnostics.showToast(toastType: .notice, toastDetails: "toast-body")

        XCTAssertEqual(capturedLogs.count, 1)
        XCTAssertEqual(capturedErrors.count, 1)
        XCTAssertEqual(capturedMessages, ["done"])
        XCTAssertEqual(capturedToasts.first?.0, .notice)
        XCTAssertTrue(PlayCoverDiagnostics.hasActiveToast(ofType: .network))
        XCTAssertFalse(PlayCoverDiagnostics.hasActiveToast(ofType: .error))

        PlayCoverDiagnostics.reset()
        XCTAssertFalse(PlayCoverDiagnostics.hasActiveToast(ofType: .network))
    }

    func testWindowCompatibilityAndPixelBudgetModels() {
        XCTAssertEqual(WindowCompatibilityMode(inverseScreenValues: false, windowFixMethod: 0), .standard)
        XCTAssertEqual(WindowCompatibilityMode(inverseScreenValues: false, windowFixMethod: 1), .standard)
        XCTAssertEqual(WindowCompatibilityMode(inverseScreenValues: true, windowFixMethod: 0), .invertedMetrics)
        XCTAssertEqual(WindowCompatibilityMode(inverseScreenValues: true, windowFixMethod: 1), .invertedLegacyResize)

        XCTAssertEqual(WindowCompatibilityMode.standard.legacyValues.inverseScreenValues, false)
        XCTAssertEqual(WindowCompatibilityMode.standard.legacyValues.windowFixMethod, 0)
        XCTAssertFalse(WindowCompatibilityMode.standard.requiresAdaptiveResolutionOff)

        XCTAssertEqual(WindowCompatibilityMode.invertedMetrics.legacyValues.inverseScreenValues, true)
        XCTAssertEqual(WindowCompatibilityMode.invertedMetrics.legacyValues.windowFixMethod, 0)
        XCTAssertFalse(WindowCompatibilityMode.invertedMetrics.requiresAdaptiveResolutionOff)

        XCTAssertEqual(WindowCompatibilityMode.invertedLegacyResize.legacyValues.inverseScreenValues, true)
        XCTAssertEqual(WindowCompatibilityMode.invertedLegacyResize.legacyValues.windowFixMethod, 1)
        XCTAssertTrue(WindowCompatibilityMode.invertedLegacyResize.requiresAdaptiveResolutionOff)

        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(PixelBudget.limit, 2_621_440.0 * 2.0)
        XCTAssertEqual(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 8 * gib), 4_500_000)
        XCTAssertEqual(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 16 * gib), 6_000_000)
        XCTAssertEqual(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 24 * gib), 9_000_000)
        XCTAssertEqual(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 32 * gib), 12_000_000)

        let okBudget = PixelBudget(width: 1920, height: 1080, scaler: 1.0, physicalMemoryBytes: 8 * gib)
        XCTAssertEqual(okBudget.weightedPixels, 2_073_600, accuracy: 0.5)
        XCTAssertEqual(okBudget.renderedWidth, 1920)
        XCTAssertEqual(okBudget.renderedHeight, 1080)
        XCTAssertFalse(okBudget.exceedsMaxTextureEdge)
        XCTAssertEqual(okBudget.level, .ok)

        let cautionBudget = PixelBudget(width: 1920, height: 1080, scaler: 2.0, physicalMemoryBytes: 24 * gib)
        XCTAssertEqual(cautionBudget.weightedPixels, 8_294_400, accuracy: 0.5)
        XCTAssertEqual(cautionBudget.renderedWidth, 3840)
        XCTAssertEqual(cautionBudget.renderedHeight, 2160)
        XCTAssertFalse(cautionBudget.exceedsMaxTextureEdge)
        XCTAssertEqual(cautionBudget.level, .caution)

        let highMemBudget = PixelBudget(width: 1920, height: 1080, scaler: 2.0, physicalMemoryBytes: 32 * gib)
        XCTAssertEqual(highMemBudget.level, .ok)

        let edge4096Exact = PixelBudget(width: 2048, height: 1536, scaler: 2.0, physicalMemoryBytes: 32 * gib)
        XCTAssertEqual(edge4096Exact.renderedWidth, 4096)
        XCTAssertEqual(edge4096Exact.renderedHeight, 3072)
        XCTAssertFalse(edge4096Exact.exceedsMaxTextureEdge)

        let edgeOver4096 = PixelBudget(width: 1920, height: 1080, scaler: 2.2, physicalMemoryBytes: 32 * gib)
        XCTAssertEqual(edgeOver4096.renderedWidth, 4224)
        XCTAssertEqual(edgeOver4096.renderedHeight, 2376)
        XCTAssertTrue(edgeOver4096.exceedsMaxTextureEdge)

        let overBudget = PixelBudget(width: 2560, height: 1440, scaler: 2.0, physicalMemoryBytes: 16 * gib)
        XCTAssertEqual(overBudget.weightedPixels, 14_745_600, accuracy: 0.5)
        XCTAssertEqual(overBudget.level, .over)
        XCTAssertTrue(overBudget.exceedsMaxTextureEdge)
        XCTAssertEqual(overBudget.fittedScaler, 1.2, accuracy: 0.001)
        let fitted = PixelBudget(
            width: 2560, height: 1440, scaler: overBudget.fittedScaler, physicalMemoryBytes: 16 * gib
        )
        XCTAssertNotEqual(fitted.level, .over)

        let over8GB = PixelBudget(width: 1920, height: 1080, scaler: 2.0, physicalMemoryBytes: 8 * gib)
        XCTAssertEqual(over8GB.level, .over)
        XCTAssertEqual(over8GB.fittedScaler, 1.4, accuracy: 0.001)
        XCTAssertNotEqual(
            PixelBudget(width: 1920, height: 1080, scaler: over8GB.fittedScaler, physicalMemoryBytes: 8 * gib).level,
            .over
        )

        XCTAssertEqual(PixelBudget(width: 0, height: 1080, scaler: 2.0).weightedPixels, 0)
        XCTAssertEqual(PixelBudget(width: 0, height: 1080, scaler: 2.0).renderedWidth, 0)
        XCTAssertEqual(PixelBudget(width: 0, height: 1080, scaler: 2.0).fittedScaler, 1.0)
        XCTAssertEqual(PixelBudget(width: 1920, height: 1080, scaler: -1.0).weightedPixels, 0)
        XCTAssertFalse(PixelBudget(width: 1920, height: 1080, scaler: -1.0).exceedsMaxTextureEdge)
    }

    func testStrictEmulationEnumsAndDeviceDisplaySpecs() {
        XCTAssertEqual(StrictViewportOrientation(rawSetting: nil), .landscape)
        XCTAssertEqual(StrictViewportOrientation(rawSetting: " Portrait \n"), .portrait)
        XCTAssertEqual(StrictViewportOrientation(rawSetting: "bogus"), .landscape)
        XCTAssertEqual(StrictViewportOrientation.landscape.displayRotationTag, 0)
        XCTAssertEqual(StrictViewportOrientation.portrait.displayRotationTag, 1)

        XCTAssertEqual(StrictViewportScaleMode(rawSetting: nil), .fitScreen)
        XCTAssertEqual(StrictViewportScaleMode(rawSetting: "native1x"), .native1x)
        XCTAssertEqual(StrictViewportScaleMode(rawSetting: "NATIVE"), .native1x)
        XCTAssertEqual(StrictViewportScaleMode(rawSetting: "unknown"), .fitScreen)

        let expectedSpecs: [(String, Int, Int, Double, Int, Bool)] = [
            ("iPad6,7", 2048, 2732, 2.0, 60, true),
            ("iPad8,6", 2048, 2732, 2.0, 120, true),
            ("iPad13,8", 2048, 2732, 2.0, 120, true),
            ("iPad14,5", 2048, 2732, 2.0, 120, true),
            ("iPad16,6", 2064, 2752, 2.0, 120, true),
            ("iPad17,3", 2064, 2752, 2.0, 120, true),
            ("iPhone12,5", 1242, 2688, 3.0, 60, false),
            ("iPhone14,3", 1284, 2778, 3.0, 120, false),
            ("iPhone15,3", 1290, 2796, 3.0, 120, false),
            ("iPhone16,2", 1290, 2796, 3.0, 120, false),
            ("iPhone17,2", 1320, 2868, 3.0, 120, false),
            ("iPhone18,2", 1320, 2868, 3.0, 120, false)
        ]
        for (model, pxW, pxH, scale, fps, isIPad) in expectedSpecs {
            let spec = StrictDeviceDisplaySpec.resolve(for: model)
            XCTAssertEqual(spec.portraitPixelWidth, pxW)
            XCTAssertEqual(spec.portraitPixelHeight, pxH)
            XCTAssertEqual(spec.nativeScale, scale)
            XCTAssertEqual(spec.maxFrameRateHz, fps)
            XCTAssertEqual(spec.isIPad, isIPad)
        }

        let m4Pad = StrictDeviceDisplaySpec.resolve(for: "iPad16,6")
        XCTAssertTrue(m4Pad.isMSeriesIPad)
        XCTAssertEqual(m4Pad.logicalSize(orientation: .portrait).width, 1032)
        XCTAssertEqual(m4Pad.logicalSize(orientation: .portrait).height, 1376)
        XCTAssertEqual(m4Pad.logicalSize(orientation: .landscape).width, 1376)
        XCTAssertEqual(m4Pad.logicalSize(orientation: .landscape).height, 1032)

        let a12xPad = StrictDeviceDisplaySpec.resolve(for: "iPad8,6")
        XCTAssertFalse(a12xPad.isMSeriesIPad)

        let unknownPhone = StrictDeviceDisplaySpec.resolve(for: "iPhone99,1")
        XCTAssertFalse(unknownPhone.isIPad)
        XCTAssertEqual(unknownPhone.nativeScale, 3.0)
        XCTAssertEqual(unknownPhone.portraitPixelWidth, 1320)

        let unknownPad = StrictDeviceDisplaySpec.resolve(for: "")
        XCTAssertTrue(unknownPad.isIPad)
        XCTAssertEqual(unknownPad.nativeScale, 2.0)
        XCTAssertEqual(unknownPad.portraitPixelWidth, 2048)
    }

    func testFrameRateTargetReportedIOSVersionAndRestartFields() {
        XCTAssertEqual(FrameRateTarget(rawSetting: nil), .adaptive)
        XCTAssertNil(FrameRateTarget.adaptive.targetHz)
        XCTAssertEqual(FrameRateTarget(rawSetting: "unknown"), .adaptive)
        XCTAssertEqual(FrameRateTarget(rawSetting: " 120 ").targetHz, 120)
        XCTAssertEqual(FrameRateTarget(rawSetting: "60Hz").targetHz, 60)
        XCTAssertEqual(FrameRateTarget(rawSetting: "fixed30").targetHz, 30)

        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: nil), .automatic)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "unexpected"), .automatic)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "follow_host"), .followHost)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "host"), .followHost)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "18.3"), .compat18_3)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "ios18_3"), .compat18_3)
        XCTAssertEqual(ReportedIOSVersionMode.compat18_3Version, "18.3")
        XCTAssertEqual(ReportedIOSVersionMode.compat18_3Build, "22D63")
        XCTAssertEqual(ReportedIOSVersionMode.compat18_3KernelRelease, "24.3.0")

        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "compat13_7"), .compat13_7)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "13.7"), .compat13_7)
        XCTAssertEqual(ReportedIOSVersionMode(rawSetting: "ios13_7"), .compat13_7)
        XCTAssertEqual(ReportedIOSVersionMode.compat13_7Version, "13.7")
        XCTAssertEqual(ReportedIOSVersionMode.compat13_7Build, "17H35")
        XCTAssertEqual(ReportedIOSVersionMode.compat13_7KernelRelease, "19.6.0")
        XCTAssertTrue(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPad6,7"))
        XCTAssertTrue(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPad8,6"))
        XCTAssertTrue(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPhone12,5"))
        XCTAssertFalse(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPad13,8"))
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("iPad13,8", for: .compat13_7), "iPad8,6")
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("iPhone17,2", for: .compat13_7), "iPhone12,5")
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("iPad6,7", for: .compat13_7), "iPad6,7")
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("iPad13,8", for: .automatic), "iPad13,8")
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("", for: .automatic), "iPad13,8")
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("   ", for: .automatic), "iPad13,8")
        XCTAssertEqual(ReportedIOSVersionMode.effectiveDeviceModel("", for: .compat13_7), "iPad8,6")

        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("13.0", higherThan: 13, minor: 7))
        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("13.7", higherThan: 13, minor: 7))
        XCTAssertTrue(ReportedIOSVersionMode.isMinimumOSVersion("13.7.1", higherThan: 13, minor: 7))
        XCTAssertTrue(ReportedIOSVersionMode.isMinimumOSVersion("14.0", higherThan: 13, minor: 7))
        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("12.4", higherThan: 13, minor: 7))
        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("", higherThan: 13, minor: 7))

        XCTAssertEqual(PlayCoverRestartField.allCases.count, 27)
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.windowCompatibility))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.frameRateTarget))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.reportedIOSVersion))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.interceptInlineSyscalls))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.strictEmulationMode))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.strictViewportOrientation))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.strictViewportScaleMode))
    }
}
