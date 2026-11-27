import Foundation
import Synchronization
import Testing
@testable import PlayCoverCore

@Suite(.serialized)
struct PlayCoverCoreSPMTests {
    @Test
    func networkRuleParserAndPlayRules() {
        #expect(NetworkRuleParser.isRuleEnabled("example.com"))
        #expect(!NetworkRuleParser.isRuleEnabled("#!OFF example.com"))
        #expect(NetworkRuleParser.isImportableRuleLine("DOMAIN-SUFFIX,example.com"))
        #expect(!NetworkRuleParser.isImportableRuleLine("   # comment"))

        let blockMeta = NetworkRuleParser.classifyRule("api.tracker.example # telemetry")
        #expect(blockMeta.isEnabled)
        #expect(!blockMeta.isAllow)
        #expect(NetworkRuleParser.stripInlineComment(blockMeta.body) == "api.tracker.example")

        let allowMeta = NetworkRuleParser.classifyRule("!https://allowed.example/path")
        #expect(allowMeta.isAllow)
        #expect(NetworkRuleParser.normalizedAllowRule("allowed.example") == "@@allowed.example")

        let built = PlayRules.buildRules(rules: ["host-a", "HOST-B"], bundleID: "com.example.game")
        #expect(!built.isEmpty)
        let template = RuleTemplate(data: ["bundle": "com.example.game"])
        #expect(template.render(template: "id=${bundle}") == "id=com.example.game")
    }

    @Test
    func urlExtensionsAndAppInfoRoundTrip() throws {
        #expect("hello world".esc == "hello\\ world")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverCoreSPMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let escaped = tmpDir.appendingEscapedPathComponent("a/b")
        #expect(escaped.lastPathComponent == "a:b")

        let sampleFile = tmpDir.appendingPathComponent("sample.bin")
        try Data("playcover".utf8).write(to: sampleFile)
        #expect(sampleFile.sha256?.count == 64)

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
        #expect(info.bundleIdentifier == "com.example.spm")
        #expect(info.executableName == "SampleApp")
        info.setApplicationCategoryType(.games, persist: true)
        info.assert(minimumVersion: 14.0)
        try info.write()

        let reloaded = AppInfo(contentsOf: plistURL)
        #expect(reloaded.applicationCategoryType == .games)
        #expect(reloaded.minimumOSVersion == "14.0")
    }

    @Test
    func playCoverDiagnosticsThreadSafeHooksAndReset() {
        defer { PlayCoverDiagnostics.reset() }
        struct CapturedState {
            var logs: [(String, Bool)] = []
            var errors: [String] = []
            var messages: [String] = []
            var toasts: [(PlayCoverDiagnosticToastKind, String)] = []
        }
        let captured = Mutex(CapturedState())

        PlayCoverDiagnostics.configure(
            logHandler: { msg, isError in captured.withLock { $0.logs.append((msg, isError)) } },
            errorHandler: { msg in captured.withLock { $0.errors.append(msg) } },
            messageHandler: { msg in captured.withLock { $0.messages.append(msg) } },
            toastHandler: { kind, msg, _ in captured.withLock { $0.toasts.append((kind, msg)) } },
            activeToastChecker: { $0 == .network }
        )

        PlayCoverDiagnostics.log("hello", isError: false)
        PlayCoverDiagnostics.reportError(PlayCoverError.infoPlistNotFound)
        PlayCoverDiagnostics.reportMessage("done")
        PlayCoverDiagnostics.showToast(toastType: .notice, toastDetails: "toast-body")

        let snap = captured.withLock { $0 }
        #expect(snap.logs.count == 1)
        #expect(snap.errors.count == 1)
        #expect(snap.messages == ["done"])
        #expect(snap.toasts.first?.0 == .notice)
        #expect(PlayCoverDiagnostics.hasActiveToast(ofType: .network))
        #expect(!PlayCoverDiagnostics.hasActiveToast(ofType: .error))

        PlayCoverDiagnostics.reset()
        #expect(!PlayCoverDiagnostics.hasActiveToast(ofType: .network))
    }

