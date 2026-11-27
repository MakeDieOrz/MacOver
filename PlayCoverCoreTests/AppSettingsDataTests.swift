import AppKit
import Foundation
import PlayCoverCore
import Synchronization
import Testing
@testable import PlayCover

@Suite
struct AppSettingsDataTests {
    @Test
    func defaultValuesAndCodableRoundTrip() throws {
        var original = AppSettingsData()
        #expect(original.bundleIdentifier == "")
        #expect(original.sensitivity == 50)
        #expect(original.windowWidth == 1920)
        #expect(original.windowHeight == 1080)
        #expect(original.customScaler == 2.0)
        #expect(original.iosDeviceModel == "iPad13,8")
        #expect(!original.notch)
        #expect(original.playChain)
        #expect(original.networkBlockMock200)
        #expect(!original.enableNetworkRules)
        #expect(!original.strictEmulationMode)
        #expect(original.strictViewportOrientation == .landscape)
        #expect(original.strictViewportScaleMode == .fitScreen)

        original.bundleIdentifier = "com.example.game"
        original.sensitivity = 72.5
        original.customScaler = 1.5
        original.enableNetworkRules = true
        original.blockedURLPatterns = ["ads.example.com", "@@cdn.example.com"]
        original.strictEmulationMode = true
        original.strictViewportOrientation = .portrait
        original.strictViewportScaleMode = .native1x
        original.discordActivity = DiscordActivity()
        original.discordActivity.enable = true
        original.discordActivity.applicationID = "123456"
        original.discordActivity.details = "Playing"

        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .xml
        let plistData = try plistEncoder.encode(original)
        let decodedPlist = try PropertyListDecoder().decode(AppSettingsData.self, from: plistData)
        #expect(decodedPlist == original)

        let jsonData = try JSONEncoder().encode(original)
        let decodedJSON = try JSONDecoder().decode(AppSettingsData.self, from: jsonData)
        #expect(decodedJSON == original)
    }

