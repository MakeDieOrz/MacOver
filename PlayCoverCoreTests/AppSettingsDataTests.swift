import AppKit
import Foundation
import PlayCoverCore
import XCTest
@testable import PlayCover

final class AppSettingsDataTests: XCTestCase {
    func testDefaultValuesAndCodableRoundTrip() throws {
        var original = AppSettingsData()
        XCTAssertEqual(original.bundleIdentifier, "")
        XCTAssertEqual(original.sensitivity, 50)
        XCTAssertEqual(original.windowWidth, 1920)
        XCTAssertEqual(original.windowHeight, 1080)
        XCTAssertEqual(original.customScaler, 2.0)
        XCTAssertEqual(original.iosDeviceModel, "iPad13,8")
        XCTAssertEqual(original.notch, NSScreen.hasNotch())
        XCTAssertTrue(original.playChain)
        XCTAssertTrue(original.networkBlockMock200)
        XCTAssertFalse(original.enableNetworkRules)
        XCTAssertFalse(original.strictEmulationMode)
        XCTAssertEqual(original.strictViewportOrientation, .landscape)
        XCTAssertEqual(original.strictViewportScaleMode, .fitScreen)

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
        XCTAssertEqual(decodedPlist, original)

        let jsonData = try JSONEncoder().encode(original)
        let decodedJSON = try JSONDecoder().decode(AppSettingsData.self, from: jsonData)
        XCTAssertEqual(decodedJSON, original)
    }

