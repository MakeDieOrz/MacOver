import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
enum PlayToolsGlobalStateScope {}

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
final class PlaySettingsTests {
    private let tempDir: URL
    private var savedEnv: [String: String?] = [:]

    init() throws {
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

    deinit {
        for (key, val) in savedEnv {
            if let str = val {
                setenv(key, str, 1)
            } else {
                unsetenv(key)
            }
        }
        savedEnv.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test
    func appSettingsDataAndDiscordActivityCodableRoundTrip() throws {
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
        #expect(decodedPlist == original)

        let json = """
        {
          "bundleIdentifier": "com.example.numeric",
          "sensitivity": 40,
          "customScaler": 3,
          "keymappingDisabledAt": 8.5
        }
        """
        let decodedJSON = try JSONDecoder().decode(AppSettingsData.self, from: Data(json.utf8))
        #expect(decodedJSON.sensitivity == 40.0)
        #expect(decodedJSON.customScaler == 3.0)
        #expect(decodedJSON.keymappingDisabledAt == 8.5)

        let empty = try JSONDecoder().decode(AppSettingsData.self, from: Data("{}".utf8))
        #expect(empty == AppSettingsData())
    }

    @Test
    func resolveHostUserRootHandlesContainerFirmlinkAndHome() {
        unsetenv("PLAYTOOLS_SETTINGS_PLIST")
        setenv("CFFIXED_USER_HOME", "/System/Volumes/Data/Users/alice/Library/Containers/com.app/Data", 1)
        #expect(PlaySettings.resolveHostUserRoot() == "/Users/alice")

        unsetenv("CFFIXED_USER_HOME")
        setenv("HOME", "/Users/bob/Desktop", 1)
        #expect(PlaySettings.resolveHostUserRoot() == "/Users/bob")
    }

    @Test
    func resolveSettingsURLOverrideAndContainerFallback() throws {
        let overrideURL = tempDir.appendingPathComponent("override.plist")
        setenv("PLAYTOOLS_SETTINGS_PLIST", overrideURL.path, 1)
        #expect(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "com.example.app").path == overrideURL.path
        )

        unsetenv("PLAYTOOLS_SETTINGS_PLIST")
        let fakeUserRoot = tempDir.appendingPathComponent("userroot", isDirectory: true)
        let appSettingsDir = fakeUserRoot
            .appendingPathComponent("Library/Containers/app.makedie.MacOver/App Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSettingsDir, withIntermediateDirectories: true)

        let containerPath = fakeUserRoot
            .appendingPathComponent("Library/Containers/com.container.id/Data", isDirectory: true).path
        setenv("CFFIXED_USER_HOME", containerPath, 1)

        let altPlist = appSettingsDir.appendingPathComponent("com.container.id.plist")
        try Data("{}".utf8).write(to: altPlist)
        #expect(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "com.missing.primary").path == altPlist.path
        )

        let primaryPlist = appSettingsDir.appendingPathComponent("com.primary.id.plist")
        try Data("{}".utf8).write(to: primaryPlist)
        #expect(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "com.primary.id").path == primaryPlist.path
        )
    }

    @Test
    func playSettingsInitFromURLOemIDAndKeymappingDisabledAtPersistence() throws {
        let settingsURL = tempDir.appendingPathComponent("com.example.test.plist")

        var initial = AppSettingsData()
        initial.bundleIdentifier = "com.example.test"
        initial.iosDeviceModel = "iPhone16,2"
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(initial)
        let plistDict = try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        var mutableDict = plistDict
        mutableDict["customUnrelatedKey"] = "keep-me"
        let customData = try PropertyListSerialization.data(fromPropertyList: mutableDict, format: .xml, options: 0)
        try customData.write(to: settingsURL)

        let loaded = PlaySettings(settingsURL: settingsURL, bundleIdentifier: "com.example.test")
        #expect((loaded.oemID as String) == "D84AP")
        #expect(!loaded.quitOnWindowClose)
        #expect(!loaded.currentQuitOnWindowClose())

        var updated = initial
        updated.quitOnWindowClose = true
        let updatedData = try encoder.encode(updated)
        try updatedData.write(to: settingsURL)
        #expect(loaded.currentQuitOnWindowClose())
        let reloaded = PlaySettings(settingsURL: settingsURL, bundleIdentifier: "com.example.test")
        #expect(reloaded.quitOnWindowClose)
        try customData.write(to: settingsURL)

        loaded.keymappingDisabledAt = 42.5
        let persistedData = try Data(contentsOf: settingsURL)
        let persistedDict = try #require(
            PropertyListSerialization.propertyList(from: persistedData, options: [], format: nil) as? [String: Any]
        )
        #expect((persistedDict["customUnrelatedKey"] as? String) == "keep-me")
        #expect((persistedDict["keymappingDisabledAt"] as? NSNumber)?.floatValue == 42.5)

