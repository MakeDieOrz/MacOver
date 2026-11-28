import Foundation
import SQLite3
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

        let lazyInfo = AppInfo(
            cachedPlistURL: plistURL,
            cachedFields: AppInfo.CachedFields(
                bundleIdentifier: "com.example.spm",
                bundleName: "SampleApp",
                displayName: "SampleApp",
                bundleVersion: "1.2.3",
                cfBundleVersion: "1",
                executableName: "SampleApp",
                installGeneration: "",
                primaryIconName: "CustomIcon"
            )
        )
        #expect(lazyInfo.bundleIdentifier == "com.example.spm")
        #expect(lazyInfo.primaryIconName == "CustomIcon")
        #expect(lazyInfo.minimumOSVersion == "14.0")
        #expect(lazyInfo.applicationCategoryType == .games)
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

        let hugeBudget = PixelBudget(width: 7680, height: 4320, scaler: 1e16, physicalMemoryBytes: 8 * gib)
        #expect(hugeBudget.renderedWidth == Int.max)
        #expect(hugeBudget.renderedHeight == Int.max)
        #expect(hugeBudget.exceedsMaxTextureEdge)
        let infBudget = PixelBudget(width: 7680, height: 4320, scaler: .infinity, physicalMemoryBytes: 8 * gib)
        #expect(infBudget.renderedWidth == 0)
        #expect(infBudget.renderedHeight == 0)
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

        #expect(PlayCoverRestartField.allCases.count == 33)
        #expect(PlayCoverRestartField.allCases.contains(.networkProxy))
        #expect(PlayCoverRestartField.allCases.contains(.windowCompatibility))
        #expect(PlayCoverRestartField.allCases.contains(.frameRateTarget))
        #expect(PlayCoverRestartField.allCases.contains(.reportedIOSVersion))
        #expect(PlayCoverRestartField.allCases.contains(.interceptInlineSyscalls))
        #expect(PlayCoverRestartField.allCases.contains(.enableAutomationBridge))
        #expect(PlayCoverRestartField.allCases.contains(.enableCustomCertificates))
        #expect(PlayCoverRestartField.allCases.contains(.mitmAllowPinningBypass))
        #expect(PlayCoverRestartField.allCases.contains(.hideProxyFromApp))
        #expect(PlayCoverRestartField.allCases.contains(.strictEmulationMode))
        #expect(PlayCoverRestartField.allCases.contains(.strictViewportOrientation))
        #expect(PlayCoverRestartField.allCases.contains(.strictViewportScaleMode))
        #expect(PlayCoverRestartField.allCases.contains(.injectIosFrameworks))
    }

    @Test
    func networkVMConnectivityCheckIsThreadSafeAndFast() async {
        let initial = await NetworkVM.isConnectedToNetworkAsync()
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

    @Test
    func appSettingsSchemaRoundTripMalformedFallbackAndOEMIDs() throws {
        var original = AppSettingsData()
        #expect(!original.quitOnWindowClose)
        original.bundleIdentifier = "com.example.schema"
        original.strictEmulationMode = true
        original.strictViewportOrientation = .portrait
        original.strictViewportScaleMode = .native1x
        original.iosDeviceModel = "iPhone15,3"
        original.bypass = false
        original.quitOnWindowClose = true

        let encoded = try PropertyListEncoder().encode(original)
        let decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.quitOnWindowClose)
        #expect(decoded.effectiveBypass)
        #expect(decoded.effectiveWindowWidth == 430)
        #expect(decoded.effectiveWindowHeight == 932)
        #expect(decoded.effectiveCustomScaler == 3.0)
        #expect(decoded.effectiveDisplayRotation == 1)
        #expect(StrictDeviceDisplaySpec.oemID(for: "iPhone15,3") == "D74AP")
        #expect(StrictDeviceDisplaySpec.oemID(for: "unknown") == "J522AP")

        let malformed = Data(#"{"sensitivity":"bad","customScaler":3,"strictViewportOrientation":99}"#.utf8)
        let tolerant = try JSONDecoder().decode(AppSettingsData.self, from: malformed)
        #expect(tolerant.sensitivity == 50)
        #expect(tolerant.customScaler == 3.0)
        #expect(tolerant.strictViewportOrientation == .landscape)
        #expect(tolerant.strictViewportScaleMode == .fitScreen)
        #expect(!tolerant.quitOnWindowClose)
    }

    @Test
    func keyCoverVaultStorePBKDF2PermsAndKeyEncryption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyCoverVaultSPM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeDir = root.appendingPathComponent("KeyCover", isDirectory: true)
        let chainDir = root.appendingPathComponent("PlayChain", isDirectory: true)
        try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)

        let vault = KeyCoverVaultStore(storeDirectory: storeDir)
        let record = try #require(vault.makePasswordVerifierRecord(password: "correct-horse", iterations: 10_000))
        try vault.writeRecord(record)

        let attrs = try FileManager.default.attributesOfItem(atPath: vault.recordURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        let loaded = try #require(vault.readRecord())
        #expect(vault.verify(password: "correct-horse", against: loaded))
        #expect(!vault.verify(password: "wrong-password", against: loaded))

        let selfRecord = vault.makeSelfGeneratedRecord(key: KeyCoverVaultStore.generateSecurePassword())
        try vault.writeRecord(selfRecord)
        #expect(vault.readRecord() == selfRecord)

        let key = KeyCoverKey(appBundleID: "com.example.vault", playChainDirectory: chainDir)
        try Data("sqlite-bytes".utf8).write(to: key.decryptedKeyDB)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: key.decryptedKeyDB.path + "-wal"))
        #expect(KeyCoverVaultStore.listKeychains(in: chainDir) == [key])
        #expect(KeyCoverVaultStore.unlockedCount(in: [key]) == 1)

        try key.encryptKeyDB(plainTextKey: "secret-pass")
        #expect(key.chainEncryptionStatus)
        #expect(!FileManager.default.fileExists(atPath: key.decryptedKeyDB.path))
        #expect(!FileManager.default.fileExists(atPath: key.decryptedKeyDB.path + "-wal"))
        #expect(key.canDecrypt(plainTextKey: "secret-pass"))
        #expect(!key.canDecrypt(plainTextKey: "bad-pass"))

        try key.decryptKeyDB(plainTextKey: "secret-pass")
        #expect(!key.chainEncryptionStatus)
        #expect(try Data(contentsOf: key.decryptedKeyDB) == Data("sqlite-bytes".utf8))
    }

    @Test
    func appSettingsPersistencePreservesDiskKeysAndAutoResolution() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsPersistenceSPM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settingsURL = dir.appendingPathComponent("com.example.app.plist")
        let initialPlist = try PropertyListSerialization.data(
            fromPropertyList: [
                "bundleIdentifier": "com.example.app",
                "keymappingDisabledAt": 42.5,
                "customExtraKey": "keep-me"
            ],
            format: .xml,
            options: 0
        )
        try initialPlist.write(to: settingsURL)

        var snapshot = try AppSettingsPersistence.decode(from: settingsURL)
        snapshot.bypass = false
        let persisted = try AppSettingsPersistence.encode(snapshot, to: settingsURL, preservingExistingKeys: true)
        #expect(persisted.keymappingDisabledAt == 42.5)

        let rawDisk = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: settingsURL), options: [], format: nil
        ) as? [String: Any]
        #expect(rawDisk?["customExtraKey"] as? String == "keep-me")
        #expect(rawDisk?["bypass"] as? Bool == false)

        let bakURL = AppSettingsPersistence.preserveUnreadableFileIfPresent(
            at: settingsURL,
            bundleIdentifier: "com.example.app"
        )
        #expect(bakURL != nil)
        #expect(FileManager.default.fileExists(atPath: settingsURL.appendingPathExtension("bak").path))

        let notchAuto = AppSettingsPersistence.autoResolution(screenWidth: 1512, screenHeight: 982, hasNotch: true)
        #expect(notchAuto.width == 1512)
        #expect(notchAuto.height == 945)
        let plainAuto = AppSettingsPersistence.autoResolution(screenWidth: 1920, screenHeight: 1080, hasNotch: false)
        #expect(plainAuto == (1920, 1080))
    }

    @Test
    func appRunStateTransitionsAndSortRanks() {
        #expect(AppRunState.idle.sortRank == 2)
        #expect(!AppRunState.idle.isRunning && !AppRunState.idle.isBusy)

        let prep = AppRunState.preparing(.verifying)
        #expect(prep.isStarting && prep.isBusy && !prep.isRunning)
        #expect(prep.sortRank == 1)
        #expect(AppLaunchStage.verifying.localizationKey == "app.state.preparing.verifying")
        #expect(AppLaunchStage.unlocking.localizationKey == "app.state.preparing.unlocking")
        #expect(AppLaunchStage.opening.localizationKey == "app.state.preparing.opening")

        #expect(AppRunState.launching.isStarting && AppRunState.launching.sortRank == 1)
        #expect(AppRunState.terminating.isTerminating && AppRunState.terminating.isBusy)
        #expect(AppRunState.terminating.sortRank == 1)

        let bgRunning = AppRunState.running(isActive: false)
        #expect(bgRunning.isRunning && !bgRunning.isActive && !bgRunning.isBusy)
        #expect(bgRunning.sortRank == 0)

        let fgRunning = AppRunState.running(isActive: true)
        #expect(fgRunning.isRunning && fgRunning.isActive && fgRunning.sortRank == 0)
    }

    @Test
    func reportedIOS183CoercionDisplayNormalizationAndNewRestartFields() {
        #expect(ReportedIOSVersionMode.supportsIOS18_3(deviceModel: "iPhone17,2"))
        #expect(!ReportedIOSVersionMode.supportsIOS18_3(deviceModel: "iPhone18,2"))
        #expect(ReportedIOSVersionMode.supportsIOS18_3(deviceModel: "iPad16,6"))
        #expect(!ReportedIOSVersionMode.supportsIOS18_3(deviceModel: "iPad17,3"))
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPhone18,2", for: .compat18_3) == "iPhone17,2")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad17,3", for: .compat18_3) == "iPad16,6")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPhone18,2", for: .automatic) == "iPhone18,2")

        let base = AppSettingsData()
        var updated = base
        updated.resolution = 2
        updated.aspectRatio = 2
        updated.normalizeDisplaySettings(previous: base)
        #expect(updated.windowWidth == 1728)
        #expect(updated.windowHeight == 1080)

        var customResize = base
        customResize.resizableAspectRatioType = 3
        customResize.normalizeDisplaySettings(previous: base)
        #expect(customResize.resizableAspectRatioWidth == 16)
        #expect(customResize.resizableAspectRatioHeight == 9)

        var resetResize = customResize
        resetResize.resizableAspectRatioType = 0
        resetResize.normalizeDisplaySettings(previous: customResize)
        #expect(resetResize.resizableAspectRatioWidth == 0)
        #expect(resetResize.resizableAspectRatioHeight == 0)

        var explicitWidth = base
        explicitWidth.windowWidth = 2560
        explicitWidth.normalizeDisplaySettings(previous: base)
        #expect(explicitWidth.windowWidth == 2560)

        var netChanged = base
        netChanged.enableCustomCertificates = true
        netChanged.mitmAllowPinningBypass = true
        netChanged.hideProxyFromApp = false
        let restartFields = netChanged.restartRequiredChanges(comparedTo: base)
        #expect(restartFields.contains(.enableCustomCertificates))
        #expect(restartFields.contains(.mitmAllowPinningBypass))
        #expect(restartFields.contains(.hideProxyFromApp))
    }

    @Test
    func shellBundleIdentifierValidationRejectsFlagsAndTraversal() {
        #expect(Shell.isValidBundleIdentifier("com.example.game"))
        #expect(Shell.isValidBundleIdentifier("app.makedie.MacOver"))
        #expect(Shell.isValidBundleIdentifier("com.a-b.c_1"))
        #expect(!Shell.isValidBundleIdentifier(""))
        #expect(!Shell.isValidBundleIdentifier("-globalDomain"))
        #expect(!Shell.isValidBundleIdentifier(".leading"))
        #expect(!Shell.isValidBundleIdentifier("trailing."))
        #expect(!Shell.isValidBundleIdentifier("nodot"))
        #expect(!Shell.isValidBundleIdentifier("com..double"))
        #expect(!Shell.isValidBundleIdentifier("../escape"))
        #expect(!Shell.isValidBundleIdentifier("com.bad/slash"))
        #expect(!Shell.isValidBundleIdentifier(String(repeating: "a.", count: 70)))

        #expect(throws: (any Error).self) {
            try Shell.setMetalHUD("-globalDomain", enabled: true)
        }
    }

    @Test
    func canonicalNetworkRuleEngineMatchesRuntimeSemantics() {
        let engine = CanonicalNetworkRuleEngine(rawPatterns: [
            "DOMAIN,exact.example.com",
            "DOMAIN-SUFFIX,suffix.example.com",
            "DOMAIN-KEYWORD,telemetry",
            "URL-REGEX,^https://api\\.example\\.com/v[0-9]{1,3}/events$,MOCK-200",
            "DOMAIN,drop.example.com,REJECT-DROP",
            "||ads.example.com^$third-party",
            "@@||safe.ads.example.com",
            "#!OFF DOMAIN,disabled.example.com"
        ])

        #expect(
            engine.evaluate(host: "exact.example.com", urlString: "https://exact.example.com/")
                == .block(.defaultBlock)
        )
        #expect(
            engine.evaluate(host: "sub.exact.example.com", urlString: "https://sub.exact.example.com/")
                == .pass
        )
        #expect(
            engine.evaluate(host: "a.suffix.example.com", urlString: "https://a.suffix.example.com/")
                == .block(.defaultBlock)
        )
        #expect(
            engine.evaluate(host: "notsuffix.example.com", urlString: "https://notsuffix.example.com/")
                == .pass
        )

        // DOMAIN-KEYWORD must inspect host only, not URL path
        #expect(
            engine.evaluate(host: "telemetry.app.com", urlString: "https://telemetry.app.com/")
                == .block(.defaultBlock)
        )
        #expect(
            engine.evaluate(host: "safe.app.com", urlString: "https://safe.app.com/telemetry/ping")
                == .pass
        )

        // URL-REGEX preserves commas inside quantifiers and honors per-rule action
        #expect(
            engine.evaluate(host: "api.example.com", urlString: "https://api.example.com/v12/events")
                == .block(.forceMock200)
        )
        #expect(
            engine.evaluate(host: "drop.example.com", urlString: "https://drop.example.com/ping")
                == .block(.forceFail)
        )

        // Adblock || with $options and @@ allow override
        #expect(
            engine.evaluate(host: "sub.ads.example.com", urlString: "https://sub.ads.example.com/ad")
                == .block(.defaultBlock)
        )
        #expect(
            engine.evaluate(host: "safe.ads.example.com", urlString: "https://safe.ads.example.com/ok")
                == .allow
        )
        #expect(
            engine.evaluate(host: "disabled.example.com", urlString: "https://disabled.example.com/")
                == .pass
        )

        // Tunnel host-level decision
        #expect(engine.evaluateHostForTunnel(host: "exact.example.com") == .block(.defaultBlock))
        #expect(engine.evaluateHostForTunnel(host: "sub.exact.example.com") == .pass)
        #expect(engine.evaluateHostForTunnel(host: "safe.ads.example.com") == .allow)
    }

    @Test
    func keyCoverVaultCheckpointsRealSQLiteWALAndRejectsTamperedGCM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyCoverWAL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = KeyCoverKey(appBundleID: "com.example.wal", playChainDirectory: root)
        var db: OpaquePointer?
        #expect(sqlite3_open(key.decryptedKeyDB.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO kv VALUES ('token', 'super-secret-wal');", nil, nil, nil) == SQLITE_OK)
        // Hold WAL contents on disk by disabling auto-checkpoint before closing
        #expect(sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO kv VALUES ('token2', 'wal-only-row');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        try key.encryptKeyDB(plainTextKey: "pass-123")
        #expect(key.chainEncryptionStatus)
        let encData = try Data(contentsOf: key.encryptedKeyDB)
        #expect(encData.starts(with: Data("MCKV1\0\0\0".utf8)))
        let encPerms = (try FileManager.default.attributesOfItem(
            atPath: key.encryptedKeyDB.path
        )[.posixPermissions] as? NSNumber)?.intValue
        #expect(encPerms == 0o600)

        // Wrong password must throw without deleting .keyCover
        #expect(throws: (any Error).self) {
            try key.decryptKeyDB(plainTextKey: "wrong-pass")
        }
        #expect(FileManager.default.fileExists(atPath: key.encryptedKeyDB.path))

        // Tampered ciphertext must fail authentication without deleting .keyCover
        var tampered = encData
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: key.encryptedKeyDB)
        #expect(!key.canDecrypt(plainTextKey: "pass-123"))
        #expect(throws: (any Error).self) {
            try key.decryptKeyDB(plainTextKey: "pass-123")
        }
        #expect(FileManager.default.fileExists(atPath: key.encryptedKeyDB.path))

        // Restore valid ciphertext, plant stale -wal sidecar, and verify decrypt removes it and keeps WAL rows
        try encData.write(to: key.encryptedKeyDB)
        let staleWAL = URL(fileURLWithPath: key.decryptedKeyDB.path + "-wal")
        try Data("stale-garbage-wal".utf8).write(to: staleWAL)

        try key.decryptKeyDB(plainTextKey: "pass-123")
        #expect(!FileManager.default.fileExists(atPath: staleWAL.path))
        let decPerms = (try FileManager.default.attributesOfItem(
            atPath: key.decryptedKeyDB.path
        )[.posixPermissions] as? NSNumber)?.intValue
        #expect(decPerms == 0o600)

        var reopened: OpaquePointer?
        #expect(sqlite3_open_v2(key.decryptedKeyDB.path, &reopened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { if let reopened { sqlite3_close(reopened) } }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(reopened, "SELECT v FROM kv WHERE k = 'token2';", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let value = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        #expect(value == "wal-only-row")
    }

    @Test
    func appInfoDefaultInstallGenerationKeyMatchesInstaller() {
        let missingPlist = URL(fileURLWithPath: "/nonexistent/Info.plist")
        let lazyInfo = AppInfo(
            cachedPlistURL: missingPlist,
            cachedFields: AppInfo.CachedFields(
                bundleIdentifier: "com.example.gen",
                bundleName: "Gen",
                displayName: "Gen",
                bundleVersion: "1.0",
                cfBundleVersion: "1",
                executableName: "Gen",
                installGeneration: "gen-42",
                primaryIconName: "AppIcon"
            )
        )
        #expect(lazyInfo[string: "PCInstallGeneration"] == "gen-42")
    }

    @Test
    func reportedIOSVersionModeEnforcesDeviceModelMinMaxBounds() {
        // iPad6,7 max iPadOS 16 -> coerced on 18.3 and 26, valid on 13.7
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad6,7", for: .compat13_7) == "iPad6,7")
        #expect(!ReportedIOSVersionMode.supportsIOS18_3(deviceModel: "iPad6,7"))
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad6,7", for: .compat18_3) == "iPad13,8")
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPad6,7", for: .automatic, hostIOSMajor: 26) == "iPad13,8"
        )

        // iPad8,6 valid on 18.3, coerced on iOS 26; iPhone12,5 valid on 13.7, 18.3, and 26 (PTSystemSpoofer parity)
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPad8,6", for: .compat18_3) == "iPad8,6")
        #expect(ReportedIOSVersionMode.effectiveDeviceModel("iPhone12,5", for: .compat18_3) == "iPhone12,5")
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPad8,6", for: .automatic, hostIOSMajor: 26) == "iPad13,8"
        )
        let iphone12On26 = ReportedIOSVersionMode.effectiveDeviceModel(
            "iPhone12,5",
            for: .followHost,
            hostIOSMajor: 26
        )
        #expect(iphone12On26 == "iPhone12,5")

        // iPhone18,2 / iPad17,3 min iOS 26 -> coerced to newest compatible model on iOS 17/18 and preserved on 26
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPhone18,2", for: .automatic, hostIOSMajor: 18) == "iPhone17,2"
        )
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPhone18,2", for: .automatic, hostIOSMajor: 17) == "iPhone16,2"
        )
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPad17,3", for: .automatic, hostIOSMajor: 18) == "iPad16,6"
        )
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPad17,3", for: .automatic, hostIOSMajor: 16) == "iPad14,5"
        )
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPhone18,2", for: .compat13_7) == "iPhone12,5"
        )
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPhone18,2", for: .automatic, hostIOSMajor: 26) == "iPhone18,2"
        )
        #expect(
            ReportedIOSVersionMode.effectiveDeviceModel("iPad17,3", for: .automatic, hostIOSMajor: 26) == "iPad17,3"
        )
    }

    @Test
    func appIntegrityDetectsCaseInsensitiveApplicationsPath() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("AppIntegrityTest-\(UUID().uuidString)")
        let fakeApps = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        let fakeDownloads = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: fakeApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeDownloads, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let lowerApp = fakeApps.appendingPathComponent("macover.app", isDirectory: true)
        let expectedApp = fakeApps.appendingPathComponent("MacOver.app", isDirectory: true)
        let downloadsApp = fakeDownloads.appendingPathComponent("MacOver.app", isDirectory: true)
        try fm.createDirectory(at: lowerApp, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloadsApp, withIntermediateDirectories: true)

        #expect(AppIntegrity.isURLInsideApplications(
            lowerApp,
            expectedAppURL: expectedApp,
            applicationsDirURL: fakeApps
        ))
        #expect(!AppIntegrity.isURLInsideApplications(
            downloadsApp,
            expectedAppURL: expectedApp,
            applicationsDirURL: fakeApps
        ))
    }

    @Test
    func appInfoConcurrentHydrationAndMutationIsThreadSafe() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppInfoConcurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.concurrent",
                "CFBundleName": "Concurrent",
                "CFBundleDisplayName": "Concurrent",
                "CFBundleShortVersionString": "1.0",
                "CFBundleExecutable": "Concurrent",
                "MinimumOSVersion": "15.0",
                "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: plistURL)

        let info = AppInfo(
            cachedPlistURL: plistURL,
            cachedFields: AppInfo.CachedFields(
                bundleIdentifier: "com.example.concurrent",
                bundleName: "Concurrent",
                displayName: "Concurrent",
                bundleVersion: "1.0",
                cfBundleVersion: "1",
                executableName: "Concurrent",
                installGeneration: "1",
                primaryIconName: "AppIcon"
            )
        )

        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<24 {
                group.addTask {
                    _ = info.minimumOSVersion
                    _ = info.primaryIconName
                    _ = info.lsEnvironment
                    _ = info.bundleIdentifier
                    info[string: "CustomKey\(idx % 4)"] = "val-\(idx)"
                }
            }
        }
        #expect(info.minimumOSVersion == "15.0")
        #expect(info.primaryIconName == "AppIcon60x60")
    }

    @Test
    func canonicalNetworkRuleEngineAllowRegexMatchesPTNetworkRulesParity() {
        // Grouped scheme+host allow regex exempts only matching hosts from tunnel block
        let grouped = CanonicalNetworkRuleEngine(rawPatterns: [
            "example.com",
            "@@/^https?://(api|cdn)\\.example\\.com(:443)?/v1/"
        ])
        #expect(grouped.evaluateHostForTunnel(host: "api.example.com") == .allow)
        #expect(grouped.evaluateHostForTunnel(host: "cdn.example.com") == .allow)
        #expect(grouped.evaluateHostForTunnel(host: "ads.example.com") == .block(.defaultBlock))

        // Scheme-less host-bounded allow regex exempts matching host without failing open globally
        let schemeless = CanonicalNetworkRuleEngine(rawPatterns: [
            "example.com",
            "@@/safe\\.example\\.com:8443/health/"
        ])
        #expect(schemeless.evaluateHostForTunnel(host: "safe.example.com") == .allow)
        #expect(schemeless.evaluateHostForTunnel(host: "tracker.example.com") == .block(.defaultBlock))

        // Broad canary-matching regex fails open (hostless) so tunnel isn't falsely blocked
        let canary = CanonicalNetworkRuleEngine(rawPatterns: [
            "example.com",
            "@@/^https?://.*/allow/"
        ])
        #expect(canary.evaluateHostForTunnel(host: "any.example.com") == .pass)
    }
}
