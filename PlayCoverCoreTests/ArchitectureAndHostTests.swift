import Combine
import Darwin
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
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(legacy.effectivePixelBudget(physicalMemoryBytes: 8 * gib).level, .over)
        XCTAssertEqual(legacy.effectivePixelBudget(physicalMemoryBytes: 16 * gib).level, .over)
        XCTAssertEqual(legacy.effectivePixelBudget(physicalMemoryBytes: 24 * gib).level, .caution)
        XCTAssertEqual(legacy.effectivePixelBudget(physicalMemoryBytes: 32 * gib).level, .ok)
        XCTAssertEqual(
            legacy.pixelBudget,
            legacy.effectivePixelBudget(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        )

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

        var strictUpdated = legacy
        strictUpdated.strictEmulationMode = true
        strictUpdated.strictViewportOrientation = .portrait
        strictUpdated.strictViewportScaleMode = .native1x
        let strictDiff = strictUpdated.restartRequiredChanges(comparedTo: legacy)
        XCTAssertTrue(strictDiff.contains(.strictEmulationMode))
        XCTAssertTrue(strictDiff.contains(.strictViewportOrientation))
        XCTAssertTrue(strictDiff.contains(.strictViewportScaleMode))
        XCTAssertTrue(strictDiff.contains(.interceptInlineSyscalls))
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
        XCTAssertTrue(appSettings.flush())
        XCTAssertEqual(appSettings.settings.iosDeviceModel, "iPad13,8")
        XCTAssertEqual(appSettings.settings.effectiveIOSDeviceModel, "iPad8,6")
        let reloadedPad = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.2)
        XCTAssertEqual(reloadedPad.settings.iosDeviceModel, "iPad13,8")
        XCTAssertEqual(reloadedPad.settings.effectiveIOSDeviceModel, "iPad8,6")
        appSettings.update { $0.reportedIOSVersionMode = .automatic }
        XCTAssertEqual(appSettings.settings.iosDeviceModel, "iPad13,8")
        XCTAssertEqual(appSettings.settings.effectiveIOSDeviceModel, "iPad13,8")

        appSettings.update {
            $0.iosDeviceModel = "iPhone18,2"
            $0.reportedIOSVersionMode = .compat13_7
        }
        appSettings.sync()
        XCTAssertTrue(appSettings.flush())
        XCTAssertEqual(appSettings.settings.iosDeviceModel, "iPhone18,2")
        XCTAssertEqual(appSettings.settings.effectiveIOSDeviceModel, "iPhone12,5")
        appSettings.update { $0.reportedIOSVersionMode = .compat18_3 }
        XCTAssertEqual(appSettings.settings.iosDeviceModel, "iPhone18,2")
        XCTAssertEqual(appSettings.settings.effectiveIOSDeviceModel, "iPhone18,2")

        appSettings.update {
            $0.resolution = 1
            $0.windowWidth = 1234
            $0.windowHeight = 567
            $0.strictEmulationMode = true
        }
        appSettings.sync()
        XCTAssertEqual(appSettings.settings.windowWidth, 1234)
        XCTAssertEqual(appSettings.settings.windowHeight, 567)

        let defaultRules = try Entitlements.getDefaultRules()
        XCTAssertTrue(defaultRules.blocklist?.contains("/System/Library/CoreServices/Finder.app") ?? false)

        let sandboxAppDir = dir.appendingPathComponent("StrictSandboxProbe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxAppDir, withIntermediateDirectories: true)
        let probeBundleID = "com.example.strictprobe.\(UUID().uuidString.lowercased())"
        let probeInfo: [String: Any] = [
            "CFBundleIdentifier": probeBundleID,
            "CFBundleExecutable": "StrictSandboxProbe",
            "CFBundleShortVersionString": "1.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: probeInfo, format: .xml, options: 0)
            .write(to: sandboxAppDir.appendingPathComponent("Info.plist"))
        let probeApp = PlayApp(appUrl: sandboxAppDir)
        let probeSettingsURL = AppSettings.settingsURL(forBundleIdentifier: probeBundleID)
        defer {
            _ = probeApp.settings.flush()
            try? FileManager.default.removeItem(at: probeSettingsURL)
        }

        probeApp.settings.update {
            $0.bypass = false
            $0.strictEmulationMode = false
        }
        let nonStrictEnts = try Entitlements.composeEntitlements(probeApp)
        let nonStrictSBPL = (nonStrictEnts["com.apple.security.temporary-exception.sbpl"] as? [String] ?? [])
            .joined(separator: "\n")
        XCTAssertFalse(nonStrictSBPL.contains("/System/Library/CoreServices/Finder.app"))

        probeApp.settings.update {
            $0.bypass = false
            $0.strictEmulationMode = true
        }
        let strictEnts = try Entitlements.composeEntitlements(probeApp)
        let strictSBPL = (strictEnts["com.apple.security.temporary-exception.sbpl"] as? [String] ?? [])
            .joined(separator: "\n")
        XCTAssertTrue(strictSBPL.contains("/System/Library/CoreServices/Finder.app"))
    }

    func testCommitAppBackupsReplacesOrInvalidatesStaleBackups() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.appbackups"
        let targetDir = dir.appendingPathComponent("AppBackups").appendingPathComponent(bundleID)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let oldExec = targetDir.appendingPathComponent("executable")
        try Data("v1-binary".utf8).write(to: oldExec)

        // Replacing with valid staged artifacts and manifest swaps in v2 + manifest.plist
        let stagingV2 = dir.appendingPathComponent("staging-v2")
        try fm.createDirectory(at: stagingV2, withIntermediateDirectories: true)
        try Data("v2-binary".utf8).write(to: stagingV2.appendingPathComponent("executable"))
        let manifestV2 = Installer.AppBackupManifest(
            bundleIdentifier: bundleID,
            shortVersionString: "2.0.0",
            bundleVersion: "200",
            installGeneration: "GEN-V2-UUID"
        )
        try Installer.commitAppBackups(
            .staged(stagingV2),
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: manifestV2
        )
        XCTAssertEqual(try String(contentsOf: oldExec, encoding: .utf8), "v2-binary")
        let manifestURL = targetDir.appendingPathComponent(Installer.backupManifestFileName)
        XCTAssertTrue(fm.fileExists(atPath: manifestURL.path))

        // Upgrade with no applicable backup artifacts (e.g. Fat binary without mobileprovision)
        // must remove stale v2 backup so runtime does not serve old binary to v3 app.
        try Installer.commitAppBackups(
            .noneApplicable,
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: nil
        )
        XCTAssertFalse(fm.fileExists(atPath: targetDir.path))

        // Failed or empty staging after app bundle wrap must also invalidate stale backup.
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data("v3-binary".utf8).write(to: oldExec)
        try Installer.commitAppBackups(
            .failed,
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: manifestV2
        )
        XCTAssertFalse(fm.fileExists(atPath: targetDir.path))
    }

    func testAppBackupManifestBindsGenerationAndBundleVersion() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.manifestbind"
        let targetDir = dir.appendingPathComponent("AppBackups").appendingPathComponent(bundleID)
        let appDir = dir.appendingPathComponent("Sample.app", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        let infoURL = appDir.appendingPathComponent("Info.plist")
        let cleanInfoDict: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            "MinimumOSVersion": "16.4"
        ]
        try PropertyListSerialization.data(fromPropertyList: cleanInfoDict, format: .xml, options: 0)
            .write(to: infoURL)
        let stagingClean = dir.appendingPathComponent("staging-clean-info")
        let baseSampleApp = BaseApp(appUrl: appDir)
        if case .staged(let stagedURL) = Installer.stageAppBackups(for: baseSampleApp, in: stagingClean) {
            let stagedInfoData = try Data(contentsOf: stagedURL.appendingPathComponent("Info.plist"))
            let stagedParsed = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: stagedInfoData, format: nil) as? [String: Any]
            )
            XCTAssertNil(stagedParsed[Installer.installGenerationInfoKey])
            XCTAssertEqual(stagedParsed["MinimumOSVersion"] as? String, "16.4")
        } else {
            XCTFail("Expected stageAppBackups to stage clean Info.plist")
        }

        let v1Gen = UUID().uuidString
        let infoDict: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            Installer.installGenerationInfoKey: v1Gen
        ]
        try PropertyListSerialization.data(fromPropertyList: infoDict, format: .xml, options: 0)
            .write(to: infoURL)
        let appInfo = AppInfo(contentsOf: infoURL)

        let stagingV1 = dir.appendingPathComponent("staging-v1")
        try fm.createDirectory(at: stagingV1, withIntermediateDirectories: true)
        try Data("v1-exec".utf8).write(to: stagingV1.appendingPathComponent("executable"))
        try Installer.commitAppBackups(
            .staged(stagingV1),
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: Installer.AppBackupManifest(appInfo: appInfo)
        )
        XCTAssertTrue(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Reinstall or crash-interrupted upgrade with a different installGeneration must reject stale backup
        appInfo[string: Installer.installGenerationInfoKey] = UUID().uuidString
        XCTAssertFalse(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Restore generation, mutate CFBundleVersion -> must reject mismatched version
        appInfo[string: Installer.installGenerationInfoKey] = v1Gen
        XCTAssertTrue(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))
        appInfo[string: "CFBundleVersion"] = "46"
        XCTAssertFalse(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Legacy backup directory without manifest.plist must be rejected
        appInfo[string: "CFBundleVersion"] = "45"
        try fm.removeItem(at: targetDir.appendingPathComponent(Installer.backupManifestFileName))
        XCTAssertFalse(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Committing staged artifacts without valid manifest must refuse and invalidate targetDir
        let stagingUnbound = dir.appendingPathComponent("staging-unbound")
        try fm.createDirectory(at: stagingUnbound, withIntermediateDirectories: true)
        try Data("unbound-exec".utf8).write(to: stagingUnbound.appendingPathComponent("executable"))
        try Installer.commitAppBackups(
            .staged(stagingUnbound),
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: nil
        )
        XCTAssertFalse(fm.fileExists(atPath: targetDir.path))
    }

    func testAppBackupsPreWrapQuarantineAndWrapReplacementSafety() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.txnsafety"
        let backupsRoot = dir.appendingPathComponent("AppBackups", isDirectory: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("v1-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))

        // Pre-wrap quarantine moves active AppBackups/<bundleID> out of runtime path immediately
        let quarantined = try XCTUnwrap(
            Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
        )
        XCTAssertFalse(fm.fileExists(atPath: targetBackupDir.path))
        XCTAssertTrue(fm.fileExists(atPath: quarantined.path))

        // Pre-wrap failure restores quarantined backup when new .app was never published
        Installer.restoreQuarantinedAppBackups(quarantined, to: targetBackupDir, bundleIdentifier: bundleID)
        XCTAssertTrue(fm.fileExists(atPath: targetBackupDir.path))
        XCTAssertFalse(fm.fileExists(atPath: quarantined.path))

        // Post-wrap commit cleans up quarantined directory and any orphan .invalidated-* siblings
        let quarantined2 = try XCTUnwrap(
            Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
        )
        let orphanInvalidated = backupsRoot.appendingPathComponent(".\(bundleID).invalidated-orphan")
        try fm.createDirectory(at: orphanInvalidated, withIntermediateDirectories: true)
        Installer.cleanupInvalidatedAppBackups(
            primary: quarantined2,
            in: backupsRoot,
            bundleIdentifier: bundleID
        )
        XCTAssertFalse(fm.fileExists(atPath: quarantined2.path))
        XCTAssertFalse(fm.fileExists(atPath: orphanInvalidated.path))

        // wrap(_:into:) replaces existing .app atomically and preserves existing .app if source fails
        let appsDir = dir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let existingAppURL = appsDir.appendingPathComponent("\(bundleID).app", isDirectory: true)
        try fm.createDirectory(at: existingAppURL, withIntermediateDirectories: true)
        let v1Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: v1Info, format: .xml, options: 0)
            .write(to: existingAppURL.appendingPathComponent("Info.plist"))
        try Data("v1-live".utf8).write(to: existingAppURL.appendingPathComponent("Sample"))

        // Broken incoming app whose directory vanished before move must not delete existing .app
        let brokenCandidateURL = dir.appendingPathComponent("BrokenIncoming.app", isDirectory: true)
        try fm.createDirectory(at: brokenCandidateURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: v1Info, format: .xml, options: 0)
            .write(to: brokenCandidateURL.appendingPathComponent("Info.plist"))
        let brokenBaseApp = BaseApp(appUrl: brokenCandidateURL)
        try fm.removeItem(at: brokenCandidateURL)
        XCTAssertThrowsError(try Installer.wrap(brokenBaseApp, into: appsDir))
        XCTAssertEqual(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8),
            "v1-live"
        )

        // Valid v2 incoming app swaps cleanly into Applications/<bundleID>.app
        let incomingV2URL = dir.appendingPathComponent("IncomingV2.app", isDirectory: true)
        try fm.createDirectory(at: incomingV2URL, withIntermediateDirectories: true)
        let v2Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "2.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: v2Info, format: .xml, options: 0)
            .write(to: incomingV2URL.appendingPathComponent("Info.plist"))
        try Data("v2-live".utf8).write(to: incomingV2URL.appendingPathComponent("Sample"))
        let v2BaseApp = BaseApp(appUrl: incomingV2URL)
        let wrappedURL = try Installer.wrap(v2BaseApp, into: appsDir)
        XCTAssertEqual(wrappedURL.standardizedFileURL, existingAppURL.standardizedFileURL)
        XCTAssertEqual(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8),
            "v2-live"
        )
        let appDirEntries = try fm.contentsOfDirectory(atPath: appsDir.path)
        XCTAssertEqual(appDirEntries, ["\(bundleID).app"])

        // Pre-swap sign/verify failure must keep existing v2 .app intact and clean up staging artifacts
        let failingSignCandidateURL = dir.appendingPathComponent("FailingSignV3.app", isDirectory: true)
        try fm.createDirectory(at: failingSignCandidateURL, withIntermediateDirectories: true)
        let v3Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "3.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: v3Info, format: .xml, options: 0)
            .write(to: failingSignCandidateURL.appendingPathComponent("Info.plist"))
        try Data("v3-unsigned".utf8).write(to: failingSignCandidateURL.appendingPathComponent("Sample"))
        let failingSignApp = BaseApp(appUrl: failingSignCandidateURL)

        var liveContentDuringStaging: String?
        XCTAssertThrowsError(
            try Installer.publishSignedBundle(
                failingSignApp,
                into: appsDir,
                prepareAndVerify: { stagedURL, targetLocation in
                    XCTAssertEqual(targetLocation.standardizedFileURL, existingAppURL.standardizedFileURL)
                    XCTAssertNotEqual(stagedURL.standardizedFileURL, existingAppURL.standardizedFileURL)
                    liveContentDuringStaging = try String(
                        contentsOf: existingAppURL.appendingPathComponent("Sample"),
                        encoding: .utf8
                    )
                    throw PlayCoverError.shellExecutionFailed(
                        binary: "/usr/bin/codesign",
                        status: 1,
                        output: "simulated codesign failure"
                    )
                }
            )
        )
        XCTAssertEqual(liveContentDuringStaging, "v2-live")
        XCTAssertEqual(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8),
            "v2-live"
        )
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: appsDir.path), ["\(bundleID).app"])

        // Post-swap commit failure must atomically roll back to v2-live and leave no staging leftovers
        let failingPostSwapURL = dir.appendingPathComponent("FailingPostSwapV3.app", isDirectory: true)
        try fm.createDirectory(at: failingPostSwapURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: v3Info, format: .xml, options: 0)
            .write(to: failingPostSwapURL.appendingPathComponent("Info.plist"))
        try Data("v3-signed".utf8).write(to: failingPostSwapURL.appendingPathComponent("Sample"))
        let failingPostSwapApp = BaseApp(appUrl: failingPostSwapURL)

        var sawPublishedV3BeforeRollback = false
        XCTAssertThrowsError(
            try Installer.publishSignedBundle(
                failingPostSwapApp,
                into: appsDir,
                prepareAndVerify: { _, _ in },
                afterSwap: { publishedURL in
                    let publishedContent = try String(
                        contentsOf: publishedURL.appendingPathComponent("Sample"),
                        encoding: .utf8
                    )
                    sawPublishedV3BeforeRollback = (publishedContent == "v3-signed")
                    throw PlayCoverError.entitlementsError("simulated post-swap failure")
                }
            )
        )
        XCTAssertTrue(sawPublishedV3BeforeRollback)
        XCTAssertEqual(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8),
            "v2-live"
        )
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: appsDir.path), ["\(bundleID).app"])
    }

    func testRollbackFailureAndBackupCommitFailurePreservePreviousArtifacts() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.rollbackpreserve"

        // 1. Unrecoverable rollback failure must never delete the sole previous .app:
        //    (a) When target bundle is locked (UF_IMMUTABLE) while destinationDir is writable,
        //        previous .app is rescued beside location and stagingRoot is cleaned up.
        //    (b) When destinationDir itself is read-only (0o555), stagingRoot is retained intact
        //        so defer never deletes the previous .app's contents inside stagingRoot.
        let appsDir = dir.appendingPathComponent("ApplicationsRollback", isDirectory: true)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let existingAppURL = appsDir.appendingPathComponent("\(bundleID).app", isDirectory: true)
        try fm.createDirectory(at: existingAppURL, withIntermediateDirectories: true)
        let v1Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0"
        ]
        let v2Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "2.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: v1Info, format: .xml, options: 0)
            .write(to: existingAppURL.appendingPathComponent("Info.plist"))
        try Data("v1-precious".utf8).write(to: existingAppURL.appendingPathComponent("Sample"))

        let candidateImmutableURL = dir.appendingPathComponent("CandidateImmutableV2.app", isDirectory: true)
        try fm.createDirectory(at: candidateImmutableURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: v2Info, format: .xml, options: 0)
            .write(to: candidateImmutableURL.appendingPathComponent("Info.plist"))
        try Data("v2-published".utf8).write(to: candidateImmutableURL.appendingPathComponent("Sample"))

        var chflagsApplied = false
        var reportedPreservedSiblingURL: URL?
        defer {
            if chflagsApplied {
                _ = Darwin.chflags(existingAppURL.path, 0)
            }
        }
        XCTAssertThrowsError(
            try Installer.publishSignedBundle(
                BaseApp(appUrl: candidateImmutableURL),
                into: appsDir,
                prepareAndVerify: { _, _ in },
                afterSwap: { publishedURL in
                    if Darwin.chflags(publishedURL.path, UInt32(UF_IMMUTABLE)) == 0 {
                        chflagsApplied = true
                    }
                    throw PlayCoverError.entitlementsError("post-swap failure with immutable target")
                },
                onUnrecoverableRollbackFailure: { _, preservedURL in
                    reportedPreservedSiblingURL = preservedURL
                }
            )
        )
        if chflagsApplied {
            _ = Darwin.chflags(existingAppURL.path, 0)
            chflagsApplied = false
            let rescuedURL = try XCTUnwrap(reportedPreservedSiblingURL)
            XCTAssertEqual(
                rescuedURL.deletingLastPathComponent().standardizedFileURL,
                appsDir.standardizedFileURL
            )
            XCTAssertEqual(
                try String(contentsOf: rescuedURL.appendingPathComponent("Sample"), encoding: .utf8),
                "v1-precious"
            )
            // Restore v1-precious back to existingAppURL for subtest (b)
            try fm.removeItem(at: existingAppURL)
            try fm.moveItem(at: rescuedURL, to: existingAppURL)
        }

        if Darwin.geteuid() != 0 {
            let candidateReadOnlyDirURL = dir.appendingPathComponent("CandidateReadOnlyV2.app", isDirectory: true)
            try fm.createDirectory(at: candidateReadOnlyDirURL, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: v2Info, format: .xml, options: 0)
                .write(to: candidateReadOnlyDirURL.appendingPathComponent("Info.plist"))
            try Data("v2-ro".utf8).write(to: candidateReadOnlyDirURL.appendingPathComponent("Sample"))

            var lockedAppsDir = false
            var reportedPreservedInStagingURL: URL?
            defer {
                if lockedAppsDir {
                    _ = Darwin.chmod(appsDir.path, mode_t(0o755))
                }
            }
            XCTAssertThrowsError(
                try Installer.publishSignedBundle(
                    BaseApp(appUrl: candidateReadOnlyDirURL),
                    into: appsDir,
                    prepareAndVerify: { _, _ in },
                    afterSwap: { _ in
                        XCTAssertEqual(Darwin.chmod(appsDir.path, mode_t(0o555)), 0)
                        lockedAppsDir = true
                        throw PlayCoverError.entitlementsError("post-swap failure with read-only parent")
                    },
                    onUnrecoverableRollbackFailure: { _, preservedURL in
                        reportedPreservedInStagingURL = preservedURL
                    }
                )
            )
            XCTAssertEqual(Darwin.chmod(appsDir.path, mode_t(0o755)), 0)
            lockedAppsDir = false
            let preservedStagingBundle = try XCTUnwrap(reportedPreservedInStagingURL)
            XCTAssertEqual(
                try String(contentsOf: preservedStagingBundle.appendingPathComponent("Sample"), encoding: .utf8),
                "v1-precious"
            )
        }

        // 2. commitAppBackups failure must restore previousDir -> targetDir, never delete existing backup,
        //    and always throw even when targetDir is absent (never treat missing targetDir as commit success).
        let backupsRoot = dir.appendingPathComponent("AppBackupsPreserve", isDirectory: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("v1-backup-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))

        let missingIncoming = backupsRoot.appendingPathComponent(".missing-incoming-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try Installer.replaceBackupDirectoryAtomically(
                incomingDir: missingIncoming,
                targetDir: targetBackupDir,
                parentDir: backupsRoot,
                bundleIdentifier: bundleID,
                allowRenameSwap: false
            )
        )
        XCTAssertEqual(
            try String(contentsOf: targetBackupDir.appendingPathComponent("executable"), encoding: .utf8),
            "v1-backup-exec"
        )

        if Darwin.geteuid() != 0 {
            let stagingV2 = dir.appendingPathComponent("staging-v2-fail", isDirectory: true)
            try fm.createDirectory(at: stagingV2, withIntermediateDirectories: true)
            try Data("v2-backup-exec".utf8).write(to: stagingV2.appendingPathComponent("executable"))
            let manifestV2 = Installer.AppBackupManifest(
                bundleIdentifier: bundleID,
                shortVersionString: "2.0",
                bundleVersion: "2",
                installGeneration: "GEN-V2"
            )
            XCTAssertEqual(Darwin.chmod(backupsRoot.path, mode_t(0o555)), 0)
            defer { _ = Darwin.chmod(backupsRoot.path, mode_t(0o755)) }
            XCTAssertThrowsError(
                try Installer.commitAppBackups(
                    .staged(stagingV2),
                    to: targetBackupDir,
                    bundleIdentifier: bundleID,
                    manifest: manifestV2
                )
            )
            // Even when targetDir does not exist (quarantined pre-swap), commit failure must throw!
            let quarantinedTargetDir = backupsRoot.appendingPathComponent("com.example.absenttarget", isDirectory: true)
            XCTAssertThrowsError(
                try Installer.commitAppBackups(
                    .staged(stagingV2),
                    to: quarantinedTargetDir,
                    bundleIdentifier: "com.example.absenttarget",
                    manifest: Installer.AppBackupManifest(
                        bundleIdentifier: "com.example.absenttarget",
                        shortVersionString: "2.0",
                        bundleVersion: "2",
                        installGeneration: "GEN-V2"
                    )
                )
            )
            XCTAssertEqual(Darwin.chmod(backupsRoot.path, mode_t(0o755)), 0)
            XCTAssertEqual(
                try String(contentsOf: targetBackupDir.appendingPathComponent("executable"), encoding: .utf8),
                "v1-backup-exec"
            )
        }

        // 3. Unrestored quarantined AppBackups must NOT be deleted by cleanupInvalidatedAppBackups.
        let quarantined = try XCTUnwrap(
            Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
        )
        let orphanInvalidated = backupsRoot.appendingPathComponent(".\(bundleID).invalidated-stale-orphan")
        try fm.createDirectory(at: orphanInvalidated, withIntermediateDirectories: true)
        // Simulate obstruction at targetBackupDir causing restoreQuarantinedAppBackups to return false
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("obstructing-partial".utf8).write(to: targetBackupDir.appendingPathComponent("partial"))
        XCTAssertFalse(
            Installer.restoreQuarantinedAppBackups(quarantined, to: targetBackupDir, bundleIdentifier: bundleID)
        )
        Installer.cleanupInvalidatedAppBackups(
            primary: nil,
            in: backupsRoot,
            bundleIdentifier: bundleID,
            excluding: [quarantined]
        )
        XCTAssertFalse(fm.fileExists(atPath: orphanInvalidated.path))
        XCTAssertTrue(fm.fileExists(atPath: quarantined.path))
        XCTAssertEqual(
            try String(contentsOf: quarantined.appendingPathComponent("executable"), encoding: .utf8),
            "v1-backup-exec"
        )
    }

    func testAppBackupsDistinguishesENOENTFromLstatQueryErrors() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.lstatquery"
        let backupsRoot = dir.appendingPathComponent("AppBackupsQuery", isDirectory: true)
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)

        let appDir = dir.appendingPathComponent("QuerySample.app", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        let infoURL = appDir.appendingPathComponent("Info.plist")
        let infoDict: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            Installer.installGenerationInfoKey: "GEN-QUERY-1"
        ]
        try PropertyListSerialization.data(fromPropertyList: infoDict, format: .xml, options: 0)
            .write(to: infoURL)
        let appInfo = AppInfo(contentsOf: infoURL)

        // Genuinely absent path (ENOENT) must be treated as absent/clean across invalidation, quarantine, and launch.
        XCTAssertTrue(Installer.invalidateAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
        XCTAssertNil(try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
        XCTAssertNoThrow(try Installer.validateOrInvalidateAppBackupsForLaunch(at: targetBackupDir, for: appInfo))

        // Create backup with mismatched manifest and verify launch validation evicts it when accessible.
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("stale-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))
        try Installer.validateOrInvalidateAppBackupsForLaunch(at: targetBackupDir, for: appInfo)
        XCTAssertFalse(fm.fileExists(atPath: targetBackupDir.path))

        // Re-create backup, remove search/read permissions on parent directory (0o000 -> EACCES on lstat),
        // and verify query failures return false / throw rather than silently succeeding.
        if Darwin.geteuid() != 0 {
            try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
            try Data("protected-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))
            XCTAssertEqual(Darwin.chmod(backupsRoot.path, mode_t(0o000)), 0)
            defer { _ = Darwin.chmod(backupsRoot.path, mode_t(0o755)) }

            XCTAssertFalse(Installer.invalidateAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
            XCTAssertThrowsError(try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
            XCTAssertThrowsError(
                try Installer.commitAppBackups(
                    .noneApplicable,
                    to: targetBackupDir,
                    bundleIdentifier: bundleID,
                    manifest: nil
                )
            )
            XCTAssertThrowsError(
                try Installer.validateOrInvalidateAppBackupsForLaunch(at: targetBackupDir, for: appInfo)
            )

            XCTAssertEqual(Darwin.chmod(backupsRoot.path, mode_t(0o755)), 0)
            XCTAssertEqual(
                try String(contentsOf: targetBackupDir.appendingPathComponent("executable"), encoding: .utf8),
                "protected-exec"
            )
        }
    }

    func testAfterSwapPreservesQuarantinedBackupsOnStagingOrValidationFailure() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default
        let bundleID = "com.example.degradedbackups"
        let appsDir = dir.appendingPathComponent("ApplicationsDegraded", isDirectory: true)
        let backupsRoot = dir.appendingPathComponent("AppBackupsDegraded", isDirectory: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)

        let existingAppURL = appsDir.appendingPathComponent("\(bundleID).app", isDirectory: true)
        try fm.createDirectory(at: existingAppURL, withIntermediateDirectories: true)
        let v1Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: v1Info, format: .xml, options: 0)
            .write(to: existingAppURL.appendingPathComponent("Info.plist"))
        try Data("v1-live".utf8).write(to: existingAppURL.appendingPathComponent("Sample"))
        try Data("v1-precious-backup".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))

        // 1. Upgrade v2 with backup staging .failed: new .app install succeeds (not rolled back),
        //    active targetBackupDir stays absent, and quarantined v1 backup is preserved (not deleted).
        let candidateV2URL = dir.appendingPathComponent("CandidateDegradedV2.app", isDirectory: true)
        try fm.createDirectory(at: candidateV2URL, withIntermediateDirectories: true)
        let v2Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "2",
            Installer.installGenerationInfoKey: "GEN-V2"
        ]
        try PropertyListSerialization.data(fromPropertyList: v2Info, format: .xml, options: 0)
            .write(to: candidateV2URL.appendingPathComponent("Info.plist"))
        try Data("v2-live".utf8).write(to: candidateV2URL.appendingPathComponent("Sample"))

        var quarantinedV1Dir: URL?
        var v2CommitOutcome: Installer.AppBackupCommitOutcome?
        let publishedV2URL = try Installer.publishSignedBundle(
            BaseApp(appUrl: candidateV2URL),
            into: appsDir,
            prepareAndVerify: { _, _ in },
            beforeSwap: {
                quarantinedV1Dir = try Installer.quarantineAppBackups(
                    at: targetBackupDir,
                    bundleIdentifier: bundleID
                )
            },
            afterSwap: { publishedURL in
                let installedInfo = AppInfo(contentsOf: publishedURL.appendingPathComponent("Info.plist"))
                v2CommitOutcome = try Installer.finalizeAppBackupsAfterSwap(
                    .failed,
                    to: targetBackupDir,
                    bundleIdentifier: bundleID,
                    manifest: Installer.AppBackupManifest(appInfo: installedInfo),
                    quarantinedDir: quarantinedV1Dir
                )
            }
        )
        let preservedQuarantinedURL = try XCTUnwrap(quarantinedV1Dir)
        XCTAssertEqual(publishedV2URL.standardizedFileURL, existingAppURL.standardizedFileURL)
        XCTAssertEqual(v2CommitOutcome, .degradedWithoutBackups)
        XCTAssertEqual(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8),
            "v2-live"
        )
        XCTAssertFalse(fm.fileExists(atPath: targetBackupDir.path))
        XCTAssertTrue(fm.fileExists(atPath: preservedQuarantinedURL.path))
        XCTAssertEqual(
            try String(contentsOf: preservedQuarantinedURL.appendingPathComponent("executable"), encoding: .utf8),
            "v1-precious-backup"
        )

        // 2. Subsequent upgrade v3 with .staged validation failure (nil manifest) must also succeed
        //    without rolling back v3 and without wiping previously preserved .invalidated-* backups.
        let candidateV3URL = dir.appendingPathComponent("CandidateDegradedV3.app", isDirectory: true)
        try fm.createDirectory(at: candidateV3URL, withIntermediateDirectories: true)
        let v3Info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "3.0",
            "CFBundleVersion": "3"
        ]
        try PropertyListSerialization.data(fromPropertyList: v3Info, format: .xml, options: 0)
            .write(to: candidateV3URL.appendingPathComponent("Info.plist"))
        try Data("v3-live".utf8).write(to: candidateV3URL.appendingPathComponent("Sample"))
        let invalidStagedV3 = dir.appendingPathComponent("staging-v3-unbound", isDirectory: true)
        try fm.createDirectory(at: invalidStagedV3, withIntermediateDirectories: true)
        try Data("v3-exec".utf8).write(to: invalidStagedV3.appendingPathComponent("executable"))

        var v3CommitOutcome: Installer.AppBackupCommitOutcome?
        _ = try Installer.publishSignedBundle(
            BaseApp(appUrl: candidateV3URL),
            into: appsDir,
            prepareAndVerify: { _, _ in },
            beforeSwap: {
                XCTAssertNil(try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
            },
            afterSwap: { _ in
                v3CommitOutcome = try Installer.finalizeAppBackupsAfterSwap(
                    .staged(invalidStagedV3),
                    to: targetBackupDir,
                    bundleIdentifier: bundleID,
                    manifest: nil,
                    quarantinedDir: nil
                )
            }
        )
        XCTAssertEqual(v3CommitOutcome, .degradedWithoutBackups)
        XCTAssertEqual(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8),
            "v3-live"
        )
        XCTAssertFalse(fm.fileExists(atPath: invalidStagedV3.path))
        XCTAssertTrue(fm.fileExists(atPath: preservedQuarantinedURL.path))

        // 3. .noneApplicable (new app genuinely needs no backups) still cleans up invalidated backups.
        let noneOutcome = try Installer.finalizeAppBackupsAfterSwap(
            .noneApplicable,
            to: targetBackupDir,
            bundleIdentifier: bundleID,
            manifest: nil,
            quarantinedDir: preservedQuarantinedURL
        )
        XCTAssertEqual(noneOutcome, .noneApplicable)
        XCTAssertFalse(fm.fileExists(atPath: preservedQuarantinedURL.path))
    }

    func testAppBackupsRejectsPathTraversalSymlinkStagingAndPreservesUnreadableRollbackFiles() throws {
        let dir = try XCTUnwrap(tempDir)
        let fm = FileManager.default

        // 1. Path-traversal and malformed bundle identifiers must never touch sibling directories.
        let backupsRoot = dir.appendingPathComponent("AppBackupsTraversal", isDirectory: true)
        let victimDir = backupsRoot.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victimDir, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: victimDir.appendingPathComponent("keep.txt"))

        let maliciousIDs = ["../victim", "nested/id", "..", ".", ".hidden", ""]
        for badID in maliciousIDs {
            XCTAssertFalse(Installer.isSafeBundleIdentifierForStorage(badID))
            let escapedTarget = backupsRoot.appendingPathComponent("sub", isDirectory: true)
                .appendingPathComponent(badID, isDirectory: true)
            XCTAssertFalse(Installer.invalidateAppBackups(at: escapedTarget, bundleIdentifier: badID))
            XCTAssertThrowsError(try Installer.quarantineAppBackups(at: victimDir, bundleIdentifier: badID))
            XCTAssertThrowsError(
                try Installer.commitAppBackups(
                    .noneApplicable,
                    to: victimDir,
                    bundleIdentifier: badID,
                    manifest: nil
                )
            )
            Installer.cleanupInvalidatedAppBackups(
                primary: victimDir,
                in: backupsRoot,
                bundleIdentifier: badID
            )
        }
        XCTAssertTrue(fm.fileExists(atPath: victimDir.appendingPathComponent("keep.txt").path))

        // 2. stageAppBackups must refuse symlinked Info.plist, embedded.mobileprovision, and executable.
        let secretURL = dir.appendingPathComponent("secret-outside.txt")
        try Data("SECRET_HOST_DATA".utf8).write(to: secretURL)
        let symAppDir = dir.appendingPathComponent("SymlinkLeak.app", isDirectory: true)
        try fm.createDirectory(at: symAppDir, withIntermediateDirectories: true)
        let symInfoURL = symAppDir.appendingPathComponent("Info.plist")
        let plistDict: [String: Any] = [
            "CFBundleIdentifier": "com.example.symlinktest",
            "CFBundleExecutable": "SymExec",
            "CFBundleShortVersionString": "1.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: symInfoURL)
        let symProvURL = symAppDir.appendingPathComponent("embedded.mobileprovision")
        let symExecURL = symAppDir.appendingPathComponent("SymExec")
        try fm.createSymbolicLink(at: symProvURL, withDestinationURL: secretURL)
        try fm.createSymbolicLink(at: symExecURL, withDestinationURL: secretURL)

        let symStagingDir = dir.appendingPathComponent("StagingSymlinkPartial", isDirectory: true)
        let partialStage = Installer.stageAppBackups(for: BaseApp(appUrl: symAppDir), in: symStagingDir)
        guard case .staged(let stagedURL) = partialStage else {
            return XCTFail("Expected Info.plist alone to still stage safely")
        }
        XCTAssertTrue(fm.fileExists(atPath: stagedURL.appendingPathComponent("Info.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: stagedURL.appendingPathComponent("embedded.mobileprovision").path))
        XCTAssertFalse(fm.fileExists(atPath: stagedURL.appendingPathComponent("executable").path))

        // Replace Info.plist with a symlink too -> nothing regular remains -> .noneApplicable.
        try fm.removeItem(at: symInfoURL)
        try fm.createSymbolicLink(at: symInfoURL, withDestinationURL: secretURL)
        let noneStage = Installer.stageAppBackups(
            for: BaseApp(appUrl: symAppDir),
            in: dir.appendingPathComponent("StagingSymlinkNone", isDirectory: true)
        )
        guard case .noneApplicable = noneStage else {
            return XCTFail("Expected all-symlink bundle artifacts to yield .noneApplicable")
        }

        // 3. Rollback restoration helper must delete newly created files, restore readable originals,
        //    and NEVER delete pre-existing unreadable files.
        let freshFile = dir.appendingPathComponent("fresh-settings.plist")
        try Data("new".utf8).write(to: freshFile)
        Installer.restoreRollbackFile(at: freshFile, existedBefore: false, previousData: nil, label: "settings")
        XCTAssertFalse(fm.fileExists(atPath: freshFile.path))

        let existingFile = dir.appendingPathComponent("existing-settings.plist")
        try Data("updated".utf8).write(to: existingFile)
        Installer.restoreRollbackFile(
            at: existingFile,
            existedBefore: true,
            previousData: Data("original".utf8),
            label: "settings"
        )
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "original")

        let unreadableFile = dir.appendingPathComponent("unreadable-entitlements.plist")
        try Data("locked".utf8).write(to: unreadableFile)
        Installer.restoreRollbackFile(
            at: unreadableFile,
            existedBefore: true,
            previousData: nil,
            label: "entitlements"
        )
        XCTAssertTrue(fm.fileExists(atPath: unreadableFile.path))
    }

    func testAppsVMInvalidatesCachedPlayAppWhenOnDiskInfoChanges() throws {
        let dir = try XCTUnwrap(tempDir)
        let appURL = dir.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)

        let plistURL = appURL.appendingPathComponent("Info.plist")
        var plistDict: [String: Any] = [
            "CFBundleIdentifier": "com.example.overwrite",
            "CFBundleName": "Sample",
            "CFBundleDisplayName": "Sample",
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "100",
            Installer.installGenerationInfoKey: "gen-1"
        ]
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)

        let existing = PlayApp(appUrl: appURL)
        XCTAssertTrue(AppsVM.shouldReuseExistingApp(existing, at: appURL))

        // Overwrite-reinstall with a new PCInstallGeneration must invalidate cached PlayApp.
        plistDict[Installer.installGenerationInfoKey] = "gen-2"
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        XCTAssertFalse(AppsVM.shouldReuseExistingApp(existing, at: appURL))

        // Reset generation, then bump CFBundleVersion / CFBundleShortVersionString -> also invalidates.
        plistDict[Installer.installGenerationInfoKey] = "gen-1"
        plistDict["CFBundleVersion"] = "101"
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        XCTAssertFalse(AppsVM.shouldReuseExistingApp(existing, at: appURL))

        plistDict["CFBundleVersion"] = "100"
        plistDict["CFBundleShortVersionString"] = "1.0.1"
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        XCTAssertFalse(AppsVM.shouldReuseExistingApp(existing, at: appURL))
    }

    func testUninstallerResolvesSVCPatchesBundleIdentifier() {
        XCTAssertEqual(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.game.json"),
                in: "SVCPatches"
            ),
            "com.example.game"
        )
        XCTAssertEqual(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.json.json"),
                in: "SVCPatches"
            ),
            "com.example.json"
        )
        XCTAssertEqual(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.game"),
                in: "SVCPatches"
            ),
            "com.example.game"
        )
    }
}