        let corruptURL = tempDir.appendingPathComponent("corrupt.plist")
        try Data("not-a-plist".utf8).write(to: corruptURL)
        let fallback = PlaySettings(settingsURL: corruptURL, bundleIdentifier: "com.corrupt.app")
        #expect(fallback.settingsData.bundleIdentifier == "com.corrupt.app")
        #expect((fallback.oemID as String) == "J522AP")
    }

    @Test
    func resolveHostUserRootAndSettingsURLBoundaries() throws {
        let fakeUserRoot = tempDir.appendingPathComponent("root", isDirectory: true)
        let appSettingsDir = fakeUserRoot
            .appendingPathComponent("Library/Containers/app.makedie.MacOver/App Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSettingsDir, withIntermediateDirectories: true)

        // Relative PLAYTOOLS_SETTINGS_PLIST must be ignored
        setenv("PLAYTOOLS_SETTINGS_PLIST", "relative/path.plist", 1)
        let containerPath = fakeUserRoot
            .appendingPathComponent("Library/Containers/com.empty.bid.container/Data", isDirectory: true).path
        setenv("CFFIXED_USER_HOME", containerPath, 1)

        #expect(
            PlaySettings.resolveSettingsURL(bundleIdentifier: "").path ==
                appSettingsDir.appendingPathComponent("com.empty.bid.container.plist").path
        )

        unsetenv("CFFIXED_USER_HOME")
        setenv("HOME", fakeUserRoot.path, 1)
        // Without /Users/... prefix, resolveHostUserRoot falls back to passwd / NSUserName;
        // verify empty bundleIdentifier resolves to "<resolvedRoot>/.../App Settings/.plist"
        let emptyNoContainer = PlaySettings.resolveSettingsURL(bundleIdentifier: "")
        #expect(emptyNoContainer.lastPathComponent == ".plist")
    }

    @Test
    func keymappingPersistenceWithMissingDirArrayPlistAndReadOnlyDir() throws {
        // Missing nested parent directory creation
        let nestedURL = tempDir.appendingPathComponent("a/b/c/com.nested.plist")
        let nested = PlaySettings(settingsURL: nestedURL, bundleIdentifier: "com.nested")
        nested.keymappingDisabledAt = 15.0
        #expect(FileManager.default.fileExists(atPath: nestedURL.path))
        let reloadedNested = PlaySettings(settingsURL: nestedURL, bundleIdentifier: "com.nested")
        #expect(reloadedNested.keymappingDisabledAt == 15.0)

        // Non-dict <array/> plist overwritten cleanly
        let arrayURL = tempDir.appendingPathComponent("com.array.plist")
        let arrayPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><array><string>stale</string></array></plist>
        """
        try Data(arrayPlist.utf8).write(to: arrayURL)
        let arraySettings = PlaySettings(settingsURL: arrayURL, bundleIdentifier: "com.array")
        arraySettings.keymappingDisabledAt = 22.0
        let overwritten = try PropertyListDecoder().decode(AppSettingsData.self, from: Data(contentsOf: arrayURL))
        #expect(overwritten.keymappingDisabledAt == 22.0)

        // Read-only parent directory fails silently without leaving .tmp behind
        let roDir = tempDir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let roURL = roDir.appendingPathComponent("com.ro.plist")
        let roSettings = PlaySettings(settingsURL: roURL, bundleIdentifier: "com.ro")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: roDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: roDir.path)
        }
        roSettings.keymappingDisabledAt = 33.0
        #expect(!FileManager.default.fileExists(atPath: roURL.appendingPathExtension("tmp").path))
    }

    @Test
    func allOemIDsMixedTypePlistAndDiscordActivityResilience() throws {
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
            let url = tempDir.appendingPathComponent("oem_\(index).plist")
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(data).write(to: url)
            let ps = PlaySettings(settingsURL: url, bundleIdentifier: "com.oem.\(index)")
            #expect((ps.oemID as String) == entry.oem)
        }

        // Mixed-type XML plist decoding
        let mixedURL = tempDir.appendingPathComponent("mixed.plist")
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
        #expect(mixed.customScaler == 3.0)
        #expect(abs(mixed.sensitivity - 0.4) <= 0.001)
        #expect(mixed.keymapping)
        #expect(mixed.settingsData.blockedURLPatterns == [])
        #expect(mixed.discordActivity == DiscordActivity())

        // DiscordActivity Equatable and malformed JSON resilience
        var a = DiscordActivity()
        a.enable = true
        a.details = "Stage 1"
        var b = a
        #expect(a == b)
        b.state = "Boss"
        #expect(a != b)

        let malformedDiscord = try JSONDecoder().decode(
            DiscordActivity.self,
            from: Data(#"{"enable":"bad","applicationID":123,"details":"ok"}"#.utf8)
        )
        #expect(!malformedDiscord.enable)
        #expect(malformedDiscord.applicationID == "")
        #expect(malformedDiscord.details == "ok")
    }

    @Test
    func playSettingsConcurrentReadsKVCWritesAndSafeModeScalerFallback() throws {
        let url = tempDir.appendingPathComponent("com.concurrent.test.plist")

        var data = AppSettingsData()
        data.bundleIdentifier = "com.concurrent.test"
        data.customScaler = 2.5
        data.windowWidth = 1920
        data.windowHeight = 1080
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(data).write(to: url)

        let ps = PlaySettings(settingsURL: url, bundleIdentifier: "com.concurrent.test")
        #expect(ps.customScaler == 2.5)

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
        #expect(group.wait(timeout: .now() + 5) == .success)

        // When Safe Mode activates via shared instance, customScaler drops to native 1.0x
        let hadBreadcrumbBefore = FileManager.default.fileExists(atPath: PTSafeMode.shared.breadcrumbURL.path)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        #expect(PTSafeMode.isActive)
        #expect(ps.customScaler == 1.0)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        if !hadBreadcrumbBefore {
            PTSafeMode.shared.markGracefulTermination()
        }
        #expect(ps.customScaler == 2.5)
    }

    @Test
    func frameRateRangeClampingAndSafeModeOverrides() throws {
        let url = tempDir.appendingPathComponent("com.example.settings.test.plist")

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
        #expect(!PTSafeMode.isActive)
        #expect(ps.inverseScreenValues)
        #expect(ps.windowFixMethod == 1)
        #expect(ps.customScaler == 1.75)
        #expect((ps.frameRateTarget as String) == "fixed60")
        #expect(ps.targetFrameRateHz == 60)
        #expect((ps.reportedIOSVersion as String) == "compat18_3")

        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        #expect(PTSafeMode.isActive)
        #expect(!ps.inverseScreenValues)
        #expect(ps.windowFixMethod == 0)
        #expect(ps.customScaler == 1.0)
        #expect(ps.targetFrameRateHz == 0)
        #expect((ps.frameRateTarget as String) == "adaptive")
        #expect((ps.reportedIOSVersion as String) == "automatic")

        #expect(
            PTFrameRateRangeValues(minimum: 30, maximum: 120, preferred: 120).clamped(toMaxHz: 60) ==
                PTFrameRateRangeValues(minimum: 30, maximum: 60, preferred: 60)
        )
        #expect(
            PTFrameRateRangeValues(minimum: 60, maximum: 120, preferred: 90).clamped(toMaxHz: 30) ==
                PTFrameRateRangeValues(minimum: 30, maximum: 30, preferred: 30)
        )
        #expect(
            PTFrameRateRangeValues(minimum: 0, maximum: 0, preferred: 0).clamped(toMaxHz: 60) ==
                PTFrameRateRangeValues(minimum: 60, maximum: 60, preferred: 60)
        )
        #expect(
            PTFrameRateRangeValues(minimum: 20, maximum: 24, preferred: 24).clamped(toMaxHz: 60) ==
                PTFrameRateRangeValues(minimum: 20, maximum: 24, preferred: 24)
        )
        #expect(
            PTFrameRateRangeValues(minimum: 30, maximum: 120, preferred: 90).clamped(toMaxHz: 0) ==
                PTFrameRateRangeValues(minimum: 30, maximum: 120, preferred: 90)
        )
        #expect(PTFrameRateRangeValues.clampedLegacyFPS(120, maxHz: 30) == 30)
        #expect(PTFrameRateRangeValues.clampedLegacyFPS(24, maxHz: 60) == 24)
        #expect(PTFrameRateRangeValues.clampedLegacyFPS(0, maxHz: 60) == 60)
        #expect(PTFrameRateRangeValues.clampedLegacyFPS(120, maxHz: 0) == 120)

        for rawVersion in ["compat13_7", "13.7", "ios13_7"] {
            var compat13Data = AppSettingsData()
            compat13Data.bundleIdentifier = "com.example.settings.compat13"
            compat13Data.reportedIOSVersion = rawVersion
            compat13Data.iosDeviceModel = "iPhone12,5"
            try encoder.encode(compat13Data).write(to: url)
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
            let ps13 = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.compat13")
            #expect((ps13.deviceModel as String) == "iPhone12,5")
            #expect((ps13.oemID as String) == "D431AP")
            #expect((ps13.reportedIOSVersion as String) == "compat13_7")
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
            #expect((ps13.reportedIOSVersion as String) == "automatic")
        }

        // Default iPad13,8 + compat13_7 coerces to iPad8,6 in normal mode and reverts in Safe Mode
        var mismatchedPad13 = AppSettingsData()
        mismatchedPad13.bundleIdentifier = "com.example.settings.compat13.pad"
        mismatchedPad13.reportedIOSVersion = "compat13_7"
        mismatchedPad13.iosDeviceModel = "iPad13,8"
        try encoder.encode(mismatchedPad13).write(to: url)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        let psPad13 = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.compat13.pad")
        #expect((psPad13.rawConfiguredDeviceModel as String) == "iPad13,8")
        #expect((psPad13.deviceModel as String) == "iPad8,6")
        #expect((psPad13.oemID as String) == "J320xAP")
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        #expect((psPad13.deviceModel as String) == "iPad13,8")
        #expect((psPad13.oemID as String) == "J522AP")

        // Modern iPhone + compat13_7 (including whitespace) coerces to iPhone12,5 and restores in Safe Mode
        var mismatchedPhone13 = AppSettingsData()
        mismatchedPhone13.bundleIdentifier = "com.example.settings.compat13.phone"
        mismatchedPhone13.reportedIOSVersion = " compat13_7\n"
        mismatchedPhone13.iosDeviceModel = " iPhone17,2 "
        try encoder.encode(mismatchedPhone13).write(to: url)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        let psPhone13 = PlaySettings(settingsURL: url, bundleIdentifier: "com.example.settings.compat13.phone")
        #expect((psPhone13.rawConfiguredDeviceModel as String) == "iPhone17,2")
        #expect((psPhone13.deviceModel as String) == "iPhone12,5")
        #expect((psPhone13.oemID as String) == "D431AP")
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        #expect((psPhone13.deviceModel as String) == "iPhone17,2")
        #expect((psPhone13.oemID as String) == "D94AP")
    }

    @Test
    func rightClickLongPressDefaultsAndDecodingPersistence() throws {
        // Fresh AppSettingsData defaults rightClickLongPress to true
        let fresh = AppSettingsData()
        #expect(fresh.rightClickLongPress)

        // Legacy plist missing rightClickLongPress key defaults to true
        let legacyURL = tempDir.appendingPathComponent("com.legacy.rmb.plist")
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
        #expect(legacyLoaded.rightClickLongPress)

        // Explicit false value round-trips and loads accurately
        var disabled = AppSettingsData()
        disabled.bundleIdentifier = "com.disabled.rmb"
        disabled.rightClickLongPress = false
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let disabledURL = tempDir.appendingPathComponent("com.disabled.rmb.plist")
        try encoder.encode(disabled).write(to: disabledURL)

        let disabledLoaded = PlaySettings(settingsURL: disabledURL, bundleIdentifier: "com.disabled.rmb")
        #expect(!disabledLoaded.rightClickLongPress)
        #expect(!disabledLoaded.settingsData.rightClickLongPress)
    }

    private func makeStrictPortraitTestSettingsData() -> AppSettingsData {
        var data = AppSettingsData()
        data.bundleIdentifier = "com.example.strict.portrait"
        data.strictEmulationMode = true
        data.strictViewportOrientation = .portrait
        data.strictViewportScaleMode = .native1x
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

    @Test
    func strictEmulationModePortraitOverridesAndNonDestructiveDisk() throws {
        let hadBreadcrumbBefore = FileManager.default.fileExists(atPath: PTSafeMode.shared.breadcrumbURL.path)
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
        defer {
            _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"])
            if !hadBreadcrumbBefore {
                PTSafeMode.shared.markGracefulTermination()
            }
        }

        let legacy = AppSettingsData()
        #expect(!legacy.strictEmulationMode)
        #expect(legacy.strictViewportOrientation == .landscape)
        #expect(legacy.strictViewportScaleMode == .fitScreen)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let portraitURL = tempDir.appendingPathComponent("com.example.strict.portrait.plist")
        try encoder.encode(makeStrictPortraitTestSettingsData()).write(to: portraitURL)

        let playSettings = PlaySettings(settingsURL: portraitURL, bundleIdentifier: "com.example.strict.portrait")
        #expect(playSettings.strictEmulationMode)
        #expect((playSettings.strictViewportOrientation as String) == "portrait")
        #expect((playSettings.strictViewportScaleMode as String) == "native1x")
        #expect(playSettings.isStrictPortraitOrientation)
        #expect(playSettings.bypass)
        #expect(playSettings.interceptInlineSyscalls)
        #expect(playSettings.rootWorkDir)
        #expect(!playSettings.metalHUD)
        #expect(!playSettings.playChainDebugging)
        #expect(!playSettings.notch)
        #expect(!playSettings.inverseScreenValues)
        #expect(playSettings.windowFixMethod == 0)
        #expect(playSettings.adaptiveDisplay)
        #expect(!playSettings.resizableWindow)
        #expect(playSettings.customScaler == 3.0)
        #expect(playSettings.windowSizeWidth == 430)
        #expect(playSettings.windowSizeHeight == 932)
        #expect(playSettings.displayRotation == 1)

        // Persisting keymappingDisabledAt must NOT overwrite non-strict settings on disk
        playSettings.keymappingDisabledAt = 12.0
        let reloadedDisk = try PropertyListDecoder().decode(AppSettingsData.self, from: Data(contentsOf: portraitURL))
        #expect(!reloadedDisk.bypass)
        #expect(reloadedDisk.notch)
        #expect(reloadedDisk.customScaler == 1.25)
        #expect(reloadedDisk.windowWidth == 800)
        #expect(reloadedDisk.windowHeight == 600)
        #expect(reloadedDisk.keymappingDisabledAt == 12.0)
    }

    @Test
    func strictEmulationModeLandscapePadAndSafeModePrecedence() throws {
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
        landscapePad.strictViewportOrientation = .landscape
        landscapePad.strictViewportScaleMode = .fitScreen
        landscapePad.iosDeviceModel = "iPad16,6"
        let padURL = tempDir.appendingPathComponent("com.example.strict.ipad.plist")
        try encoder.encode(landscapePad).write(to: padURL)
        let padSettings = PlaySettings(settingsURL: padURL, bundleIdentifier: "com.example.strict.ipad")
        #expect(padSettings.customScaler == 2.0)
        #expect(padSettings.windowSizeWidth == 1376)
        #expect(padSettings.windowSizeHeight == 1032)
        #expect(padSettings.displayRotation == 0)

        // Safe Mode still supersedes strict mode overrides cleanly
        _ = PTSafeMode.shared.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"])
        #expect(!padSettings.strictEmulationMode)
        #expect(padSettings.customScaler == 1.0)
        #expect(!padSettings.interceptInlineSyscalls)
    }

    @Test
    func safeModeTruthyEnvFlagsAndPostMortemBreadcrumbPrecedence() {
        let stateDir = tempDir.appendingPathComponent("SafeModeState", isDirectory: true)
        let safeMode = PTSafeMode(stateDirectory: stateDir, bundleIdentifier: "com.example.safemode")

        for truthy in ["1", "true", "YES", " True\n", "\tyes "] {
            #expect(
                safeMode.evaluateAndBeginLaunch(
                    environment: ["PLAYTOOLS_SAFE_MODE": truthy],
                    stabilityWindow: 5.0
                )
            )
            #expect(safeMode.isSafeModeActive)
        }

        for falsy in ["0", "false", "NO", " no "] {
            // Seed stale breadcrumb first; explicit falsy flag must still override it
            #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
            #expect(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))

            #expect(
                !safeMode.evaluateAndBeginLaunch(
                    environment: ["PLAYTOOLS_SAFE_MODE": falsy],
                    stabilityWindow: 5.0
                )
            )
            #expect(!safeMode.isSafeModeActive)
            safeMode.markGracefulTermination()
        }

        // Unrecognized env flag falls through to post-mortem breadcrumb check
        #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))
        #expect(
            safeMode.evaluateAndBeginLaunch(
                environment: ["PLAYTOOLS_SAFE_MODE": "maybe"],
                stabilityWindow: 5.0
            )
        )
        #expect(safeMode.isSafeModeActive)
        #expect(FileManager.default.fileExists(atPath: safeMode.lastTriggeredURL.path))
    }

    @Test
    func discordIPCClientPOSIXHandshakeSetActivityPingPongAndClear() throws {
        let sockPath = "/tmp/pt-ipc-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        _ = Darwin.unlink(sockPath)
        defer { _ = Darwin.unlink(sockPath) }

        let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(serverFD >= 0)
        defer { Darwin.close(serverFD) }

        var addr = sockaddr_un()
        let utf8 = sockPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        #expect(utf8.count > 0)
        #expect(utf8.count <= maxLen)
        guard utf8.count <= maxLen else { return }
        let pathOffset = try #require(MemoryLayout<sockaddr_un>.offset(of: \.sun_path))
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            utf8.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let addrLen = socklen_t(pathOffset + utf8.count)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, addrLen)
            }
        }
        #expect(bindRC == 0)
        #expect(Darwin.listen(serverFD, 2) == 0)

        let receivedFrames = Mutex<[(opcode: DiscordIPCClient.Opcode, jsonData: Data)]>([])
        let pongReceived = DispatchSemaphore(value: 0)
        let serverDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { serverDone.signal() }
            // Accept hasLiveDiscordSocket probe connection (closes immediately) or client connections
            for _ in 0..<2 {
                let connFD = Darwin.accept(serverFD, nil, nil)
                if connFD < 0 { break }
                defer { Darwin.close(connFD) }

                var tv = timeval(tv_sec: 3, tv_usec: 0)
                _ = Darwin.setsockopt(connFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                guard let hs = DiscordIPCClient.readFrame(fd: connFD) else { continue }
                receivedFrames.withLock { $0.append((hs.opcode, hs.payload)) }

                let readyData = Data(#"{"evt":"READY","cmd":"DISPATCH"}"#.utf8)
                #expect(DiscordIPCClient.writeFrame(fd: connFD, opcode: .frame, payload: readyData))

                // Read SET_ACTIVITY frame
                if let f1 = DiscordIPCClient.readFrame(fd: connFD) {
                    receivedFrames.withLock { $0.append((f1.opcode, f1.payload)) }
                }

                // Send PING and expect PONG back
                let pingData = Data(#"{"ping":1}"#.utf8)
                #expect(DiscordIPCClient.writeFrame(fd: connFD, opcode: .ping, payload: pingData))
                if let pong = DiscordIPCClient.readFrame(fd: connFD) {
                    receivedFrames.withLock { $0.append((pong.opcode, pong.payload)) }
                }
                pongReceived.signal()

                // Read clearPresence SET_ACTIVITY frame and CLOSE frame
                while let next = DiscordIPCClient.readFrame(fd: connFD) {
                    receivedFrames.withLock { $0.append((next.opcode, next.payload)) }
                    if next.opcode == .close {
                        break
                    }
                }
                break
            }
        }

        #expect(DiscordIPCClient.hasLiveDiscordSocket(paths: [sockPath]))
        let client = DiscordIPCClient(appId: "123456", socketPaths: [sockPath])
        #expect(client.connect())

        var activity = DiscordRichPresence()
        activity.details = "Playing Harness"
        activity.state = "Testing"
        activity.timestamps.start = 1_700_000_000
        activity.buttons = [DiscordRichPresence.Button(label: "MacOver", url: "https://example.test")]
        client.setPresence(activity)

        #expect(pongReceived.wait(timeout: .now() + 3.0) == .success)
        client.clearPresence()
        client.disconnect()

        #expect(serverDone.wait(timeout: .now() + 5.0) == .success)

        let frames: [(opcode: DiscordIPCClient.Opcode, json: [String: Any])] = receivedFrames.withLock { entries in
            entries.map { entry in
                let obj = (try? JSONSerialization.jsonObject(with: entry.jsonData) as? [String: Any]) ?? [:]
                return (entry.opcode, obj)
            }
        }

        #expect(frames.count >= 5)
        #expect(frames[0].opcode == .handshake)
        #expect((frames[0].json["v"] as? Int) == 1)
        #expect((frames[0].json["client_id"] as? String) == "123456")

        #expect(frames[1].opcode == .frame)
        #expect((frames[1].json["cmd"] as? String) == "SET_ACTIVITY")
        let args = try #require(frames[1].json["args"] as? [String: Any])
        let act = try #require(args["activity"] as? [String: Any])
        #expect((act["details"] as? String) == "Playing Harness")
        #expect((act["state"] as? String) == "Testing")

        #expect(frames[2].opcode == .pong)
        #expect((frames[2].json["ping"] as? Int) == 1)

        #expect(frames[3].opcode == .frame)
        #expect((frames[3].json["cmd"] as? String) == "SET_ACTIVITY")
        let clearedArgs = try #require(frames[3].json["args"] as? [String: Any])
        #expect(clearedArgs["activity"] is NSNull)

        #expect(frames.last?.opcode == .close)
    }

    @Test
    func discordIPCClientConcurrentStressAndBoundedDisconnect() throws {
        let sockPath = "/tmp/pt_ipc_stress_\(getpid())_\(UUID().uuidString.prefix(8)).sock"
        _ = Darwin.unlink(sockPath)
        defer { _ = Darwin.unlink(sockPath) }

        let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(serverFD >= 0)
        defer { Darwin.close(serverFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = sockPath.utf8CString
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        #expect(utf8.count > 0 && utf8.count <= maxPathLen)
        let pathOffset = try #require(MemoryLayout<sockaddr_un>.offset(of: \.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            utf8.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let addrLen = socklen_t(pathOffset + utf8.count)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(serverFD, $0, addrLen) }
        }
        #expect(bindRC == 0)
        #expect(Darwin.listen(serverFD, 4) == 0)

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { serverDone.signal() }
            while true {
                let connFD = Darwin.accept(serverFD, nil, nil)
                if connFD < 0 { break }
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                _ = Darwin.setsockopt(connFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if let hs = DiscordIPCClient.readFrame(fd: connFD), hs.opcode == .handshake {
                    let readyData = Data(#"{"evt":"READY","cmd":"DISPATCH"}"#.utf8)
                    _ = DiscordIPCClient.writeFrame(fd: connFD, opcode: .frame, payload: readyData)
                    while let next = DiscordIPCClient.readFrame(fd: connFD) {
                        if next.opcode == .close { break }
                    }
                }
                Darwin.close(connFD)
                break
            }
        }

        let client = DiscordIPCClient(appId: "stress-app", socketPaths: [sockPath])
        #expect(client.connect())

        var activity = DiscordRichPresence()
        activity.details = "Stress Run"
        DispatchQueue.concurrentPerform(iterations: 20) { idx in
            if idx % 3 == 0 {
                client.clearPresence()
            } else {
                client.setPresence(activity)
            }
        }

        let startDisconnect = ContinuousClock.now
        client.disconnect()
        #expect(startDisconnect.duration(to: .now) < .seconds(2))
        Darwin.shutdown(serverFD, SHUT_RDWR)
        _ = serverDone.wait(timeout: .now() + 2.0)
    }

    @Test
    func hostToPlaySettingsPlistSchemaRoundTrip108() throws {
        let plistURL = tempDir.appendingPathComponent("com.example.pt108.plist")
        let payload: [String: Any] = [
            "bundleIdentifier": "com.example.pt108",
            "strictEmulationMode": false,
            "strictViewportOrientation": "portrait",
            "strictViewportScaleMode": "native1x",
            "reportedIOSVersion": "compat13_7",
            "interceptInlineSyscalls": true,
            "displayRotation": 1,
            "bypass": true,
            "enableNetworkRules": true,
            "networkBlockMock200": false,
            "blockedURLPatterns": ["||tracker.example.com^"],
            "networkProxyMode": "builtInMITM",
            "externalProxyProtocol": "socks5",
            "externalProxyHost": "127.0.0.1",
            "externalProxyPort": 9050,
            "mitmPort": 8443,
            "mitmRuntimePort": 54321,
            "enableCustomCertificates": true,
            "mitmAllHosts": false,
            "mitmHostPatterns": ["api.example.com"],
            "mitmAllowPinningBypass": true,
            "hideProxyFromApp": false,
            "mitmCaptureBodies": false
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try plistData.write(to: plistURL)

        let settings = PlaySettings(settingsURL: plistURL, bundleIdentifier: "com.example.pt108")
        #expect(settings.hasUserConfiguredDisplayRotation)
        #expect(settings.displayRotation == 1)
        #expect(settings.bypass)
        #expect((settings.reportedIOSVersion as String) == "compat13_7")
        #expect(settings.interceptInlineSyscalls)
        #expect(!settings.rawConfiguredStrictEmulationMode)
        #expect((settings.strictViewportOrientation as String) == "portrait")
        #expect((settings.strictViewportScaleMode as String) == "native1x")

        let decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: plistData)
        #expect(decoded.enableNetworkRules)
        #expect(!decoded.networkBlockMock200)
        #expect(decoded.blockedURLPatterns == ["||tracker.example.com^"])
        #expect(decoded.networkProxyMode == "builtInMITM")
        #expect(decoded.externalProxyProtocol == "socks5")
        #expect(decoded.externalProxyPort == 9050)
        #expect(decoded.mitmRuntimePort == 54321)
        #expect(decoded.enableCustomCertificates)
        #expect(!decoded.mitmAllHosts)
        #expect(decoded.mitmHostPatterns == ["api.example.com"])
        #expect(decoded.mitmAllowPinningBypass)
        #expect(!decoded.hideProxyFromApp)
        #expect(!decoded.mitmCaptureBodies)
    }
}
}
