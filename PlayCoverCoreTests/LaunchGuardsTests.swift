import AppKit
import Foundation
import PlayCoverCore
import Synchronization
import Testing
@testable import PlayCover

@Suite
struct LaunchGuardsTests {
    @Test
    func processInfoIsRunningUnitTestsIsTrue() {
        #expect(ProcessInfo.isRunningUnitTests)
    }

    @Test
    @MainActor
    func guardedServicesAndAppDelegateExecuteSafelyInUnitTests() {
        let deps = PlayCoverDependencies(loadInitialData: false)
        let beforeCount = deps.log.logdata.count
        deps.log.msg("LaunchGuardsTests.msg")
        deps.log.error("LaunchGuardsTests.error")
        #expect(deps.log.logdata.count > beforeCount)
        #expect(deps.log.logdata.contains("LaunchGuardsTests.msg"))
        #expect(deps.log.logdata.contains("ERROR: LaunchGuardsTests.error"))

        deps.notifyService.allowNotify()
        deps.notifyService.notify("Title", "Message")
        deps.soundDeviceService.prepareSoundDevice()
        UpdateScheme.checkForUpdate()

        let updater = UpdaterViewModel()
        #expect(!updater.canCheckForUpdates)
        updater.checkForUpdates()

        let delegate = AppDelegate(dependencies: deps)
        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/nonexistent.ipa")])
        delegate.powerModal()
        let prevMenuBarValue = UserDefaults.standard.object(forKey: "showMenuBarExtra")
        UserDefaults.standard.set(false, forKey: "showMenuBarExtra")
        defer {
            if let prevMenuBarValue {
                UserDefaults.standard.set(prevMenuBarValue, forKey: "showMenuBarExtra")
            } else {
                UserDefaults.standard.removeObject(forKey: "showMenuBarExtra")
            }
        }
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test
    @MainActor
    func playAppRunStateObservationAndGridTopPinning() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverRunStateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func makeApp(_ name: String, bundleID: String) throws -> PlayApp {
            let appURL = tmp.appendingPathComponent("\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": bundleID,
                    "CFBundleDisplayName": name,
                    "CFBundleName": name,
                    "CFBundleExecutable": name,
                    "CFBundleShortVersionString": "1.0"
                ],
                format: .xml,
                options: 0
            ).write(to: appURL.appendingPathComponent("Info.plist"))
            return PlayApp(appUrl: appURL)
        }

        let deps = PlayCoverDependencies(loadInitialData: false)
        let alpha = try makeApp("Alpha", bundleID: "com.test.alpha.\(UUID().uuidString)")
        let zulu = try makeApp("Zulu", bundleID: "com.test.zulu.\(UUID().uuidString)")
        alpha.dependencies = deps
        zulu.dependencies = deps
        deps.appsVM.apps = [zulu, alpha]
        deps.appsVM.applyFilter()
        #expect(deps.appsVM.filteredApps.map(\.name) == ["Alpha", "Zulu"])

        let observedStarting = Mutex(false)
        withObservationTracking {
            _ = zulu.isStarting
        } onChange: {
            observedStarting.withLock { $0 = true }
        }
        zulu.setRunState(.preparing(.verifying))
        #expect(observedStarting.withLock { $0 })
        #expect(zulu.isStarting)
        #expect(deps.appsVM.filteredApps.map(\.name) == ["Zulu", "Alpha"])

        zulu.setRunState(.running(isActive: false))
        alpha.setRunState(.preparing(.opening))
        #expect(deps.appsVM.filteredApps.map(\.name) == ["Zulu", "Alpha"])