    @Test
    func windowCompatibilityAndPixelBudgetModels() {
        #expect(WindowCompatibilityMode(inverseScreenValues: false, windowFixMethod: 0) == .standard)
        #expect(WindowCompatibilityMode(inverseScreenValues: false, windowFixMethod: 1) == .standard)
        #expect(WindowCompatibilityMode(inverseScreenValues: true, windowFixMethod: 0) == .invertedMetrics)
        #expect(WindowCompatibilityMode(inverseScreenValues: true, windowFixMethod: 1) == .invertedLegacyResize)

        #expect(!WindowCompatibilityMode.standard.legacyValues.inverseScreenValues)
        #expect(WindowCompatibilityMode.standard.legacyValues.windowFixMethod == 0)
        #expect(!WindowCompatibilityMode.standard.requiresAdaptiveResolutionOff)

        #expect(WindowCompatibilityMode.invertedMetrics.legacyValues.inverseScreenValues)
        #expect(WindowCompatibilityMode.invertedMetrics.legacyValues.windowFixMethod == 0)
        #expect(!WindowCompatibilityMode.invertedMetrics.requiresAdaptiveResolutionOff)

        #expect(WindowCompatibilityMode.invertedLegacyResize.legacyValues.inverseScreenValues)
        #expect(WindowCompatibilityMode.invertedLegacyResize.legacyValues.windowFixMethod == 1)
        #expect(WindowCompatibilityMode.invertedLegacyResize.requiresAdaptiveResolutionOff)

        let gib: UInt64 = 1_073_741_824
        #expect(PixelBudget.limit == 2_621_440.0 * 2.0)
        #expect(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 8 * gib) == 4_500_000)
        #expect(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 16 * gib) == 6_000_000)
        #expect(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 24 * gib) == 9_000_000)
        #expect(PixelBudget.adaptiveLimit(forPhysicalMemoryBytes: 32 * gib) == 12_000_000)

        let okBudget = PixelBudget(width: 1920, height: 1080, scaler: 1.0, physicalMemoryBytes: 8 * gib)
        #expect(abs(okBudget.weightedPixels - 2_073_600) <= 0.5)
        #expect(okBudget.renderedWidth == 1920)
        #expect(okBudget.renderedHeight == 1080)
        #expect(!okBudget.exceedsMaxTextureEdge)
        #expect(okBudget.level == .ok)

        let cautionBudget = PixelBudget(width: 1920, height: 1080, scaler: 2.0, physicalMemoryBytes: 24 * gib)
        #expect(abs(cautionBudget.weightedPixels - 8_294_400) <= 0.5)
        #expect(cautionBudget.renderedWidth == 3840)
        #expect(cautionBudget.renderedHeight == 2160)
        #expect(!cautionBudget.exceedsMaxTextureEdge)
        #expect(cautionBudget.level == .caution)

        let highMemBudget = PixelBudget(width: 1920, height: 1080, scaler: 2.0, physicalMemoryBytes: 32 * gib)
        #expect(highMemBudget.level == .ok)

        let edge4096Exact = PixelBudget(width: 2048, height: 1536, scaler: 2.0, physicalMemoryBytes: 32 * gib)
        #expect(edge4096Exact.renderedWidth == 4096)
        #expect(edge4096Exact.renderedHeight == 3072)
        #expect(!edge4096Exact.exceedsMaxTextureEdge)

        let edgeOver4096 = PixelBudget(width: 1920, height: 1080, scaler: 2.2, physicalMemoryBytes: 32 * gib)
        #expect(edgeOver4096.renderedWidth == 4224)
        #expect(edgeOver4096.renderedHeight == 2376)
        #expect(edgeOver4096.exceedsMaxTextureEdge)

        let overBudget = PixelBudget(width: 2560, height: 1440, scaler: 2.0, physicalMemoryBytes: 16 * gib)
        #expect(abs(overBudget.weightedPixels - 14_745_600) <= 0.5)
        #expect(overBudget.level == .over)
        #expect(overBudget.exceedsMaxTextureEdge)
        #expect(abs(overBudget.fittedScaler - 1.2) <= 0.001)
        let fitted = PixelBudget(
            width: 2560, height: 1440, scaler: overBudget.fittedScaler, physicalMemoryBytes: 16 * gib
        )
        #expect(fitted.level != .over)

        let over8GB = PixelBudget(width: 1920, height: 1080, scaler: 2.0, physicalMemoryBytes: 8 * gib)
        #expect(over8GB.level == .over)
        #expect(abs(over8GB.fittedScaler - 1.4) <= 0.001)
        #expect(
            PixelBudget(width: 1920, height: 1080, scaler: over8GB.fittedScaler, physicalMemoryBytes: 8 * gib).level
                != .over
        )