    func testTolerantDecodingForLegacyAndMixedNumericTypes() throws {
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
        XCTAssertEqual(decoded.bundleIdentifier, "com.legacy.app")
        XCTAssertEqual(decoded.sensitivity, 65.0)
        XCTAssertEqual(decoded.customScaler, 3.0)
        XCTAssertEqual(decoded.keymappingDisabledAt, 12.5)
        XCTAssertFalse(decoded.playChain)
        XCTAssertEqual(decoded.notch, NSScreen.hasNotch())
        XCTAssertTrue(decoded.networkBlockMock200)
        XCTAssertEqual(decoded.blockedURLPatterns, [])
        XCTAssertFalse(decoded.strictEmulationMode)
        XCTAssertEqual(decoded.strictViewportOrientation, .landscape)
        XCTAssertEqual(decoded.strictViewportScaleMode, .fitScreen)

        let emptyDecoded = try JSONDecoder().decode(AppSettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(emptyDecoded, AppSettingsData())
    }

    func testDiscordActivityDefaultsAndPartialDecoding() throws {
        let defaults = DiscordActivity()
        XCTAssertFalse(defaults.enable)
        XCTAssertEqual(defaults.applicationID, "")
        XCTAssertEqual(defaults.details, "")
        XCTAssertEqual(defaults.state, "")
        XCTAssertEqual(defaults.image, "")

        let partial = try JSONDecoder().decode(
            DiscordActivity.self,
            from: Data(#"{"enable":true,"details":"Boss Fight"}"#.utf8)
        )
        XCTAssertTrue(partial.enable)
        XCTAssertEqual(partial.applicationID, "")
        XCTAssertEqual(partial.details, "Boss Fight")
        XCTAssertEqual(partial.state, "")
        XCTAssertEqual(partial.image, "")
    }

    func testMalformedFieldsFallbackAndExtremeNumericBounds() throws {
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
        XCTAssertEqual(decoded.bundleIdentifier, "")
        XCTAssertEqual(decoded.sensitivity, 50)
        XCTAssertEqual(decoded.customScaler, 2.0)
        XCTAssertEqual(decoded.discordActivity, DiscordActivity())
        XCTAssertEqual(decoded.blockedURLPatterns, [])
        XCTAssertEqual(decoded.windowWidth, 1920)
        XCTAssertEqual(decoded.windowHeight, -100)
        XCTAssertEqual(decoded.keymappingDisabledAt, 999999.5)
        XCTAssertEqual(decoded.version, "99.0.0-future")
        XCTAssertFalse(decoded.strictEmulationMode)
        XCTAssertEqual(decoded.strictViewportOrientation, .landscape)
        XCTAssertEqual(decoded.strictViewportScaleMode, .fitScreen)
    }

    func testStrictEmulationDerivedSettingsAreNonDestructive() {
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
        XCTAssertFalse(data.bypass)
        XCTAssertFalse(data.interceptInlineSyscalls)
        XCTAssertFalse(data.rootWorkDir)
        XCTAssertTrue(data.metalHUD)
        XCTAssertTrue(data.playChainDebugging)
        XCTAssertTrue(data.notch)
        XCTAssertEqual(data.resolution, 6)
        XCTAssertEqual(data.windowWidth, 1920)
        XCTAssertEqual(data.windowHeight, 1080)
        XCTAssertEqual(data.customScaler, 1.25)
        XCTAssertEqual(data.windowCompatibility, .invertedMetrics)
        XCTAssertEqual(data.displayRotation, 2)

        // Effective strict values enforce hardware & security parity.
        XCTAssertTrue(data.effectiveBypass)
        XCTAssertTrue(data.effectiveInterceptInlineSyscalls)
        XCTAssertTrue(data.effectiveRootWorkDir)
        XCTAssertFalse(data.effectiveMetalHUD)
        XCTAssertFalse(data.effectivePlayChainDebugging)
        XCTAssertFalse(data.effectiveNotch)
        XCTAssertFalse(data.effectiveHasIntrospection(true))
        XCTAssertFalse(data.effectiveOpenWithLLDB(true))
        XCTAssertEqual(data.effectiveResolution, 5)
        XCTAssertEqual(data.effectiveWindowCompatibility, .standard)
        XCTAssertEqual(data.effectiveCustomScaler, 2.0)
        XCTAssertEqual(data.effectiveWindowWidth, 1032)
        XCTAssertEqual(data.effectiveWindowHeight, 1376)
        XCTAssertEqual(data.effectiveDisplayRotation, 1)
        XCTAssertEqual(
            data.activeTroubleshootingCount(hasIntrospection: true, hasIosFrameworks: false, openWithLLDB: true),
            0
        )
        XCTAssertFalse(PlayAppSettingsPreset.balanced.matches(data))

        data.strictViewportOrientation = .landscape
        XCTAssertEqual(data.effectiveWindowWidth, 1376)
        XCTAssertEqual(data.effectiveWindowHeight, 1032)
        XCTAssertEqual(data.effectiveDisplayRotation, 0)

        data.iosDeviceModel = "iPhone18,2"
        data.strictViewportOrientation = .portrait
        XCTAssertEqual(data.effectiveCustomScaler, 3.0)
        XCTAssertEqual(data.effectiveWindowWidth, 440)
        XCTAssertEqual(data.effectiveWindowHeight, 956)
        let gib: UInt64 = 1_073_741_824
        let strictBudget = data.effectivePixelBudget(physicalMemoryBytes: 8 * gib)
        XCTAssertEqual(strictBudget.renderedWidth, 1320)
        XCTAssertEqual(strictBudget.renderedHeight, 2868)
        XCTAssertEqual(strictBudget.weightedPixels, 3_785_760, accuracy: 0.5)
        XCTAssertEqual(strictBudget.level, .caution)

        // Disabling strict mode restores effective accessors immediately to stored values.
        data.strictEmulationMode = false
        XCTAssertFalse(data.effectiveBypass)
        XCTAssertFalse(data.effectiveInterceptInlineSyscalls)
        XCTAssertFalse(data.effectiveRootWorkDir)
        XCTAssertTrue(data.effectiveMetalHUD)
        XCTAssertTrue(data.effectivePlayChainDebugging)
        XCTAssertTrue(data.effectiveNotch)
        XCTAssertTrue(data.effectiveHasIntrospection(true))
        XCTAssertTrue(data.effectiveOpenWithLLDB(true))
        XCTAssertEqual(data.effectiveResolution, 6)
        XCTAssertEqual(data.effectiveWindowWidth, 1920)
        XCTAssertEqual(data.effectiveWindowHeight, 1080)
        XCTAssertEqual(data.effectiveCustomScaler, 1.25)
        XCTAssertEqual(data.effectiveWindowCompatibility, .invertedMetrics)
        XCTAssertEqual(data.effectiveDisplayRotation, 2)
        XCTAssertEqual(
            data.activeTroubleshootingCount(hasIntrospection: true, hasIosFrameworks: false, openWithLLDB: true),
            5
        )
    }

    func testStrictIntrospectionStripAndNonStrictRestoration() throws {
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
                "DYLD_LIBRARY_PATH": "\(PlayApp.introspection):\(PlayApp.iosFrameworks)"
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: initialPlist, format: .xml, options: 0)
            .write(to: plistURL)

        let app = PlayApp(appUrl: appURL)
        defer { _ = app.settings.flush() }
        XCTAssertFalse(app.settings.settings.storedHasIntrospection)

        // Strict launch strips introspection from Info.plist, syncs in-memory info,
        // and records storedHasIntrospection = true non-destructively.
        let strictLaunchInfo = AppInfo(contentsOf: plistURL)
        XCTAssertTrue(app.stripIntrospectionForStrictLaunch(launchInfo: strictLaunchInfo))
        XCTAssertTrue(app.settings.settings.storedHasIntrospection)
        let afterStrictDisk = AppInfo(contentsOf: plistURL)
        XCTAssertEqual(afterStrictDisk.lsEnvironment["DYLD_LIBRARY_PATH"], PlayApp.iosFrameworks)
        XCTAssertEqual(app.info.lsEnvironment["DYLD_LIBRARY_PATH"], PlayApp.iosFrameworks)

        // Second strict pass is a no-op.
        XCTAssertFalse(app.stripIntrospectionForStrictLaunch(launchInfo: afterStrictDisk))

        // Non-strict launch restores introspection when storedHasIntrospection == true.
        let nonStrictLaunchInfo = AppInfo(contentsOf: plistURL)
        XCTAssertTrue(app.restoreIntrospectionForNonStrictLaunch(launchInfo: nonStrictLaunchInfo))
        let afterRestoreDisk = AppInfo(contentsOf: plistURL)
        let restoredEntries = (afterRestoreDisk.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "").split(separator: ":")
        XCTAssertTrue(restoredEntries.contains(Substring(PlayApp.introspection)))
        XCTAssertTrue(restoredEntries.contains(Substring(PlayApp.iosFrameworks)))
        XCTAssertEqual(app.info.lsEnvironment["DYLD_LIBRARY_PATH"], afterRestoreDisk.lsEnvironment["DYLD_LIBRARY_PATH"])

        // When storedHasIntrospection == false and stripped, non-strict launch does not inject introspection.
        app.settings.update { $0.storedHasIntrospection = false }
        let cleanLaunchInfo = AppInfo(contentsOf: plistURL)
        XCTAssertTrue(app.stripIntrospectionForStrictLaunch(launchInfo: cleanLaunchInfo))
        // Note: strip sets storedHasIntrospection = true only when it had to strip; explicit off clears it.
        app.settings.update { $0.storedHasIntrospection = false }
        XCTAssertFalse(app.restoreIntrospectionForNonStrictLaunch(launchInfo: AppInfo(contentsOf: plistURL)))
    }

    func testMetalHUDUpdatesSerializeAndCoalesceToLatestState() async throws {
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

        let recordLock = NSLock()
        var recorded: [Bool] = []
        let appSettings = AppSettings(
            settingsUrl: settingsURL,
            info: info,
            debounceInterval: 0.2,
            metalHUDExecutor: { _, enabled in
                if recorded.isEmpty {
                    Thread.sleep(forTimeInterval: 0.03)
                }
                recordLock.lock()
                recorded.append(enabled)
                recordLock.unlock()
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
                recordLock.lock()
                recorded.append(enabled)
                recordLock.unlock()
            }
        )

        recordLock.lock()
        let finalValue = recorded.last
        recordLock.unlock()
        XCTAssertEqual(finalValue, false)
    }
}