        let matchedDirect = RunningAppsMonitor.matchApp(
            bundleURL: alpha.url,
            bundleIdentifier: nil,
            among: [alpha, zulu]
        )
        #expect(matchedDirect?.id == alpha.id)
        #expect(RunningAppsMonitor.shouldPreventDisplaySleep(
            runState: .running(isActive: true),
            disableTimeoutEnabled: true
        ))
        #expect(!RunningAppsMonitor.shouldPreventDisplaySleep(
            runState: .running(isActive: false),
            disableTimeoutEnabled: true
        ))
        #expect(!RunningAppsMonitor.shouldPreventDisplaySleep(
            runState: .running(isActive: true),
            disableTimeoutEnabled: false
        ))
    }

    @Test
    func launchFingerprintAndLibraryIndexStoresRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverStoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fpURL = tmp.appendingPathComponent("launch-fingerprints.json")
        let store = AppLaunchFingerprintStore(storeURL: fpURL)
        let stamp = LaunchFastPathStamp(
            schemaVersion: LaunchFastPathStamp.currentSchemaVersion,
            exec: .init(inode: 11, size: 22, mtimeSec: 33, mtimeNSec: 44),
            infoPlist: .init(inode: 12, size: 23, mtimeSec: 34, mtimeNSec: 45),
            codeResources: nil,
            frameworksDir: nil,
            plugInsDir: nil,
            akExec: nil,
            playTools: .init(inode: 99, size: 88, mtimeSec: 77, mtimeNSec: 66),
            usesPlayTools: true,
            isCatalyst: true,
            strictEmulationMode: false,
            interceptInlineSyscalls: false,
            enableAutomationBridge: false,
            coverUseBridge: nil,
            coverUseBridgeStaged: false,
            storedHasIntrospection: false,
            storedHasIosFrameworks: false,
            entitlementsInputsHash: "abc123"
        )
        store.record(stamp, for: "/Applications/Sample.app")
        #expect(store.flushSynchronously())

        let reloaded = AppLaunchFingerprintStore(storeURL: fpURL)
        #expect(reloaded.matches(stamp, for: "/Applications/Sample.app"))
        reloaded.invalidate(for: "/Applications/Sample.app")
        #expect(!reloaded.matches(stamp, for: "/Applications/Sample.app"))

        let entsURL = tmp.appendingPathComponent("Sample.plist")
        var settings = AppSettingsData()
        let baseDigest = AppLaunchFingerprintStore.entitlementsInputsDigest(
            bundleID: "com.test.sample",
            bundlePath: "/Applications/Sample.app",
            settings: settings,
            appEntitlementsURL: entsURL
        )
        settings.bypass.toggle()
        let bypassDigest = AppLaunchFingerprintStore.entitlementsInputsDigest(
            bundleID: "com.test.sample",
            bundlePath: "/Applications/Sample.app",
            settings: settings,
            appEntitlementsURL: entsURL
        )
        #expect(bypassDigest != baseDigest)
        settings.discordActivity.enable.toggle()
        let discordDigest = AppLaunchFingerprintStore.entitlementsInputsDigest(
            bundleID: "com.test.sample",
            bundlePath: "/Applications/Sample.app",
            settings: settings,
            appEntitlementsURL: entsURL
        )
        #expect(discordDigest != bypassDigest)

        let idxURL = tmp.appendingPathComponent("app-library-index.json")
        let entry = CachedAppIndexEntry(
            urlPath: "/Applications/Sample.app",
            bundleIdentifier: "com.test.sample",
            bundleName: "Sample",
            displayName: "Sample",
            bundleVersion: "1.0",
            cfBundleVersion: "1",
            executableName: "Sample",
            installGeneration: "g1",
            primaryIconName: "AppIcon",
            hasPlayTools: true,
            strictEmulationMode: true,
            effectiveIOSDeviceModel: "iPad16,6",
            pixelBudgetRatio: 0.42,
            infoPlistMTimeSec: 100,
            settingsPlistMTimeSec: 150,
            execMTimeSec: 200,
            execInode: 300,
            execSize: 400
        )
        #expect(AppLibraryIndexCache.save([entry], to: idxURL))
        #expect(AppLibraryIndexCache.load(from: idxURL) == [entry])
    }

    @Test
    @MainActor
    func runningAppsMonitorIndexedLookupAndIconDownsample() async throws {
        let deps = PlayCoverDependencies(loadInitialData: false)
        let monitor = RunningAppsMonitor(observeWorkspace: false)
        #expect(monitor.matchAppIndexed(NSRunningApplication.current, among: []) == nil)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverPerfUnit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appURL = tmp.appendingPathComponent("TestApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.nonrunning",
                "CFBundleDisplayName": "TestApp",
                "CFBundleExecutable": "TestApp",
                "CFBundleShortVersionString": "1.0"
            ],
            format: .xml,
            options: 0
        ).write(to: appURL.appendingPathComponent("Info.plist"))
        let app = PlayApp(appUrl: appURL, dependencies: deps)
        #expect(monitor.matchAppIndexed(NSRunningApplication.current, among: [app]) == nil)

        // Verify CGImage downsampling caps oversized images at maxPixelSize (256)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 512,
            pixelsHigh: 512,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to synthesize test bitmap")
            return
        }
        let downsampled = Cacher.downsampleCGImage(from: pngData, maxPixelSize: 256)
        #expect(downsampled?.width == 256)
        #expect(downsampled?.height == 256)

        // Verify checkOfficialMacOS short-circuits immediately when preference is disabled
        let suite = "app.makedie.MacOverTests.IPAPopupOff.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suite))
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let installPrefs = InstallPreferences(userDefaults: isolatedDefaults)
        installPrefs.showAppStorePopup = false
        let ipa = IPA(url: tmp.appendingPathComponent("Dummy.ipa"))
        let base = BaseApp(appUrl: appURL)
        let skipped = await ipa.checkOfficialMacOS(
            app: .base(base),
            alertPresenter: deps.alertPresenter,
            installPreferences: installPrefs
        )
        #expect(!skipped)
    }

    @Test
    @MainActor
    func runningAppsMonitorProcessLivenessAndStaleCleanup() throws {
        #expect(RunningAppsMonitor.isProcessAlive(pid: getpid(), isTerminated: false))
        #expect(!RunningAppsMonitor.isProcessAlive(pid: getpid(), isTerminated: true))
        #expect(!RunningAppsMonitor.isProcessAlive(pid: -1, isTerminated: false))
        #expect(!RunningAppsMonitor.isProcessAlive(pid: 999_999, isTerminated: false))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverStaleTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appURL = tmp.appendingPathComponent("StaleApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.test.stale.\(UUID().uuidString)",
                "CFBundleDisplayName": "StaleApp",
                "CFBundleExecutable": "StaleApp",
                "CFBundleShortVersionString": "1.0"
            ],
            format: .xml,
            options: 0
        ).write(to: appURL.appendingPathComponent("Info.plist"))

        let deps = PlayCoverDependencies(loadInitialData: false)
        let monitor = RunningAppsMonitor(observeWorkspace: false)
        let app = PlayApp(appUrl: appURL, dependencies: deps)
        deps.appsVM.apps = [app]

        app.setRunState(.running(isActive: false))
        monitor.reconcile(apps: [app])
        #expect(app.runState == .idle)

        app.setRunState(.terminating)
        monitor.reconcile(apps: [app])
        #expect(app.runState == .idle)

        app.setRunState(.terminating)
        monitor.notifyProcessTerminated(for: app, pid: -1)
        #expect(app.runState == .idle)
    }

    @Test func mcpPreferencesDefaultOffAndPersistThroughUserDefaults() throws {
        let suiteName = "app.makedie.MacOver.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = MCPPreferences(userDefaults: defaults)
        #expect(prefs.isEnabled == false)
        #expect(prefs.allowSensitiveHeaders == false)

        prefs.isEnabled = true
        prefs.allowSensitiveHeaders = true

        let reloaded = MCPPreferences(userDefaults: defaults)
        #expect(reloaded.isEnabled == true)
        #expect(reloaded.allowSensitiveHeaders == true)
    }

    @MainActor
    @Test func mcpHostCoordinatorStartsLoopbackAndIssuesLaunchEnv() async throws {
        let suiteName = "app.makedie.MacOver.mcp.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = MCPPreferences(userDefaults: defaults)
        let deps = PlayCoverDependencies(loadInitialData: false)
        let coordinator = MCPHostCoordinator(preferences: prefs)
        coordinator.dependencies = deps
        defer { coordinator.stop() }

        #expect(coordinator.isRunning == false)
        #expect(coordinator.prepareAutomationEnvironment(for: "com.example.game").isEmpty)

        coordinator.setEnabled(true)
        #expect(coordinator.isRunning == true)
        #expect(coordinator.daemonPort != nil)
        #expect(coordinator.bridgePort != nil)

        let env = coordinator.prepareAutomationEnvironment(for: "com.example.game")
        #expect(env["MACOVER_AUTOMATION_PORT"] == coordinator.bridgePort.map(String.init))
        #expect(env["MACOVER_AUTOMATION_BUNDLE_ID"] == "com.example.game")
        #expect((env["MACOVER_AUTOMATION_TOKEN"] ?? "").isEmpty == false)

        let listResult = await coordinator.handleToolCall(
            name: "macover_apps",
            arguments: ["op": .string("list")]
        )
        #expect(listResult.isError != true)

        let diagUnknown = await coordinator.handleToolCall(
            name: "macover_diagnostics",
            arguments: ["bundleID": .string("com.example.missing")]
        )
        #expect(diagUnknown.isError == true)

        coordinator.setEnabled(false)
        #expect(coordinator.isRunning == false)
        #expect(coordinator.prepareAutomationEnvironment(for: "com.example.game").isEmpty)
    }

    @Test func appLaunchFingerprintStoreRejectsV1AndDetectsAutomationBridgeChange() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeURL = tmp.appendingPathComponent("launch-fingerprints.json")
        let dummyStamp = PlayTools.FileStatStamp(inode: 1, size: 123, mtimeSec: 456, mtimeNSec: 789)
        let stampV1 = LaunchFastPathStamp(
            schemaVersion: 1,
            exec: dummyStamp,
            infoPlist: dummyStamp,
            codeResources: nil,
            frameworksDir: nil,
            plugInsDir: nil,
            akExec: nil,
            playTools: dummyStamp,
            usesPlayTools: true,
            isCatalyst: false,
            strictEmulationMode: false,
            interceptInlineSyscalls: false,
            enableAutomationBridge: false,
            coverUseBridge: nil,
            coverUseBridgeStaged: false,
            storedHasIntrospection: false,
            storedHasIosFrameworks: false,
            entitlementsInputsHash: "abc"
        )
        let encoded = try JSONEncoder().encode(["/Applications/Dummy.app": stampV1])
        try encoded.write(to: storeURL)

        let store = AppLaunchFingerprintStore(storeURL: storeURL)
        #expect(store.matches(stampV1, for: "/Applications/Dummy.app") == false)

        let stampV2Disabled = LaunchFastPathStamp(
            schemaVersion: LaunchFastPathStamp.currentSchemaVersion,
            exec: dummyStamp,
            infoPlist: dummyStamp,
            codeResources: nil,
            frameworksDir: nil,
            plugInsDir: nil,
            akExec: nil,
            playTools: dummyStamp,
            usesPlayTools: true,
            isCatalyst: false,
            strictEmulationMode: false,
            interceptInlineSyscalls: false,
            enableAutomationBridge: false,
            coverUseBridge: nil,
            coverUseBridgeStaged: false,
            storedHasIntrospection: false,
            storedHasIosFrameworks: false,
            entitlementsInputsHash: "abc"
        )
        let stampV2Enabled = LaunchFastPathStamp(
            schemaVersion: LaunchFastPathStamp.currentSchemaVersion,
            exec: dummyStamp,
            infoPlist: dummyStamp,
            codeResources: nil,
            frameworksDir: nil,
            plugInsDir: nil,
            akExec: nil,
            playTools: dummyStamp,
            usesPlayTools: true,
            isCatalyst: false,
            strictEmulationMode: false,
            interceptInlineSyscalls: false,
            enableAutomationBridge: true,
            coverUseBridge: nil,
            coverUseBridgeStaged: true,
            storedHasIntrospection: false,
            storedHasIosFrameworks: false,
            entitlementsInputsHash: "abc"
        )

        store.record(stampV2Disabled, for: "/Applications/Dummy.app")
        #expect(store.matches(stampV2Disabled, for: "/Applications/Dummy.app") == true)
        #expect(store.matches(stampV2Enabled, for: "/Applications/Dummy.app") == false)
    }
}
