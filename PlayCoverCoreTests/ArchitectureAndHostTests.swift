import Combine
import Foundation
import PlayCoverCore
import XCTest
@testable import PlayCover

final class ArchitectureAndHostTests: XCTestCase {
    private var tempDir: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverArchitectureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testPlayCoverErrorStructuredCasesAndDescriptions() {
        let shellErr = PlayCoverError.shellExecutionFailed(
            binary: "/usr/bin/codesign",
            status: 1,
            output: "invalid signature"
        )
        XCTAssertEqual(shellErr.errorDescription, "invalid signature")

        let emptyShellErr = PlayCoverError.shellExecutionFailed(
            binary: "/usr/bin/true",
            status: 2,
            output: ""
        )
        XCTAssertEqual(emptyShellErr.errorDescription, "Shell command failed")

        XCTAssertEqual(PlayCoverError.playToolsError("missing binary").errorDescription, "missing binary")
        XCTAssertEqual(PlayCoverError.entitlementsError("bad yaml").errorDescription, "bad yaml")
        XCTAssertEqual(PlayCoverError.privilegeEscalationFailed("sip active").errorDescription, "sip active")
        XCTAssertEqual(PlayCoverError.appleScriptFailed("canceled").errorDescription, "canceled")
    }

    func testAppSettingsDebouncesRapidUpdatesAndFlushesImmediately() throws {
        guard let dir = tempDir else {
            XCTFail("Missing tempDir")
            return
        }
        let infoURL = dir.appendingPathComponent("Info.plist")
        let plistDict: NSDictionary = [
            "CFBundleIdentifier": "app.makedie.test.architecture",
            "CFBundleName": "ArchitectureTest",
            "CFBundleExecutable": "ArchitectureTest"
        ]
        XCTAssertTrue(plistDict.write(to: infoURL, atomically: true))

        let info = AppInfo(contentsOf: infoURL)
        let settingsURL = dir.appendingPathComponent("app.makedie.test.architecture.plist")
        let appSettings = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.25)

