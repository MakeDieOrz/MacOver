import Darwin
import Foundation
import XCTest

final class PlaySettingsTests: XCTestCase {
    private var tempDir: URL?
    private var savedEnv: [String: String?] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        for key in ["CFFIXED_USER_HOME", "HOME", "PLAYTOOLS_SETTINGS_PLIST"] {
            if let val = getenv(key) {
                savedEnv[key] = String(cString: val)
            } else {
                savedEnv[key] = .some(nil)
            }
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayToolsSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        for (key, val) in savedEnv {
            if let str = val {
                setenv(key, str, 1)
            } else {
                unsetenv(key)
            }
        }
        savedEnv.removeAll()
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testAppSettingsDataAndDiscordActivityCodableRoundTrip() throws {
        var original = AppSettingsData()
        original.bundleIdentifier = "com.example.pt"
        original.sensitivity = 75.0
        original.customScaler = 1.75
        original.iosDeviceModel = "iPhone16,2"
        original.blockedURLPatterns = ["ads.example.com"]
        original.discordActivity.enable = true
        original.discordActivity.applicationID = "98765"

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let plistData = try encoder.encode(original)
        let decodedPlist = try PropertyListDecoder().decode(AppSettingsData.self, from: plistData)
        XCTAssertEqual(decodedPlist, original)

        let json = """
        {
          "bundleIdentifier": "com.example.numeric",
          "sensitivity": 40,
          "customScaler": 3,
          "keymappingDisabledAt": 8.5
        }
        """
        let decodedJSON = try JSONDecoder().decode(AppSettingsData.self, from: Data(json.utf8))
        XCTAssertEqual(decodedJSON.sensitivity, 40.0)
        XCTAssertEqual(decodedJSON.customScaler, 3.0)
        XCTAssertEqual(decodedJSON.keymappingDisabledAt, 8.5)

        let empty = try JSONDecoder().decode(AppSettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AppSettingsData())
    }

    func testResolveHostUserRootHandlesContainerFirmlinkAndHome() {
        unsetenv("PLAYTOOLS_SETTINGS_PLIST")
        setenv("CFFIXED_USER_HOME", "/System/Volumes/Data/Users/alice/Library/Containers/com.app/Data", 1)
        XCTAssertEqual(PlaySettings.resolveHostUserRoot(), "/Users/alice")

        unsetenv("CFFIXED_USER_HOME")
        setenv("HOME", "/Users/bob/Desktop", 1)
        XCTAssertEqual(PlaySettings.resolveHostUserRoot(), "/Users/bob")
    }

    func testResolveSettingsURLOverrideAndContainerFallback() throws {
        let dir = try XCTUnwrap(tempDir)
        let overrideURL = dir.appendingPathComponent("override.plist")
        setenv("PLAYTOOLS_SETTINGS_PLIST", overrideURL.path, 1)
        XCTAssertEqual(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "com.example.app").path,
            overrideURL.path
        )

        unsetenv("PLAYTOOLS_SETTINGS_PLIST")
        let fakeUserRoot = dir.appendingPathComponent("userroot", isDirectory: true)
        let appSettingsDir = fakeUserRoot
            .appendingPathComponent("Library/Containers/app.makedie.MacOver/App Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSettingsDir, withIntermediateDirectories: true)

        let containerPath = fakeUserRoot
            .appendingPathComponent("Library/Containers/com.container.id/Data", isDirectory: true).path
        setenv("CFFIXED_USER_HOME", containerPath, 1)

        let altPlist = appSettingsDir.appendingPathComponent("com.container.id.plist")
        try Data("{}".utf8).write(to: altPlist)
        XCTAssertEqual(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "com.missing.primary").path,
            altPlist.path
        )

        let primaryPlist = appSettingsDir.appendingPathComponent("com.primary.id.plist")
        try Data("{}".utf8).write(to: primaryPlist)
        XCTAssertEqual(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "com.primary.id").path,
            primaryPlist.path
        )
    }

    func testPlaySettingsInitFromURLOemIDAndKeymappingDisabledAtPersistence() throws {
        let dir = try XCTUnwrap(tempDir)
        let settingsURL = dir.appendingPathComponent("com.example.test.plist")

        var initial = AppSettingsData()
        initial.bundleIdentifier = "com.example.test"
        initial.iosDeviceModel = "iPhone16,2"
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(initial)
        let plistDict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        var mutableDict = plistDict
        mutableDict["customUnrelatedKey"] = "keep-me"
        let customData = try PropertyListSerialization.data(fromPropertyList: mutableDict, format: .xml, options: 0)
        try customData.write(to: settingsURL)

        let loaded = PlaySettings(settingsURL: settingsURL, bundleIdentifier: "com.example.test")
        XCTAssertEqual(loaded.oemID as String, "D84AP")

        loaded.keymappingDisabledAt = 42.5
        let persistedData = try Data(contentsOf: settingsURL)
        let persistedDict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: persistedData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(persistedDict["customUnrelatedKey"] as? String, "keep-me")
        XCTAssertEqual((persistedDict["keymappingDisabledAt"] as? NSNumber)?.floatValue, 42.5)

        let corruptURL = dir.appendingPathComponent("corrupt.plist")
        try Data("not-a-plist".utf8).write(to: corruptURL)
        let fallback = PlaySettings(settingsURL: corruptURL, bundleIdentifier: "com.corrupt.app")
        XCTAssertEqual(fallback.settingsData.bundleIdentifier, "com.corrupt.app")
        XCTAssertEqual(fallback.oemID as String, "J522AP")
    }

    func testResolveHostUserRootAndSettingsURLBoundaries() throws {
        let dir = try XCTUnwrap(tempDir)
        let fakeUserRoot = dir.appendingPathComponent("root", isDirectory: true)
        let appSettingsDir = fakeUserRoot
            .appendingPathComponent("Library/Containers/app.makedie.MacOver/App Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSettingsDir, withIntermediateDirectories: true)

        // Relative PLAYTOOLS_SETTINGS_PLIST must be ignored
        setenv("PLAYTOOLS_SETTINGS_PLIST", "relative/path.plist", 1)
        let containerPath = fakeUserRoot
            .appendingPathComponent("Library/Containers/com.empty.bid.container/Data", isDirectory: true).path
        setenv("CFFIXED_USER_HOME", containerPath, 1)

        XCTAssertEqual(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "").path,
            appSettingsDir.appendingPathComponent("com.empty.bid.container.plist").path
        )

        unsetenv("CFFIXED_USER_HOME")
        setenv("HOME", fakeUserRoot.path, 1)
        // Without /Users/... prefix, resolveHostUserRoot falls back to passwd / NSUserName;
        // verify empty bundleIdentifier resolves to "<resolvedRoot>/.../App Settings/.plist"
        let emptyNoContainer = PlaySettings.resolveSettingsURL(bundleIdentifier: "")
        XCTAssertEqual(emptyNoContainer.lastPathComponent, ".plist")
    }

    func testKeymappingPersistenceWithMissingDirArrayPlistAndReadOnlyDir() throws {
        let dir = try XCTUnwrap(tempDir)

        // Missing nested parent directory creation
        let nestedURL = dir.appendingPathComponent("a/b/c/com.nested.plist")
        let nested = PlaySettings(settingsURL: nestedURL, bundleIdentifier: "com.nested")
        nested.keymappingDisabledAt = 15.0
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
        let reloadedNested = PlaySettings(settingsURL: nestedURL, bundleIdentifier: "com.nested")
        XCTAssertEqual(reloadedNested.keymappingDisabledAt, 15.0)

        // Non-dict <array/> plist overwritten cleanly
        let arrayURL = dir.appendingPathComponent("com.array.plist")
        let arrayPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><array><string>stale</string></array></plist>
        """
        try Data(arrayPlist.utf8).write(to: arrayURL)
        let arraySettings = PlaySettings(settingsURL: arrayURL, bundleIdentifier: "com.array")
        arraySettings.keymappingDisabledAt = 22.0
        let overwritten = try PropertyListDecoder().decode(AppSettingsData.self, from: Data(contentsOf: arrayURL))
        XCTAssertEqual(overwritten.keymappingDisabledAt, 22.0)

        // Read-only parent directory fails silently without leaving .tmp behind
        let roDir = dir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let roURL = roDir.appendingPathComponent("com.ro.plist")
        let roSettings = PlaySettings(settingsURL: roURL, bundleIdentifier: "com.ro")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: roDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: roDir.path)
        }
        roSettings.keymappingDisabledAt = 33.0
        XCTAssertFalse(FileManager.default.fileExists(atPath: roURL.appendingPathExtension("tmp").path))
    }

    func testAllOemIDsMixedTypePlistAndDiscordActivityResilience() throws {
        let dir = try XCTUnwrap(tempDir)
        let expectedOEMs: [(model: String, oem: String)] = [
            ("iPad6,7", "J98aAP"),
            ("iPad8,6", "J320xAP"),
            ("iPad13,8", "J522AP"),
            ("iPad14,5", "J620AP"),
            ("iPad16,6", "J720AP"),
            ("iPad17,3", "J820AP"),
            ("iPhone14,3", "D64AP"),
            ("iPhone15,3", "D74AP"),
            ("iPhone16,2", "D84AP"),
            ("iPhone17,2", "D94AP"),
            ("iPhone18,2", "D94xAP"),
            ("iPhone99,9", "J522AP")
        ]
        for (index, entry) in expectedOEMs.enumerated() {
            var data = AppSettingsData()
            data.iosDeviceModel = entry.model
            let url = dir.appendingPathComponent("oem_\(index).plist")
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(data).write(to: url)
            let ps = PlaySettings(settingsURL: url, bundleIdentifier: "com.oem.\(index)")
            XCTAssertEqual(ps.oemID as String, entry.oem)
        }

        // Mixed-type XML plist decoding
        let mixedURL = dir.appendingPathComponent("mixed.plist")
        let mixedPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>customScaler</key><integer>3</integer>
            <key>sensitivity</key><integer>40</integer>
            <key>keymapping</key><string>not-a-bool</string>
            <key>blockedURLPatterns</key><integer>42</integer>
            <key>discordActivity</key><integer>99</integer>
        </dict>
        </plist>
        """
        try Data(mixedPlist.utf8).write(to: mixedURL)
        let mixed = PlaySettings(settingsURL: mixedURL, bundleIdentifier: "com.mixed")
        XCTAssertEqual(mixed.customScaler, 3.0)
        XCTAssertEqual(mixed.sensitivity, 0.4, accuracy: 0.001)
        XCTAssertTrue(mixed.keymapping)
        XCTAssertEqual(mixed.settingsData.blockedURLPatterns, [])
        XCTAssertEqual(mixed.discordActivity, DiscordActivity())

        // DiscordActivity Equatable and malformed JSON resilience
        var a = DiscordActivity()
        a.enable = true
        a.details = "Stage 1"
        var b = a
        XCTAssertEqual(a, b)
        b.state = "Boss"
        XCTAssertNotEqual(a, b)

        let malformedDiscord = try JSONDecoder().decode(
            DiscordActivity.self,
            from: Data(#"{"enable":"bad","applicationID":123,"details":"ok"}"#.utf8)
        )
        XCTAssertFalse(malformedDiscord.enable)
        XCTAssertEqual(malformedDiscord.applicationID, "")
        XCTAssertEqual(malformedDiscord.details, "ok")
    }

    func testPlaySettingsConcurrentReadsKVCWritesAndSafeModeScalerFallback() throws {
        let dir = try XCTUnwrap(tempDir)
        let url = dir.appendingPathComponent("com.concurrent.test.plist")

        var data = AppSettingsData()
        data.bundleIdentifier = "com.concurrent.test"
        data.customScaler = 2.5
        data.windowWidth = 1920
        data.windowHeight = 1080
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(data).write(to: url)

        let ps = PlaySettings(settingsURL: url, bundleIdentifier: "com.concurrent.test")
        XCTAssertEqual(ps.customScaler, 2.5)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "pt.settings.stress", attributes: .concurrent)
        for i in 0..<64 {
            group.enter()
            queue.async {
                if i % 4 == 0 {
                    ps.setValue(NSNumber(value: 1600 + i), forKey: "windowSizeWidth")
                    ps.setValue(NSNumber(value: 900 + i), forKey: "windowSizeHeight")
                }
                _ = ps.bypass
                _ = ps.keymapping
                _ = ps.playChain
                _ = ps.deviceModel
                _ = ps.oemID
                _ = ps.windowSizeWidth
                _ = ps.windowSizeHeight
                _ = ps.customScaler
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        // When Safe Mode activates via shared instance, customScaler drops to native 1.0x
        let hadBreadcrumbBefore = FileManager.default.fileExists(atPath: PTSafeMode.shared.breadcrumbURL.path)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        XCTAssertTrue(PTSafeMode.isActive)
        XCTAssertEqual(ps.customScaler, 1.0)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        if !hadBreadcrumbBefore {
            PTSafeMode.shared.markGracefulTermination()
        }
        XCTAssertEqual(ps.customScaler, 2.5)
    }

    func testFrameRateRangeClampingAndSafeModeOverrides() throws {
        let dir = try XCTUnwrap(tempDir)
        let url = dir.appendingPathComponent("com.example.settings.test.plist")

        var data = AppSettingsData()
        data.bundleIdentifier = "com.example.settings.test"
        data.customScaler = 1.75
        data.inverseScreenValues = true
        data.windowFixMethod = 1
        data.frameRateTarget = "fixed60"
        data.reportedIOSVersion = "compat18_3"
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(data).write(to: url)

        let hadBreadcrumbBefore = FileManager.default.fileExists(atPath: PTSafeMode.shared.breadcrumbURL.path)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        defer {
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
            if !hadBreadcrumbBefore {
                PTSafeMode.shared.markGracefulTermination()
            }
        }

        let ps = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.test")
        XCTAssertFalse(PTSafeMode.isActive)
        XCTAssertTrue(ps.inverseScreenValues)
        XCTAssertEqual(ps.windowFixMethod, 1)
        XCTAssertEqual(ps.customScaler, 1.75)
        XCTAssertEqual(ps.frameRateTarget as String, "fixed60")
        XCTAssertEqual(ps.targetFrameRateHz, 60)
        XCTAssertEqual(ps.reportedIOSVersion as String, "compat18_3")

        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        XCTAssertTrue(PTSafeMode.isActive)
        XCTAssertFalse(ps.inverseScreenValues)
        XCTAssertEqual(ps.windowFixMethod, 0)
        XCTAssertEqual(ps.customScaler, 1.0)
        XCTAssertEqual(ps.targetFrameRateHz, 0)
        XCTAssertEqual(ps.frameRateTarget as String, "adaptive")
        XCTAssertEqual(ps.reportedIOSVersion as String, "automatic")

        XCTAssertEqual(
            PTFrameRateRangeValues(minimum: 30, maximum: 120, preferred: 120).clamped(toMaxHz: 60),
            PTFrameRateRangeValues(minimum: 30, maximum: 60, preferred: 60)
        )
        XCTAssertEqual(
            PTFrameRateRangeValues(minimum: 60, maximum: 120, preferred: 90).clamped(toMaxHz: 30),
            PTFrameRateRangeValues(minimum: 30, maximum: 30, preferred: 30)
        )
        XCTAssertEqual(
            PTFrameRateRangeValues(minimum: 0, maximum: 0, preferred: 0).clamped(toMaxHz: 60),
            PTFrameRateRangeValues(minimum: 60, maximum: 60, preferred: 60)
        )
        XCTAssertEqual(
            PTFrameRateRangeValues(minimum: 20, maximum: 24, preferred: 24).clamped(toMaxHz: 60),
            PTFrameRateRangeValues(minimum: 20, maximum: 24, preferred: 24)
        )
        XCTAssertEqual(
            PTFrameRateRangeValues(minimum: 30, maximum: 120, preferred: 90).clamped(toMaxHz: 0),
            PTFrameRateRangeValues(minimum: 30, maximum: 120, preferred: 90)
        )
        XCTAssertEqual(PTFrameRateRangeValues.clampedLegacyFPS(120, maxHz: 30), 30)
        XCTAssertEqual(PTFrameRateRangeValues.clampedLegacyFPS(24, maxHz: 60), 24)
        XCTAssertEqual(PTFrameRateRangeValues.clampedLegacyFPS(0, maxHz: 60), 60)
        XCTAssertEqual(PTFrameRateRangeValues.clampedLegacyFPS(120, maxHz: 0), 120)

        for rawVersion in ["compat13_7", "13.7", "ios13_7"] {
            var compat13Data = AppSettingsData()
            compat13Data.bundleIdentifier = "com.example.settings.compat13"
            compat13Data.reportedIOSVersion = rawVersion
            compat13Data.iosDeviceModel = "iPhone12,5"
            try encoder.encode(compat13Data).write(to: url)
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
            let ps13 = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.compat13")
            XCTAssertEqual(ps13.deviceModel as String, "iPhone12,5")
            XCTAssertEqual(ps13.oemID as String, "D431AP")
            XCTAssertEqual(ps13.reportedIOSVersion as String, "compat13_7")
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
            XCTAssertEqual(ps13.reportedIOSVersion as String, "automatic")
        }

        // Default iPad13,8 + compat13_7 coerces to iPad8,6 in normal mode and reverts in Safe Mode
        var mismatchedPad13 = AppSettingsData()
        mismatchedPad13.bundleIdentifier = "com.example.settings.compat13.pad"
        mismatchedPad13.reportedIOSVersion = "compat13_7"
        mismatchedPad13.iosDeviceModel = "iPad13,8"
        try encoder.encode(mismatchedPad13).write(to: url)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        let psPad13 = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.compat13.pad")
        XCTAssertEqual(psPad13.rawConfiguredDeviceModel as String, "iPad13,8")
        XCTAssertEqual(psPad13.deviceModel as String, "iPad8,6")
        XCTAssertEqual(psPad13.oemID as String, "J320xAP")
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        XCTAssertEqual(psPad13.deviceModel as String, "iPad13,8")
        XCTAssertEqual(psPad13.oemID as String, "J522AP")

        // Modern iPhone + compat13_7 (including whitespace) coerces to iPhone12,5 and restores in Safe Mode
        var mismatchedPhone13 = AppSettingsData()
        mismatchedPhone13.bundleIdentifier = "com.example.settings.compat13.phone"
        mismatchedPhone13.reportedIOSVersion = " compat13_7\n"
        mismatchedPhone13.iosDeviceModel = " iPhone17,2 "
        try encoder.encode(mismatchedPhone13).write(to: url)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        let psPhone13 = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.compat13.phone")
        XCTAssertEqual(psPhone13.rawConfiguredDeviceModel as String, "iPhone17,2")
        XCTAssertEqual(psPhone13.deviceModel as String, "iPhone12,5")
        XCTAssertEqual(psPhone13.oemID as String, "D431AP")
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        XCTAssertEqual(psPhone13.deviceModel as String, "iPhone17,2")
        XCTAssertEqual(psPhone13.oemID as String, "D94AP")
    }

    func testRightClickLongPressDefaultsAndDecodingPersistence() throws {
        let dir = try XCTUnwrap(tempDir)

        // Fresh AppSettingsData defaults rightClickLongPress to true
        let fresh = AppSettingsData()
        XCTAssertTrue(fresh.rightClickLongPress)

        // Legacy plist missing rightClickLongPress key defaults to true
        let legacyURL = dir.appendingPathComponent("com.legacy.rmb.plist")
        let legacyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>bundleIdentifier</key><string>com.legacy.rmb</string>
            <key>keymapping</key><true/>
        </dict>
        </plist>
        """
        try Data(legacyPlist.utf8).write(to: legacyURL)
        let legacyLoaded = PlaySettings(settingsURL: legacyURL, bundleIdentifier: "com.legacy.rmb")
        XCTAssertTrue(legacyLoaded.rightClickLongPress)

        // Explicit false value round-trips and loads accurately
        var disabled = AppSettingsData()
        disabled.bundleIdentifier = "com.disabled.rmb"
        disabled.rightClickLongPress = false
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let disabledURL = dir.appendingPathComponent("com.disabled.rmb.plist")
        try encoder.encode(disabled).write(to: disabledURL)

        let disabledLoaded = PlaySettings(settingsURL: disabledURL, bundleIdentifier: "com.disabled.rmb")
        XCTAssertFalse(disabledLoaded.rightClickLongPress)
        XCTAssertFalse(disabledLoaded.settingsData.rightClickLongPress)
    }

    private func makeStrictPortraitTestSettingsData() -> AppSettingsData {
        var data = AppSettingsData()
        data.bundleIdentifier = "com.example.strict.portrait"
        data.strictEmulationMode = true
        data.strictViewportOrientation = "portrait"
        data.strictViewportScaleMode = "native1x"
        data.iosDeviceModel = "iPhone15,3"
        data.bypass = false
        data.interceptInlineSyscalls = false
        data.rootWorkDir = false
        data.metalHUD = true
        data.playChainDebugging = true
        data.notch = true
        data.customScaler = 1.25
        data.resolution = 6
        data.windowFixMethod = 1
        data.inverseScreenValues = true
        data.displayRotation = 2
        data.windowWidth = 800
        data.windowHeight = 600
        return data
    }

    func testStrictEmulationModePortraitOverridesAndNonDestructiveDisk() throws {
        let dir = try XCTUnwrap(tempDir)
        let hadBreadcrumbBefore = FileManager.default.fileExists(atPath: PTSafeMode.shared.breadcrumbURL.path)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        defer {
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
            if !hadBreadcrumbBefore {
                PTSafeMode.shared.markGracefulTermination()
            }
        }

        let legacy = AppSettingsData()
        XCTAssertFalse(legacy.strictEmulationMode)
        XCTAssertEqual(legacy.strictViewportOrientation, "landscape")
        XCTAssertEqual(legacy.strictViewportScaleMode, "fitScreen")

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let portraitURL = dir.appendingPathComponent("com.example.strict.portrait.plist")
        try encoder.encode(makeStrictPortraitTestSettingsData()).write(to: portraitURL)

        let playSettings = PlaySettings(settingsURL: portraitURL, bundleIdentifier: "com.example.strict.portrait")
        XCTAssertTrue(playSettings.strictEmulationMode)
        XCTAssertEqual(playSettings.strictViewportOrientation as String, "portrait")
        XCTAssertEqual(playSettings.strictViewportScaleMode as String, "native1x")
        XCTAssertTrue(playSettings.isStrictPortraitOrientation)
        XCTAssertTrue(playSettings.bypass)
        XCTAssertTrue(playSettings.interceptInlineSyscalls)
        XCTAssertTrue(playSettings.rootWorkDir)
        XCTAssertFalse(playSettings.metalHUD)
        XCTAssertFalse(playSettings.playChainDebugging)
        XCTAssertFalse(playSettings.notch)
        XCTAssertFalse(playSettings.inverseScreenValues)
        XCTAssertEqual(playSettings.windowFixMethod, 0)
        XCTAssertTrue(playSettings.adaptiveDisplay)
        XCTAssertFalse(playSettings.resizableWindow)
        XCTAssertEqual(playSettings.customScaler, 3.0)
        XCTAssertEqual(playSettings.windowSizeWidth, 430)
        XCTAssertEqual(playSettings.windowSizeHeight, 932)
        XCTAssertEqual(playSettings.displayRotation, 1)

        // Persisting keymappingDisabledAt must NOT overwrite non-strict settings on disk
        playSettings.keymappingDisabledAt = 12.0
        let reloadedDisk = try PropertyListDecoder().decode(AppSettingsData.self, from: Data(contentsOf: portraitURL))
        XCTAssertFalse(reloadedDisk.bypass)
        XCTAssertTrue(reloadedDisk.notch)
        XCTAssertEqual(reloadedDisk.customScaler, 1.25)
        XCTAssertEqual(reloadedDisk.windowWidth, 800)
        XCTAssertEqual(reloadedDisk.windowHeight, 600)
        XCTAssertEqual(reloadedDisk.keymappingDisabledAt, 12.0)
    }

    func testStrictEmulationModeLandscapePadAndSafeModePrecedence() throws {
        let dir = try XCTUnwrap(tempDir)
        let hadBreadcrumbBefore = FileManager.default.fileExists(atPath: PTSafeMode.shared.breadcrumbURL.path)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        defer {
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
            if !hadBreadcrumbBefore {
                PTSafeMode.shared.markGracefulTermination()
            }
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        var landscapePad = AppSettingsData()
        landscapePad.bundleIdentifier = "com.example.strict.ipad"
        landscapePad.strictEmulationMode = true
        landscapePad.strictViewportOrientation = "landscape"
        landscapePad.strictViewportScaleMode = "fitScreen"
        landscapePad.iosDeviceModel = "iPad16,6"
        let padURL = dir.appendingPathComponent("com.example.strict.ipad.plist")
        try encoder.encode(landscapePad).write(to: padURL)
        let padSettings = PlaySettings(settingsURL: padURL, bundleIdentifier: "com.example.strict.ipad")
        XCTAssertEqual(padSettings.customScaler, 2.0)
        XCTAssertEqual(padSettings.windowSizeWidth, 1376)
        XCTAssertEqual(padSettings.windowSizeHeight, 1032)
        XCTAssertEqual(padSettings.displayRotation, 0)

        // Safe Mode still supersedes strict mode overrides cleanly
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        XCTAssertFalse(padSettings.strictEmulationMode)
        XCTAssertEqual(padSettings.customScaler, 1.0)
        XCTAssertFalse(padSettings.interceptInlineSyscalls)
    }

    func testSafeModeTruthyEnvFlagsAndPostMortemBreadcrumbPrecedence() throws {
        let dir = try XCTUnwrap(tempDir)
        let stateDir = dir.appendingPathComponent("SafeModeState", isDirectory: true)
        let safeMode = PTSafeMode(stateDirectory: stateDir, bundleIdentifier: "com.example.safemode")

        for truthy in ["1", "true", "YES", " True\n", "\tyes "] {
            XCTAssertTrue(
                safeMode.evaluateAndBeginLaunch(
                    environment: ["PLAYTOOLS_SAFE_MODE": truthy],
                    stabilityWindow: 5.0
                )
            )
            XCTAssertTrue(safeMode.isSafeModeActive)
        }

        for falsy in ["0", "false", "NO", " no "] {
            // Seed stale breadcrumb first; explicit falsy flag must still override it
            XCTAssertFalse(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
            XCTAssertTrue(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))

            XCTAssertFalse(
                safeMode.evaluateAndBeginLaunch(
                    environment: ["PLAYTOOLS_SAFE_MODE": falsy],
                    stabilityWindow: 5.0
                )
            )
            XCTAssertFalse(safeMode.isSafeModeActive)
            safeMode.markGracefulTermination()
        }

        // Unrecognized env flag falls through to post-mortem breadcrumb check
        XCTAssertFalse(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))
        XCTAssertTrue(
            safeMode.evaluateAndBeginLaunch(
                environment: ["PLAYTOOLS_SAFE_MODE": "maybe"],
                stabilityWindow: 5.0
            )
        )
        XCTAssertTrue(safeMode.isSafeModeActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeMode.lastTriggeredURL.path))
    }
}