    @Test
    func tolerantDecodingForLegacyAndMixedNumericTypes() throws {
        let json = """
        {
          "bundleIdentifier": "com.legacy.app",
          "sensitivity": 65,
          "customScaler": 3,
          "keymappingDisabledAt": 12.5,
          "playChain": false
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: data)
        #expect(decoded.bundleIdentifier == "com.legacy.app")
        #expect(decoded.sensitivity == 65.0)
        #expect(decoded.customScaler == 3.0)
        #expect(decoded.keymappingDisabledAt == 12.5)
        #expect(!decoded.playChain)
        #expect(!decoded.notch)
        #expect(decoded.networkBlockMock200)
        #expect(decoded.blockedURLPatterns == [])
        #expect(!decoded.strictEmulationMode)
        #expect(decoded.strictViewportOrientation == .landscape)
        #expect(decoded.strictViewportScaleMode == .fitScreen)

        let emptyDecoded = try JSONDecoder().decode(AppSettingsData.self, from: Data("{}".utf8))
        #expect(emptyDecoded == AppSettingsData())
    }

    @Test
    func discordActivityDefaultsAndPartialDecoding() throws {
        let defaults = DiscordActivity()
        #expect(!defaults.enable)
        #expect(defaults.applicationID == "")
        #expect(defaults.details == "")
        #expect(defaults.state == "")
        #expect(defaults.image == "")

        let partial = try JSONDecoder().decode(
            DiscordActivity.self,
            from: Data(#"{"enable":true,"details":"Boss Fight"}"#.utf8)
        )
        #expect(partial.enable)
        #expect(partial.applicationID == "")
        #expect(partial.details == "Boss Fight")
        #expect(partial.state == "")
        #expect(partial.image == "")
    }

    @Test
    func malformedFieldsFallbackAndExtremeNumericBounds() throws {
        let malformedJSON = """
        {
          "bundleIdentifier": 999,
          "sensitivity": "bad",
          "customScaler": "bad",
          "discordActivity": 123,
          "blockedURLPatterns": [123, "ok"],
          "windowWidth": "wide",
          "windowHeight": -100,
          "keymappingDisabledAt": 999999.5,
          "version": "99.0.0-future",
          "strictEmulationMode": "yes",
          "strictViewportOrientation": 42,
          "strictViewportScaleMode": "bogus"
        }
        """
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: Data(malformedJSON.utf8))
        #expect(decoded.bundleIdentifier == "")
        #expect(decoded.sensitivity == 50)
        #expect(decoded.customScaler == 2.0)
        #expect(decoded.discordActivity == DiscordActivity())
        #expect(decoded.blockedURLPatterns == [])
        #expect(decoded.windowWidth == 1920)
        #expect(decoded.windowHeight == -100)
        #expect(decoded.keymappingDisabledAt == 999999.5)
        #expect(decoded.version == "99.0.0-future")
        #expect(!decoded.strictEmulationMode)
        #expect(decoded.strictViewportOrientation == .landscape)
        #expect(decoded.strictViewportScaleMode == .fitScreen)
    }

    @Test
    func strictEmulationDerivedSettingsAreNonDestructive() {
        var data = AppSettingsData()
        data.bypass = false
        data.interceptInlineSyscalls = false
        data.rootWorkDir = false
        data.metalHUD = true
        data.playChainDebugging = true
        data.notch = true
        data.resolution = 6
        data.windowWidth = 1920
        data.windowHeight = 1080
        data.customScaler = 1.25
        data.windowCompatibility = .invertedMetrics
        data.displayRotation = 2
        data.iosDeviceModel = "iPad16,6"

        data.strictEmulationMode = true
        data.strictViewportOrientation = .portrait
        data.strictViewportScaleMode = .native1x

        // Stored non-strict values remain intact.
        #expect(!data.bypass)
        #expect(!data.interceptInlineSyscalls)
        #expect(!data.rootWorkDir)
        #expect(data.metalHUD)
        #expect(data.playChainDebugging)
        #expect(data.notch)
        #expect(data.resolution == 6)
        #expect(data.windowWidth == 1920)
        #expect(data.windowHeight == 1080)
        #expect(data.customScaler == 1.25)
        #expect(data.windowCompatibility == .invertedMetrics)
        #expect(data.displayRotation == 2)

        // Effective strict values enforce hardware & security parity.
        #expect(data.effectiveBypass)
        #expect(data.effectiveInterceptInlineSyscalls)
        #expect(data.effectiveRootWorkDir)
        #expect(!data.effectiveMetalHUD)
        #expect(!data.effectivePlayChainDebugging)
        #expect(!data.effectiveNotch)
        #expect(!data.effectiveHasIntrospection(true))
        #expect(!data.effectiveOpenWithLLDB(true))
        #expect(data.effectiveResolution == 5)
        #expect(data.effectiveWindowCompatibility == .standard)
        #expect(data.effectiveCustomScaler == 2.0)
        #expect(data.effectiveWindowWidth == 1032)
        #expect(data.effectiveWindowHeight == 1376)
        #expect(data.effectiveDisplayRotation == 1)
        #expect(
            data.activeTroubleshootingCount(hasIntrospection: true, hasIosFrameworks: false, openWithLLDB: true) == 0
        )
        #expect(!PlayAppSettingsPreset.balanced.matches(data))

        data.strictViewportOrientation = .landscape
        #expect(data.effectiveWindowWidth == 1376)
        #expect(data.effectiveWindowHeight == 1032)
        #expect(data.effectiveDisplayRotation == 0)

        data.iosDeviceModel = "iPhone18,2"
        data.strictViewportOrientation = .portrait
        #expect(data.effectiveCustomScaler == 3.0)
        #expect(data.effectiveWindowWidth == 440)
        #expect(data.effectiveWindowHeight == 956)
        let gib: UInt64 = 1_073_741_824
        let strictBudget = data.effectivePixelBudget(physicalMemoryBytes: 8 * gib)
        #expect(strictBudget.renderedWidth == 1320)
        #expect(strictBudget.renderedHeight == 2868)
        #expect(abs(strictBudget.weightedPixels - 3_785_760) <= 0.5)
        #expect(strictBudget.level == .caution)

        // Disabling strict mode restores effective accessors immediately to stored values.
        data.strictEmulationMode = false
        #expect(!data.effectiveBypass)
        #expect(!data.effectiveInterceptInlineSyscalls)
        #expect(!data.effectiveRootWorkDir)
        #expect(data.effectiveMetalHUD)
        #expect(data.effectivePlayChainDebugging)
        #expect(data.effectiveNotch)
        #expect(data.effectiveHasIntrospection(true))
        #expect(data.effectiveOpenWithLLDB(true))
        #expect(data.effectiveResolution == 6)
        #expect(data.effectiveWindowWidth == 1920)
        #expect(data.effectiveWindowHeight == 1080)
        #expect(data.effectiveCustomScaler == 1.25)
        #expect(data.effectiveWindowCompatibility == .invertedMetrics)
        #expect(data.effectiveDisplayRotation == 2)
        #expect(
            data.activeTroubleshootingCount(hasIntrospection: true, hasIosFrameworks: false, openWithLLDB: true) == 5
        )
    }

    @Test
    func strictIntrospectionStripAndNonStrictRestoration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("introspection-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("IntrospectionProbe.app", isDirectory: true)
        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        let bundleID = "com.example.introspection.\(UUID().uuidString.lowercased())"
        let settingsFileURL = AppSettings.settingsURL(forBundleIdentifier: bundleID)
        defer { try? fm.removeItem(at: settingsFileURL) }

        let plistURL = appURL.appendingPathComponent("Info.plist")
        let initialPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "IntrospectionProbe",
            "CFBundleShortVersionString": "1.0",
            "LSEnvironment": [
                "DYLD_LIBRARY_PATH": "\(PlayApp.introspection):\(PlayApp.iosFrameworks):/custom/dyld"
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: initialPlist, format: .xml, options: 0)
            .write(to: plistURL)

        let app = PlayApp(appUrl: appURL)
        defer { _ = app.settings.flush() }
        #expect(!app.settings.settings.storedHasIntrospection)
        #expect(!app.settings.settings.storedHasIosFrameworks)

        // Strict launch strips both introspection and iosFrameworks from Info.plist,
        // syncs in-memory info, preserves custom entries, and records stored flags non-destructively.
        let strictLaunchInfo = AppInfo(contentsOf: plistURL)
        #expect(app.stripIntrospectionForStrictLaunch(launchInfo: strictLaunchInfo))
        #expect(app.settings.settings.storedHasIntrospection)
        #expect(app.settings.settings.storedHasIosFrameworks)
        let afterStrictDisk = AppInfo(contentsOf: plistURL)
        #expect(afterStrictDisk.lsEnvironment["DYLD_LIBRARY_PATH"] == "/custom/dyld")
        #expect(app.info.lsEnvironment["DYLD_LIBRARY_PATH"] == "/custom/dyld")

        // Second strict pass is a no-op.
        #expect(!app.stripIntrospectionForStrictLaunch(launchInfo: afterStrictDisk))

        // Non-strict launch restores both introspection and iosFrameworks when stored flags are true.
        let nonStrictLaunchInfo = AppInfo(contentsOf: plistURL)
        #expect(app.restoreIntrospectionForNonStrictLaunch(launchInfo: nonStrictLaunchInfo))
        let afterRestoreDisk = AppInfo(contentsOf: plistURL)
        let restoredEntries = (afterRestoreDisk.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "").split(separator: ":")
        #expect(restoredEntries.contains(Substring(PlayApp.introspection)))
        #expect(restoredEntries.contains(Substring(PlayApp.iosFrameworks)))
        #expect(restoredEntries.contains("/custom/dyld"))
        #expect(app.info.lsEnvironment["DYLD_LIBRARY_PATH"] == afterRestoreDisk.lsEnvironment["DYLD_LIBRARY_PATH"])

        // When stored flags == false and stripped, non-strict launch does not inject host paths.
        app.settings.update {
            $0.storedHasIntrospection = false
            $0.storedHasIosFrameworks = false
        }
        let cleanLaunchInfo = AppInfo(contentsOf: plistURL)
        #expect(app.stripIntrospectionForStrictLaunch(launchInfo: cleanLaunchInfo))
        // Note: strip sets stored flags = true when it had to strip; explicit off clears them.
        app.settings.update {
            $0.storedHasIntrospection = false
            $0.storedHasIosFrameworks = false
        }
        #expect(!app.restoreIntrospectionForNonStrictLaunch(launchInfo: AppInfo(contentsOf: plistURL)))
    }

    @Test
    func metalHUDUpdatesSerializeAndCoalesceToLatestState() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("metal-hud-serial-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let infoURL = root.appendingPathComponent("Info.plist")
        let bundleID = "com.example.metalhud.\(UUID().uuidString.lowercased())"
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: infoURL)
        let info = AppInfo(contentsOf: infoURL)
        let settingsURL = root.appendingPathComponent("settings.plist")

        let recorded = Mutex<[Bool]>([])
        let appSettings = AppSettings(
            settingsUrl: settingsURL,
            info: info,
            debounceInterval: 0.2,
            metalHUDExecutor: { _, enabled in
                if recorded.withLock({ $0.isEmpty }) {
                    Thread.sleep(forTimeInterval: 0.03)
                }
                recorded.withLock {
                    $0.append(enabled)
                }
            }
        )

        // Rapidly toggle Metal HUD + Strict Mode: ON -> strict ON (false) -> strict OFF (true) -> strict ON (false)
        appSettings.update { $0.metalHUD = true }
        appSettings.update { $0.strictEmulationMode = true }
        appSettings.update { $0.strictEmulationMode = false }
        appSettings.update { $0.strictEmulationMode = true }

        await AppSettings.syncMetalHUD(
            bundleID: bundleID,
            enabled: appSettings.settings.effectiveMetalHUD,
            executor: { _, enabled in
                recorded.withLock {
                    $0.append(enabled)
                }
            }
        )

        let finalValue = recorded.withLock { $0.last }
        #expect(finalValue == false)
    }
}