        #expect(PixelBudget(width: 0, height: 1080, scaler: 2.0).weightedPixels == 0)
        #expect(PixelBudget(width: 0, height: 1080, scaler: 2.0).renderedWidth == 0)
        #expect(PixelBudget(width: 0, height: 1080, scaler: 2.0).fittedScaler == 1.0)
        #expect(PixelBudget(width: 1920, height: 1080, scaler: -1.0).weightedPixels == 0)
        #expect(!PixelBudget(width: 1920, height: 1080, scaler: -1.0).exceedsMaxTextureEdge)

        let exactBoundary8GB = PixelBudget(width: 3000, height: 1500, scaler: 1.5, physicalMemoryBytes: 8 * gib)
        #expect(exactBoundary8GB.level == .over)
        #expect(abs(exactBoundary8GB.fittedScaler - 0.9) <= 0.001)
        let fittedBoundary8GB = PixelBudget(
            width: 3000,
            height: 1500,
            scaler: exactBoundary8GB.fittedScaler,
            physicalMemoryBytes: 8 * gib
        )
        #expect(fittedBoundary8GB.ratio < 1.0)
        #expect(fittedBoundary8GB.level != .over)

        let exactBoundary16GB = PixelBudget(width: 3000, height: 2000, scaler: 1.4, physicalMemoryBytes: 16 * gib)
        #expect(abs(exactBoundary16GB.fittedScaler - 0.9) <= 0.001)
        #expect(
            PixelBudget(
                width: 3000,
                height: 2000,
                scaler: exactBoundary16GB.fittedScaler,
                physicalMemoryBytes: 16 * gib
            ).ratio < 1.0
        )

        let extremeBudget = PixelBudget(width: 7680, height: 4320, scaler: 2.0, physicalMemoryBytes: 8 * gib)
        #expect(abs(extremeBudget.fittedScaler - 0.5) <= 0.001)
    }

    @Test
    func strictEmulationEnumsAndDeviceDisplaySpecs() {
        #expect(StrictViewportOrientation(rawSetting: nil) == .landscape)
        #expect(StrictViewportOrientation(rawSetting: " Portrait \n") == .portrait)
        #expect(StrictViewportOrientation(rawSetting: "bogus") == .landscape)
        #expect(StrictViewportOrientation.landscape.displayRotationTag == 0)
        #expect(StrictViewportOrientation.portrait.displayRotationTag == 1)

        #expect(StrictViewportScaleMode(rawSetting: nil) == .fitScreen)
        #expect(StrictViewportScaleMode(rawSetting: "native1x") == .native1x)
        #expect(StrictViewportScaleMode(rawSetting: "NATIVE") == .native1x)
        #expect(StrictViewportScaleMode(rawSetting: "unknown") == .fitScreen)

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
            #expect(spec.portraitPixelWidth == pxW)
            #expect(spec.portraitPixelHeight == pxH)
            #expect(spec.nativeScale == scale)
            #expect(spec.maxFrameRateHz == fps)
            #expect(spec.isIPad == isIPad)
        }

        let m4Pad = StrictDeviceDisplaySpec.resolve(for: "iPad16,6")
        #expect(m4Pad.isMSeriesIPad)
        #expect(m4Pad.logicalSize(orientation: .portrait).width == 1032)
        #expect(m4Pad.logicalSize(orientation: .portrait).height == 1376)
        #expect(m4Pad.logicalSize(orientation: .landscape).width == 1376)
        #expect(m4Pad.logicalSize(orientation: .landscape).height == 1032)

        let a12xPad = StrictDeviceDisplaySpec.resolve(for: "iPad8,6")
        #expect(!a12xPad.isMSeriesIPad)

        let unknownPhone = StrictDeviceDisplaySpec.resolve(for: "iPhone99,1")
        #expect(!unknownPhone.isIPad)
        #expect(unknownPhone.nativeScale == 3.0)
        #expect(unknownPhone.portraitPixelWidth == 1320)

        let unknownPad = StrictDeviceDisplaySpec.resolve(for: "")
        #expect(unknownPad.isIPad)
        #expect(unknownPad.nativeScale == 2.0)
        #expect(unknownPad.portraitPixelWidth == 2048)
    }

    @Test
    func frameRateTargetReportedIOSVersionAndRestartFields() {
        #expect(FrameRateTarget(rawSetting: nil) == .adaptive)
        #expect(FrameRateTarget.adaptive.targetHz == nil)
        #expect(FrameRateTarget(rawSetting: "unknown") == .adaptive)
        #expect(FrameRateTarget(rawSetting: " 120 ").targetHz == 120)
        #expect(FrameRateTarget(rawSetting: "60Hz").targetHz == 60)
        #expect(FrameRateTarget(rawSetting: "fixed30").targetHz == 30)

        #expect(ReportedIOSVersionMode(rawSetting: nil) == .automatic)
        #expect(ReportedIOSVersionMode(rawSetting: "unexpected") == .automatic)
        #expect(ReportedIOSVersionMode(rawSetting: "follow_host") == .followHost)
        #expect(ReportedIOSVersionMode(rawSetting: "host") == .followHost)
        #expect(ReportedIOSVersionMode(rawSetting: "18.3") == .compat18_3)
        #expect(ReportedIOSVersionMode(rawSetting: "ios18_3") == .compat18_3)
        #expect(ReportedIOSVersionMode.compat18_3Version == "18.3")
        #expect(ReportedIOSVersionMode.compat18_3Build == "22D63")
        #expect(ReportedIOSVersionMode.compat18_3KernelRelease == "24.3.0")

        #expect(ReportedIOSVersionMode(rawSetting: "compat13_7") == .compat13_7)
        #expect(ReportedIOSVersionMode(rawSetting: "13.7") == .compat13_7)
        #expect(ReportedIOSVersionMode(rawSetting: "ios13_7") == .compat13_7)
        #expect(ReportedIOSVersionMode.compat13_7Version == "13.7")
        #expect(ReportedIOSVersionMode.compat13_7Build == "17H35")
        #expect(ReportedIOSVersionMode.compat13_7KernelRelease == "19.6.0")
        #expect(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPad6,7"))
        #expect(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPad8,6"))
        #expect(ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPhone12,5"))
        #expect(!ReportedIOSVersionMode.supportsIOS13(deviceModel: "iPad13,8"))
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad13,8", for: .compat13_7) == "iPad8,6")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPhone17,2", for: .compat13_7) == "iPhone12,5")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad6,7", for: .compat13_7) == "iPad6,7")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad13,8", for: .automatic) == "iPad13,8")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("", for: .automatic) == "iPad13,8")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("   ", for: .automatic) == "iPad13,8")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("", for: .compat13_7) == "iPad8,6")

        #expect(!ReportedIOSVersionMode.isMinimumOSVersion("13.0", higherThan: 13, minor: 7))
        #expect(!ReportedIOSVersionMode.isMinimumOSVersion("13.7", higherThan: 13, minor: 7))
        #expect(ReportedIOSVersionMode.isMinimumOSVersion("13.7.1", higherThan: 13, minor: 7))
        #expect(ReportedIOSVersionMode.isMinimumOSVersion("14.0", higherThan: 13, minor: 7))
        #expect(!ReportedIOSVersionMode.isMinimumOSVersion("12.4", higherThan: 13, minor: 7))
        #expect(!ReportedIOSVersionMode.isMinimumOSVersion("", higherThan: 13, minor: 7))

        #expect(PlayCoverRestartField.allCases.count == 28)
        #expect(PlayCoverRestartField.allCases.contains(.networkProxy))
        #expect(PlayCoverRestartField.allCases.contains(.windowCompatibility))
        #expect(PlayCoverRestartField.allCases.contains(.frameRateTarget))
        #expect(PlayCoverRestartField.allCases.contains(.reportedIOSVersion))
        #expect(PlayCoverRestartField.allCases.contains(.interceptInlineSyscalls))
        #expect(PlayCoverRestartField.allCases.contains(.strictEmulationMode))
        #expect(PlayCoverRestartField.allCases.contains(.strictViewportOrientation))
        #expect(PlayCoverRestartField.allCases.contains(.strictViewportScaleMode))
    }

    @Test
    func networkVMConnectivityCheckIsThreadSafeAndFast() async {
        let initial = NetworkVM.isConnectedToNetwork()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    NetworkVM.isConnectedToNetwork()
                }
            }
            var collected: [Bool] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == initial })
    }
}