        // Rapid mutations (like dragging a slider) must not synchronously write on every update
        let initialModDate = (try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.modificationDate]) as? Date
        for idx in 1...20 {
            appSettings.update { $0.sensitivity = Float(idx) }
        }
        XCTAssertEqual(appSettings.settings.sensitivity, 20)

        // Explicit flush persists immediately
        XCTAssertTrue(appSettings.flush())
        let reloaded = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.25)
        XCTAssertEqual(reloaded.settings.sensitivity, 20)
        XCTAssertNotNil(initialModDate)

        // Debounce timer persists automatically after debounceInterval elapses
        appSettings.update { $0.windowWidth = 2560 }
        let exp = expectation(description: "Debounced write completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        let reloadedAfterDebounce = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.25)
        XCTAssertEqual(reloadedAfterDebounce.settings.windowWidth, 2560)
    }

    func testToastVMDismissesByUUIDOutOfOrder() {
        let vm = ToastVM()
        let first = vm.showToast(toastType: .notice, toastDetails: "First", timeRemaining: 5)
        let second = vm.showToast(toastType: .error, toastDetails: "Second", timeRemaining: 5)
        let third = vm.showToast(toastType: .network, toastDetails: "Third", timeRemaining: 5)
        XCTAssertEqual(vm.toasts.map(\.id), [first, second, third])

        // Dismiss middle toast by UUID (old removeFirst() would wrongly drop "First")
        vm.dismiss(id: second)
        XCTAssertEqual(vm.toasts.map(\.id), [first, third])

        // Dismissing an already-removed or unknown UUID is safe
        vm.dismiss(id: second)
        vm.dismiss(id: UUID())
        XCTAssertEqual(vm.toasts.map(\.id), [first, third])
    }

    @MainActor
    func testProgressVMTransitionsWithoutPollingLoop() async throws {
        enum SampleStep: String {
            case start, working, done, failed
        }

        let vm = ProgressVM<SampleStep>(start: .start, ends: [.done, .failed])
        XCTAssertFalse(vm.inProgress)

        vm.next(.start, 0.0, 0.1)
        XCTAssertTrue(vm.inProgress)
        XCTAssertEqual(vm.status, .start)

        vm.next(.working, 0.2, 0.8)
        XCTAssertEqual(vm.status, .working)
        XCTAssertEqual(vm.progress, 0.2, accuracy: 0.0001)

        // Event-driven progress update without polling
        vm.updateProgress(0.65)
        XCTAssertEqual(vm.progress, 0.65, accuracy: 0.0001)
        vm.updateProgress(1.5)
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.0001)

        // Transitioning to end step marks 1.0 immediately
        vm.next(.done, 0.9, 1.0)
        XCTAssertEqual(vm.status, .done)
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.0001)

        // Wait past 1.5s dismissal window
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertFalse(vm.inProgress)
    }

    func testPreferencesStoresUseUserDefaultsAndEmitObjectWillChange() {
        let suiteName = "app.makedie.ArchitecturePreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let keyCoverPrefs = KeyCoverPreferences(userDefaults: defaults)
        let installPrefs = InstallPreferences(userDefaults: defaults)
        let uninstallPrefs = UninstallPreferences(userDefaults: defaults)

        var changes = 0
        var cancellables = Set<AnyCancellable>()
        keyCoverPrefs.objectWillChange.sink { _ in changes += 1 }.store(in: &cancellables)
        installPrefs.objectWillChange.sink { _ in changes += 1 }.store(in: &cancellables)
        uninstallPrefs.objectWillChange.sink { _ in changes += 1 }.store(in: &cancellables)

        keyCoverPrefs.keyCoverEnabled = .userProvidedPassword
        keyCoverPrefs.promptForKeyCoverPasswordAtLaunch = false
        installPrefs.alwaysInstallPlayTools = false
        installPrefs.defaultAppType = .games
        uninstallPrefs.clearAppData = true
        uninstallPrefs.showUninstallPopup = false

        XCTAssertEqual(changes, 6)

        let reloadedKeyCover = KeyCoverPreferences(userDefaults: defaults)
        let reloadedInstall = InstallPreferences(userDefaults: defaults)
        let reloadedUninstall = UninstallPreferences(userDefaults: defaults)

        XCTAssertEqual(reloadedKeyCover.keyCoverEnabled, .userProvidedPassword)
        XCTAssertFalse(reloadedKeyCover.promptForKeyCoverPasswordAtLaunch)
        XCTAssertFalse(reloadedInstall.alwaysInstallPlayTools)
        XCTAssertEqual(reloadedInstall.defaultAppType, .games)
        XCTAssertTrue(reloadedUninstall.clearAppData)
        XCTAssertFalse(reloadedUninstall.showUninstallPopup)
    }

    func testModifierKeyObserverAvoidsDuplicateObjectWillChangeEmissions() {
        let observer = ModifierKeyObserver()
        var emissions = 0
        let cancellable = observer.objectWillChange.sink { _ in
            emissions += 1
        }

        observer.applyModifierFlags([.option, .command])
        XCTAssertEqual(emissions, 2)
        XCTAssertTrue(observer.isOptionKeyPressed)
        XCTAssertTrue(observer.isCommandKeyPressed)

        // Applying identical modifier flags must emit zero redundant notifications
        observer.applyModifierFlags([.option, .command])
        XCTAssertEqual(emissions, 2)
        cancellable.cancel()
    }

    func testGoogleDriveLinkConversionAndFormExtraction() {
        let converted = RedirectHandler.convertGoogleDriveLink("https://drive.google.com/file/d/1AbCdEfGhIjK/view?usp=sharing")
        XCTAssertEqual(
            converted?.absoluteString,
            "https://drive.usercontent.google.com/download?id=1AbCdEfGhIjK&export=download&authuser=0"
        )
        XCTAssertNil(RedirectHandler.convertGoogleDriveLink("https://example.com/app.ipa"))

        let html = """
        <html><body>
          <form id="download-form" action="https://drive.usercontent.google.com/download">
            <input type="hidden" name="id" value="1AbCdEfGhIjK">
            <input type="hidden" name="confirm" value="t">
            <input type="hidden" name="uuid" value="xyz-999">
          </form>
        </body></html>
        """
        let extracted = RedirectHandler.extractDownloadLink(from: html)
        XCTAssertEqual(
            extracted?.absoluteString,
            "https://drive.usercontent.google.com/download?id=1AbCdEfGhIjK&confirm=t&uuid=xyz-999"
        )
        XCTAssertNil(RedirectHandler.extractDownloadLink(from: "<html><body>No form</body></html>"))
    }

    func testKeyCoverUnlockPromptContinuationWakeupAndCancellation() async throws {
        let observable = KeyCoverObservable()
        observable.isKeyCoverUnlockingPromptShown = true

        let waiter = Task {
            try await observable.waitForUnlockPromptDismissal()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        await MainActor.run {
            observable.isKeyCoverUnlockingPromptShown = false
        }
        try await waiter.value

        // Cancellation path
        await MainActor.run {
            observable.isKeyCoverUnlockingPromptShown = true
        }
        let canceledWaiter = Task {
            try await observable.waitForUnlockPromptDismissal()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        canceledWaiter.cancel()

        do {
            try await canceledWaiter.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        await MainActor.run {
            observable.isKeyCoverUnlockingPromptShown = false
        }
    }

    func testDualTrackPrivilegeEscalatorTrackSelectionAndEscaping() {
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ),
            .xpcHelper
        )
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: false,
                hasEmbeddedHelperPlist: true
            ),
            .appleScriptGUI
        )
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: false,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ),
            .appleScriptGUI
        )
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: false
            ),
            .appleScriptGUI
        )

        XCTAssertEqual(
            DualTrackPrivilegeEscalator.shellSingleQuoted("a'b\\c"),
            "'a'\"'\"'b\\c'"
        )
        let script = DualTrackPrivilegeEscalator.buildAppleScriptPrivilegeCommand(
            binary: "/usr/sbin/nvram",
            arguments: ["boot-args=amfi_get_out_of_my_way=0x1 ipc_control_port_options=0"]
        )
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("/usr/sbin/nvram"))
        XCTAssertTrue(script.contains("amfi_get_out_of_my_way=0x1"))

        XCTAssertFalse(DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: nil, leafCommonName: nil))
        XCTAssertFalse(DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: "", leafCommonName: "Developer ID Application: Foo (ABC1234567)"))
        XCTAssertFalse(DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: "ABC1234567", leafCommonName: "Apple Development: Foo (ABC1234567)"))
        XCTAssertTrue(DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: "ABC1234567", leafCommonName: "Developer ID Application: Foo (ABC1234567)"))
        XCTAssertFalse(DualTrackPrivilegeEscalator.currentProcessHasDeveloperIDTeam())
    }

    func testHelperSecurityValidatorAndEmbeddedHelperBundle() throws {
        XCTAssertTrue(HelperSecurityValidator.validateBundleIdentifier("app.makedie.MacOver"))
        XCTAssertTrue(HelperSecurityValidator.validateBundleIdentifier("com.example.app-1_2"))
        XCTAssertFalse(HelperSecurityValidator.validateBundleIdentifier("nodot"))
        XCTAssertFalse(HelperSecurityValidator.validateBundleIdentifier("foo; rm -rf /"))
        XCTAssertFalse(HelperSecurityValidator.validateBundleIdentifier("../evil.id"))
        XCTAssertFalse(HelperSecurityValidator.validateBundleIdentifier(".leading.dot"))

        XCTAssertEqual(
            HelperSecurityValidator.validateContainerPath("/Users/alice/Library/Containers/app.makedie.MacOver/Data"),
            "/Users/alice/Library/Containers/app.makedie.MacOver/Data"
        )
        XCTAssertNil(HelperSecurityValidator.validateContainerPath("/System/Library"))
        XCTAssertNil(HelperSecurityValidator.validateContainerPath("/etc/passwd"))
        XCTAssertNil(HelperSecurityValidator.validateContainerPath("/Users/alice/Library/Containers/../Desktop"))
        XCTAssertNil(HelperSecurityValidator.validateContainerPath(""))

        // Hosted test host (MacOver.app) must embed Track A helper tool and launchd daemon plist.
        let hostBundle = Bundle.main
        XCTAssertTrue(DualTrackPrivilegeEscalator.embeddedHelperDaemonPlistExists(in: hostBundle))

        let plistURL = hostBundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(DualTrackPrivilegeEscalator.helperDaemonPlistName)
        let plistData = try Data(contentsOf: plistURL)
        let parsed = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(parsed["Label"] as? String, DualTrackPrivilegeEscalator.helperMachServiceName)
        XCTAssertEqual(parsed["BundleProgram"] as? String, "Contents/Library/HelperTools/PlayCoverHelper")
        let machServices = parsed["MachServices"] as? [String: Bool]
        XCTAssertEqual(machServices?[DualTrackPrivilegeEscalator.helperMachServiceName], true)
    }

    @MainActor
    func testStartupAlertCenterQueueAndDeduplication() {
        let center = StartupAlertCenter()
        center.enqueue(.lowPowerMode)
        center.enqueue(.lowPowerMode) // deduplicated
        center.enqueue(.audioSampleRate(deviceID: 42, currentSampleRate: 96000))

        XCTAssertEqual(center.activeAlert, .lowPowerMode)
        center.dismissCurrent()
        XCTAssertEqual(center.activeAlert, .audioSampleRate(deviceID: 42, currentSampleRate: 96000))
        center.dismissCurrent()
        XCTAssertNil(center.activeAlert)
    }

    func testSyncUserPluginsCopiesDylibsSidecarManifestsAndBundleSubdirs() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("SyncUserPluginsTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let storeDir = tempRoot.appendingPathComponent("Store", isDirectory: true)
        let targetDir = tempRoot.appendingPathComponent("TargetUserPlugins", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)

        // Pre-populate stale target directory to confirm replacement semantics.
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: targetDir.appendingPathComponent("Stale.dylib"))

        // Top-level dylib + sidecar manifest
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: storeDir.appendingPathComponent("Alpha.dylib"))
        try Data("{\"identifier\":\"com.example.alpha\"}".utf8)
            .write(to: storeDir.appendingPathComponent("Alpha.manifest.json"))

        // Unrelated text/json file that must NOT be copied, plus subdir without PluginManifest.json
        try Data("ignore".utf8).write(to: storeDir.appendingPathComponent("notes.json"))
        let unmanifestedDir = storeDir.appendingPathComponent("NoManifest", isDirectory: true)
        try fm.createDirectory(at: unmanifestedDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: unmanifestedDir.appendingPathComponent("Ignored.dylib"))

        // Subdirectory plugin with PluginManifest.json
        let subDir = storeDir.appendingPathComponent("BetaBundle", isDirectory: true)
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("{\"identifier\":\"com.example.beta\"}".utf8)
            .write(to: subDir.appendingPathComponent("PluginManifest.json"))
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: subDir.appendingPathComponent("libBeta.dylib"))

        var signedFilenames: [String] = []
        try PlayTools.syncUserPlugins(from: storeDir, into: targetDir) { signedURL in
            signedFilenames.append(signedURL.lastPathComponent)
        }

        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent("Stale.dylib").path))
        XCTAssertTrue(fm.fileExists(atPath: targetDir.appendingPathComponent("Alpha.dylib").path))
        XCTAssertTrue(fm.fileExists(atPath: targetDir.appendingPathComponent("Alpha.manifest.json").path))
        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent("notes.json").path))
        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent("NoManifest").path))
        XCTAssertTrue(fm.fileExists(atPath: targetDir.appendingPathComponent("BetaBundle/PluginManifest.json").path))
        XCTAssertTrue(fm.fileExists(atPath: targetDir.appendingPathComponent("BetaBundle/libBeta.dylib").path))
        XCTAssertEqual(Set(signedFilenames), ["Alpha.dylib", "libBeta.dylib"])

        // Empty store must remove existing targetDir cleanly without recreating it.
        let emptyStore = tempRoot.appendingPathComponent("EmptyStore", isDirectory: true)
        try fm.createDirectory(at: emptyStore, withIntermediateDirectories: true)
        try PlayTools.syncUserPlugins(from: emptyStore, into: targetDir) { _ in }
        XCTAssertFalse(fm.fileExists(atPath: targetDir.path))
    }

    @MainActor
    func testAlertPresenterQueueAndStartupSafeModeAlert() async {
        let center = StartupAlertCenter()
        center.enqueue(.safeModeActivated(
            appName: "MockApp",
            bundleID: "com.example.mock",
            breadcrumbPath: "/tmp/nonexistent/.launching_in_progress"
        ))
        XCTAssertEqual(
            center.activeAlert,
            .safeModeActivated(
                appName: "MockApp",
                bundleID: "com.example.mock",
                breadcrumbPath: "/tmp/nonexistent/.launching_in_progress"
            )
        )
        center.dismissCurrent()
        XCTAssertNil(center.activeAlert)

        let presenter = AlertPresenter()
        var recordedTitles: [String] = []
        presenter.testHandler = { req in
            recordedTitles.append(req.title)
            return PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true)
        }
        let first = await presenter.present(
            PlayCoverAlertRequest(
                title: "First",
                message: "Body",
                style: .warning,
                buttons: [
                    PlayCoverAlertButton(title: "OK"),
                    PlayCoverAlertButton(title: "Cancel", isCancel: true)
                ],
                suppressionTitle: "Don't ask again"
            )
        )
        XCTAssertEqual(first, PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true))
        XCTAssertEqual(recordedTitles, ["First"])

        presenter.testHandler = nil
        let autoResolved = await presenter.present(
            PlayCoverAlertRequest(
                title: "Auto",
                message: "Running in unit test",
                buttons: [
                    PlayCoverAlertButton(title: "Proceed"),
                    PlayCoverAlertButton(title: "Cancel", isCancel: true)
                ]
            )
        )
        XCTAssertEqual(autoResolved, PlayCoverAlertResponse(buttonIndex: 1, suppressionChecked: false))
    }

    func testAppSettingsDataCompatibilityAndRestartDiff() throws {
        let legacyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>resolution</key><integer>6</integer>
            <key>customScaler</key><real>2.0</real>
            <key>windowWidth</key><integer>1920</integer>
            <key>windowHeight</key><integer>1080</integer>
        </dict>
        </plist>
        """
        let legacy = try PropertyListDecoder().decode(AppSettingsData.self, from: Data(legacyPlist.utf8))
        XCTAssertEqual(legacy.frameRateTarget, "adaptive")
        XCTAssertEqual(legacy.reportedIOSVersion, "automatic")
        XCTAssertEqual(legacy.frameRateTargetMode, .adaptive)
        XCTAssertEqual(legacy.reportedIOSVersionMode, .automatic)
        XCTAssertEqual(legacy.pixelBudget.level, .caution)

        var configured = legacy
        configured.frameRateTarget = "fixed60"
        configured.reportedIOSVersion = "compat18_3"
        let encoded = try PropertyListEncoder().encode(configured)
        let roundTripped = try PropertyListDecoder().decode(AppSettingsData.self, from: encoded)
        XCTAssertEqual(roundTripped.frameRateTargetMode, .fixed60)
        XCTAssertEqual(roundTripped.reportedIOSVersionMode, .compat18_3)

        configured.reportedIOSVersion = "compat13_7"
        let compat13Encoded = try PropertyListEncoder().encode(configured)
        let compat13Decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: compat13Encoded)
        XCTAssertEqual(compat13Decoded.reportedIOSVersionMode, .compat13_7)
        XCTAssertEqual(compat13Decoded.reportedIOSVersion, "compat13_7")

        var invalidNormalized = configured
        invalidNormalized.frameRateTarget = "bogus"
        invalidNormalized.reportedIOSVersion = "bogus"
        let redecoded = try PropertyListDecoder().decode(
            AppSettingsData.self,
            from: try PropertyListEncoder().encode(invalidNormalized)
        )
        XCTAssertEqual(redecoded.frameRateTarget, "adaptive")
        XCTAssertEqual(redecoded.reportedIOSVersion, "automatic")

        var compat = legacy
        compat.windowCompatibility = .invertedMetrics
        XCTAssertTrue(compat.inverseScreenValues)
        XCTAssertEqual(compat.windowFixMethod, 0)
        XCTAssertEqual(compat.resolution, 6)

        compat.windowCompatibility = .standard
        XCTAssertFalse(compat.inverseScreenValues)
        XCTAssertEqual(compat.windowFixMethod, 0)
        XCTAssertEqual(compat.resolution, 6)

        compat.windowCompatibility = .invertedLegacyResize
        XCTAssertTrue(compat.inverseScreenValues)
        XCTAssertEqual(compat.windowFixMethod, 1)
        XCTAssertEqual(compat.resolution, 0)

        XCTAssertEqual(legacy.restartRequiredChanges(comparedTo: legacy), [])
        var updated = legacy
        updated.windowWidth = 2560
        updated.windowCompatibility = .invertedMetrics
        updated.frameRateTargetMode = .fixed30
        updated.reportedIOSVersionMode = .compat18_3
        XCTAssertEqual(
            updated.restartRequiredChanges(comparedTo: legacy),
            [.windowSize, .windowCompatibility, .frameRateTarget, .reportedIOSVersion]
        )
    }

    func testAppSettingsObservableAndPresetsAndDeviceOptions() throws {
        let dir = try XCTUnwrap(tempDir)
        let infoURL = dir.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.configtest",
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: infoURL)
        let info = AppInfo(contentsOf: infoURL)
        let settingsURL = dir.appendingPathComponent("settings.plist")
        let appSettings = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.2)

        var notifications = 0
        let token = appSettings.objectWillChange.sink { _ in
            notifications += 1
        }
        defer { token.cancel() }

        appSettings.settings.customScaler = 1.5
        appSettings.update { $0.frameRateTargetMode = .fixed60 }
        appSettings.openWithLLDB = true
        appSettings.reset()
        XCTAssertGreaterThanOrEqual(notifications, 4)

        for preset in PlayAppSettingsPreset.allCases {
            var candidate = AppSettingsData()
            preset.apply(to: &candidate)
            XCTAssertTrue(preset.matches(candidate))
        }

        let dims1080 = AppSettingsData.computedDimensions(
            resolution: 2, aspectRatio: 1, customWidth: 0, customHeight: 0
        )
        XCTAssertEqual(dims1080.width, 1920)
        XCTAssertEqual(dims1080.height, 1080)

        let dimsCustom = AppSettingsData.computedDimensions(
            resolution: 5, aspectRatio: 0, customWidth: 1600, customHeight: 900
        )
        XCTAssertEqual(dimsCustom.width, 1600)
        XCTAssertEqual(dimsCustom.height, 900)

        var countData = AppSettingsData()
        XCTAssertEqual(
            countData.activeTroubleshootingCount(hasIntrospection: false, hasIosFrameworks: false, openWithLLDB: false),
            0
        )
        countData.metalHUD = true
        countData.rootWorkDir = false
        countData.blockSleepSpamming = true
        XCTAssertEqual(
            countData.activeTroubleshootingCount(hasIntrospection: true, hasIosFrameworks: false, openWithLLDB: true),
            5
        )

        XCTAssertTrue(DeviceProfileOption.isLegacyModel("iPad6,7"))
        XCTAssertTrue(DeviceProfileOption.isLegacyModel("iPad8,6"))
        XCTAssertTrue(DeviceProfileOption.isLegacyModel("iPhone12,5"))
        XCTAssertFalse(DeviceProfileOption.isLegacyModel("iPad17,3"))
        XCTAssertTrue(DeviceProfileOption.supportsIOS13("iPad8,6"))
        XCTAssertTrue(DeviceProfileOption.supportsIOS13("iPhone12,5"))
        XCTAssertFalse(DeviceProfileOption.supportsIOS13("iPad13,8"))
        XCTAssertFalse(DeviceProfileOption.supportsIOS13("iPhone17,2"))
        XCTAssertEqual(DeviceProfileOption.recommendedIOS13Model(isIPhone: false), "iPad8,6")
        XCTAssertEqual(DeviceProfileOption.recommendedIOS13Model(isIPhone: true), "iPhone12,5")
        XCTAssertTrue(DeviceProfileOption.isIPhone("iPhone18,2"))
        XCTAssertFalse(DeviceProfileOption.isIPhone("iPad17,3"))

        appSettings.update {
            $0.iosDeviceModel = "iPad13,8"
            $0.reportedIOSVersionMode = .compat13_7
        }
        appSettings.sync()
        XCTAssertEqual(appSettings.settings.iosDeviceModel, "iPad8,6")

        appSettings.update {
            $0.iosDeviceModel = "iPhone18,2"
            $0.reportedIOSVersionMode = .compat13_7
        }
        appSettings.sync()
        XCTAssertEqual(appSettings.settings.iosDeviceModel, "iPhone12,5")
    }

    func testCommitAppBackupsReplacesOrInvalidatesStaleBackups() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.appbackups"
        let targetDir = dir.appendingPathComponent("AppBackups").appendingPathComponent(bundleID)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let oldExec = targetDir.appendingPathComponent("executable")
        try Data("v1-binary".utf8).write(to: oldExec)

        // Replacing with valid staged artifacts swaps in v2
        let stagingV2 = dir.appendingPathComponent("staging-v2")
        try fm.createDirectory(at: stagingV2, withIntermediateDirectories: true)
        try Data("v2-binary".utf8).write(to: stagingV2.appendingPathComponent("executable"))
        Installer.commitAppBackups(.staged(stagingV2), to: targetDir, bundleIdentifier: bundleID)
        XCTAssertEqual(try String(contentsOf: oldExec, encoding: .utf8), "v2-binary")

        // Upgrade with no applicable backup artifacts (e.g. Fat binary without mobileprovision)
        // must remove stale v2 backup so runtime does not serve old binary to v3 app.
        Installer.commitAppBackups(.noneApplicable, to: targetDir, bundleIdentifier: bundleID)
        XCTAssertFalse(fm.fileExists(atPath: targetDir.path))

        // Failed or empty staging after app bundle wrap must also invalidate stale backup.
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data("v3-binary".utf8).write(to: oldExec)
        Installer.commitAppBackups(.failed, to: targetDir, bundleIdentifier: bundleID)
        XCTAssertFalse(fm.fileExists(atPath: targetDir.path))
    }
}
