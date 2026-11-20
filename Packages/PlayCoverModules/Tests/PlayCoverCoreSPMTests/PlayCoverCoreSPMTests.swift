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

        let okBudget = PixelBudget(width: 1920, height: 1080, scaler: 1.5)
        XCTAssertEqual(okBudget.weightedPixels, 3_110_400, accuracy: 0.5)
        XCTAssertEqual(okBudget.level, .ok)

        let cautionBudget = PixelBudget(width: 1920, height: 1080, scaler: 2.0)
        XCTAssertEqual(cautionBudget.weightedPixels, 4_147_200, accuracy: 0.5)
        XCTAssertEqual(cautionBudget.level, .caution)

        let overBudget = PixelBudget(width: 2560, height: 1440, scaler: 2.0)
        XCTAssertEqual(overBudget.weightedPixels, 7_372_800, accuracy: 0.5)
        XCTAssertEqual(overBudget.level, .over)
        XCTAssertEqual(overBudget.fittedScaler, 1.4, accuracy: 0.001)
        XCTAssertNotEqual(PixelBudget(width: 2560, height: 1440, scaler: overBudget.fittedScaler).level, .over)

        XCTAssertEqual(PixelBudget(width: 0, height: 1080, scaler: 2.0).weightedPixels, 0)
        XCTAssertEqual(PixelBudget(width: 0, height: 1080, scaler: 2.0).fittedScaler, 1.0)
        XCTAssertEqual(PixelBudget(width: 1920, height: 1080, scaler: -1.0).weightedPixels, 0)
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

        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("13.0", higherThan: 13, minor: 7))
        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("13.7", higherThan: 13, minor: 7))
        XCTAssertTrue(ReportedIOSVersionMode.isMinimumOSVersion("13.7.1", higherThan: 13, minor: 7))
        XCTAssertTrue(ReportedIOSVersionMode.isMinimumOSVersion("14.0", higherThan: 13, minor: 7))
        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("12.4", higherThan: 13, minor: 7))
        XCTAssertFalse(ReportedIOSVersionMode.isMinimumOSVersion("", higherThan: 13, minor: 7))

        XCTAssertEqual(PlayCoverRestartField.allCases.count, 23)
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.windowCompatibility))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.frameRateTarget))
        XCTAssertTrue(PlayCoverRestartField.allCases.contains(.reportedIOSVersion))
    }
}
