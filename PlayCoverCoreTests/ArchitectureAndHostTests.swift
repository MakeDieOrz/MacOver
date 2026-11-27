import Darwin
import Foundation
import Observation
import PlayCoverCore
import Synchronization
import Testing
@testable import PlayCover

private final class TempDirBox: Sendable {
    let url: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverArchitectureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

extension PlayCoverGlobalHostScope {
@Suite(.serialized)
struct ArchitectureAndHostTests {
    private let tempDirBox: TempDirBox
    private var tempDir: URL { tempDirBox.url }

    init() throws {
        tempDirBox = try TempDirBox()
    }

    @Test
    func playCoverErrorStructuredCasesAndDescriptions() {
        let shellErr = PlayCoverError.shellExecutionFailed(
            binary: "/usr/bin/codesign",
            status: 1,
            output: "invalid signature"
        )
        #expect(shellErr.errorDescription == "invalid signature")

        let emptyShellErr = PlayCoverError.shellExecutionFailed(
            binary: "/usr/bin/true",
            status: 2,
            output: ""
        )
        #expect(emptyShellErr.errorDescription == "Shell command failed")

        #expect(PlayCoverError.playToolsError("missing binary").errorDescription == "missing binary")
        #expect(PlayCoverError.entitlementsError("bad yaml").errorDescription == "bad yaml")
        #expect(PlayCoverError.privilegeEscalationFailed("sip active").errorDescription == "sip active")
        #expect(PlayCoverError.appleScriptFailed("canceled").errorDescription == "canceled")
    }

    @Test
    func appSettingsDebouncesRapidUpdatesAndFlushesImmediately() async throws {
        let infoURL = tempDir.appendingPathComponent("Info.plist")
        let plistDict: NSDictionary = [
            "CFBundleIdentifier": "app.makedie.test.architecture",
            "CFBundleName": "ArchitectureTest",
            "CFBundleExecutable": "ArchitectureTest"
        ]
        #expect(plistDict.write(to: infoURL, atomically: true))

        let info = AppInfo(contentsOf: infoURL)
        let settingsURL = tempDir.appendingPathComponent("app.makedie.test.architecture.plist")
        let appSettings = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.25)

        // Rapid mutations (like dragging a slider) must not synchronously write on every update
        let initialModDate = (try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.modificationDate]) as? Date
        for idx in 1...20 {
            appSettings.update { $0.sensitivity = Float(idx) }
        }
        #expect(appSettings.settings.sensitivity == 20)

        // Explicit flush persists immediately
        #expect(appSettings.flush())
        let reloaded = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.25)
        #expect(reloaded.settings.sensitivity == 20)
        #expect(initialModDate != nil)

        // Debounce timer persists automatically after debounceInterval elapses
        appSettings.update { $0.windowWidth = 2560 }
        try await Task.sleep(for: .milliseconds(500))

        let reloadedAfterDebounce = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.25)
        #expect(reloadedAfterDebounce.settings.windowWidth == 2560)
    }

    @Test
    @MainActor
    func toastVMDismissesByUUIDOutOfOrder() {
        let vm = ToastVM()
        let first = vm.showToast(toastType: .notice, toastDetails: "First", timeRemaining: 5)
        let second = vm.showToast(toastType: .error, toastDetails: "Second", timeRemaining: 5)
        let third = vm.showToast(toastType: .network, toastDetails: "Third", timeRemaining: 5)
        #expect(vm.toasts.map(\.id) == [first, second, third])

        // Dismiss middle toast by UUID (old removeFirst() would wrongly drop "First")
        vm.dismiss(id: second)
        #expect(vm.toasts.map(\.id) == [first, third])

        // Dismissing an already-removed or unknown UUID is safe
        vm.dismiss(id: second)
        vm.dismiss(id: UUID())
        #expect(vm.toasts.map(\.id) == [first, third])
    }

    @Test
    @MainActor
    func progressVMTransitionsWithoutPollingLoop() async throws {
        enum SampleStep: String {
            case start, working, done, failed
        }

        let vm = ProgressVM<SampleStep>(start: .start, ends: [.done, .failed])
        #expect(!vm.inProgress)

        vm.next(.start, 0.0, 0.1)
        #expect(vm.inProgress)
        #expect(vm.status == .start)

        vm.next(.working, 0.2, 0.8)
        #expect(vm.status == .working)
        #expect(abs(vm.progress - 0.2) <= 0.0001)

        // Event-driven progress update without polling
        vm.updateProgress(0.65)
        #expect(abs(vm.progress - 0.65) <= 0.0001)
        vm.updateProgress(1.5)
        #expect(abs(vm.progress - 1.0) <= 0.0001)

        // Transitioning to end step marks 1.0 immediately
        vm.next(.done, 0.9, 1.0)
        #expect(vm.status == .done)
        #expect(abs(vm.progress - 1.0) <= 0.0001)

        // Wait past 1.5s dismissal window
        try await Task.sleep(nanoseconds: 1_700_000_000)
        #expect(!vm.inProgress)
    }

    @Test
    @MainActor
    func preferencesStoresUseUserDefaultsAndEmitObservationChanges() throws {
        let suiteName = "app.makedie.ArchitecturePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName), "Failed to allocate isolated UserDefaults suite")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let keyCoverPrefs = KeyCoverPreferences(userDefaults: defaults)
        let installPrefs = InstallPreferences(userDefaults: defaults)
        let uninstallPrefs = UninstallPreferences(userDefaults: defaults)

        let changes = Mutex(0)
        func observe(_ read: () -> Void, mutate: () -> Void) {
            withObservationTracking {
                read()
            } onChange: {
                changes.withLock { $0 += 1 }
            }
            mutate()
        }

        observe({ _ = keyCoverPrefs.keyCoverEnabled }, mutate: {
            keyCoverPrefs.keyCoverEnabled = .userProvidedPassword
        })
        observe({ _ = keyCoverPrefs.promptForKeyCoverPasswordAtLaunch }, mutate: {
            keyCoverPrefs.promptForKeyCoverPasswordAtLaunch = false
        })
        observe({ _ = installPrefs.alwaysInstallPlayTools }, mutate: {
            installPrefs.alwaysInstallPlayTools = false
        })
        observe({ _ = installPrefs.defaultAppType }, mutate: {
            installPrefs.defaultAppType = .games
        })
        observe({ _ = uninstallPrefs.clearAppData }, mutate: {
            uninstallPrefs.clearAppData = true
        })
        observe({ _ = uninstallPrefs.showUninstallPopup }, mutate: {
            uninstallPrefs.showUninstallPopup = false
        })

        #expect(changes.withLock { $0 } == 6)

        let reloadedKeyCover = KeyCoverPreferences(userDefaults: defaults)
        let reloadedInstall = InstallPreferences(userDefaults: defaults)
        let reloadedUninstall = UninstallPreferences(userDefaults: defaults)

        #expect(reloadedKeyCover.keyCoverEnabled == .userProvidedPassword)
        #expect(!reloadedKeyCover.promptForKeyCoverPasswordAtLaunch)
        #expect(!reloadedInstall.alwaysInstallPlayTools)
        #expect(reloadedInstall.defaultAppType == .games)
        #expect(reloadedUninstall.clearAppData)
        #expect(!reloadedUninstall.showUninstallPopup)
    }

    @Test
    @MainActor
    func modifierKeyObserverAvoidsDuplicateObservationEmissions() {
        let observer = ModifierKeyObserver()
        let optionChanges = Mutex(0)
        let commandChanges = Mutex(0)

        withObservationTracking {
            _ = observer.isOptionKeyPressed
        } onChange: {
            optionChanges.withLock { $0 += 1 }
        }
        withObservationTracking {
            _ = observer.isCommandKeyPressed
        } onChange: {
            commandChanges.withLock { $0 += 1 }
        }

        observer.applyModifierFlags([.option, .command])
        #expect(optionChanges.withLock { $0 } == 1)
        #expect(commandChanges.withLock { $0 } == 1)
        #expect(observer.isOptionKeyPressed)
        #expect(observer.isCommandKeyPressed)

        // Applying identical modifier flags must trigger zero redundant observations
        let duplicateEmissions = Mutex(0)
        withObservationTracking {
            _ = observer.isOptionKeyPressed
            _ = observer.isCommandKeyPressed
        } onChange: {
            duplicateEmissions.withLock { $0 += 1 }
        }
        observer.applyModifierFlags([.option, .command])
        #expect(duplicateEmissions.withLock { $0 } == 0)
    }

    @Test
    func googleDriveLinkConversionAndFormExtraction() {
        let converted = RedirectHandler.convertGoogleDriveLink("https://drive.google.com/file/d/1AbCdEfGhIjK/view?usp=sharing")
        #expect(
            converted?.absoluteString ==
                "https://drive.usercontent.google.com/download?id=1AbCdEfGhIjK&export=download&authuser=0"
        )
        #expect(RedirectHandler.convertGoogleDriveLink("https://example.com/app.ipa") == nil)

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
        #expect(
            extracted?.absoluteString ==
                "https://drive.usercontent.google.com/download?id=1AbCdEfGhIjK&confirm=t&uuid=xyz-999"
        )
        #expect(RedirectHandler.extractDownloadLink(from: "<html><body>No form</body></html>") == nil)

        let reorderedHTML = """
        <form action="https://other.invalid/submit" id="other-form"></form>
        <FORM action='https://drive.usercontent.google.com/download&amp;extra=1' id='download-form'>
          <INPUT value=abc-123 name=id type=hidden>
          <input value="confirm-val" name="confirm">
          <input name='uuid' value='u-42'>
        </FORM>
        """
        #expect(
            RedirectHandler.extractDownloadLink(from: reorderedHTML)?.absoluteString ==
                "https://drive.usercontent.google.com/download&extra=1?id=abc-123&confirm=confirm-val&uuid=u-42"
        )
    }

    @Test
    func appStoreMacOSCompatibilityHTMLParsing() {
        let macCompatibleHTML = """
        <div class="information-list__item">
          <dd class="information-list__item__definition__item__definition">
            <span>Requires macOS 11.0 or later and a Mac with Apple M1 chip or later.</span>
          </dd>
        </div>
        """
        #expect(IPA.htmlIndicatesMacOSCompatibility(macCompatibleHTML))

        let iOSOnlyHTML = """
        <div class="information-list__item">
          <dd class="information-list__item__definition__item__definition">
            <span>Requires iOS 16.0 or later.</span>
          </dd>
        </div>
        <p class="unrelated">macOS</p>
        """
        #expect(!IPA.htmlIndicatesMacOSCompatibility(iOSOnlyHTML))
    }

    @Test
    func stringCatalogCompiledLocalizationsAndLookups() throws {
        let hostBundle = Bundle(for: PlayCoverDependencies.self)
        let localizations = Set(hostBundle.localizations)
        for expected in ["en", "zh-Hans", "ja", "pt-BR", "ar", "uk"] {
            #expect(localizations.contains(expected), "Missing localization: \(expected)")
        }

        let keys = [
            "playapp.add",
            "sidebar.appLibrary",
            "ipaLibrary.noNetworkConnection.toast"
        ]
        for key in keys {
            let localized = hostBundle.localizedString(forKey: key, value: nil, table: nil)
            #expect(!localized.isEmpty)
            #expect(localized != key, "Localization lookup returned raw key for \(key)")
        }

        let zhBundleURL = try #require(hostBundle.url(forResource: "zh-Hans", withExtension: "lproj"))
        let zhBundle = try #require(Bundle(url: zhBundleURL))
        let zhAdd = zhBundle.localizedString(forKey: "playapp.add", value: nil, table: nil)
        #expect(zhAdd != "playapp.add")
        #expect(zhAdd == "添加应用")
    }

    @Test
    @MainActor
    func keyCoverUnlockPromptContinuationWakeupAndCancellation() async throws {
        let observable = KeyCoverObservable()
        observable.isKeyCoverUnlockingPromptShown = true

        let waiter = Task {
            try await observable.waitForUnlockPromptDismissal()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        observable.isKeyCoverUnlockingPromptShown = false
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

        await #expect(throws: CancellationError.self) {
            try await canceledWaiter.value
        }
        await MainActor.run {
            observable.isKeyCoverUnlockingPromptShown = false
        }
    }

    @Test
    func dualTrackPrivilegeEscalatorTrackSelectionAndEscaping() {
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ) == .xpcHelper
        )
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: false,
                hasEmbeddedHelperPlist: true
            ) == .appleScriptGUI
        )
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: false,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ) == .appleScriptGUI
        )
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: false
            ) == .appleScriptGUI
        )

        #expect(DualTrackPrivilegeEscalator.shellSingleQuoted("a'b\\c") == "'a'\"'\"'b\\c'")
        let script = DualTrackPrivilegeEscalator.buildAppleScriptPrivilegeCommand(
            binary: "/usr/sbin/nvram",
            arguments: ["boot-args=amfi_get_out_of_my_way=0x1 ipc_control_port_options=0"]
        )
        #expect(script.contains("with administrator privileges"))
        #expect(script.contains("/usr/sbin/nvram"))
        #expect(script.contains("amfi_get_out_of_my_way=0x1"))

        #expect(!DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: nil, leafCommonName: nil))
        #expect(!DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: "", leafCommonName: "Developer ID Application: Foo (ABC1234567)"))
        #expect(!DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: "ABC1234567", leafCommonName: "Apple Development: Foo (ABC1234567)"))
        #expect(DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(teamIdentifier: "ABC1234567", leafCommonName: "Developer ID Application: Foo (ABC1234567)"))
        #expect(!DualTrackPrivilegeEscalator.currentProcessHasDeveloperIDTeam())
    }

    @Test
    func helperSecurityValidatorAndEmbeddedHelperBundle() throws {
        #expect(HelperSecurityValidator.validateBundleIdentifier("app.makedie.MacOver"))
        #expect(HelperSecurityValidator.validateBundleIdentifier("com.example.app-1_2"))
        #expect(!HelperSecurityValidator.validateBundleIdentifier("nodot"))
        #expect(!HelperSecurityValidator.validateBundleIdentifier("foo; rm -rf /"))
        #expect(!HelperSecurityValidator.validateBundleIdentifier("../evil.id"))
        #expect(!HelperSecurityValidator.validateBundleIdentifier(".leading.dot"))

        #expect(
            HelperSecurityValidator.validateContainerPath("/Users/alice/Library/Containers/app.makedie.MacOver/Data") ==
                "/Users/alice/Library/Containers/app.makedie.MacOver/Data"
        )
        #expect(HelperSecurityValidator.validateContainerPath("/System/Library") == nil)
        #expect(HelperSecurityValidator.validateContainerPath("/etc/passwd") == nil)
        #expect(HelperSecurityValidator.validateContainerPath("/Users/alice/Library/Containers/../Desktop") == nil)
        #expect(HelperSecurityValidator.validateContainerPath("") == nil)

        // Hosted test host (MacOver.app) must embed Track A helper tool and launchd daemon plist.
        let hostBundle = Bundle.main
        #expect(DualTrackPrivilegeEscalator.embeddedHelperDaemonPlistExists(in: hostBundle))

        let plistURL = hostBundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(DualTrackPrivilegeEscalator.helperDaemonPlistName)
        let plistData = try Data(contentsOf: plistURL)
        let parsed = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        #expect((parsed["Label"] as? String) == DualTrackPrivilegeEscalator.helperMachServiceName)
        #expect((parsed["BundleProgram"] as? String) == "Contents/Library/HelperTools/PlayCoverHelper")
        let machServices = parsed["MachServices"] as? [String: Bool]
        #expect(machServices?[DualTrackPrivilegeEscalator.helperMachServiceName] == true)
    }

    @Test
    @MainActor
    func startupAlertCenterQueueAndDeduplication() {
        let center = StartupAlertCenter()
        center.enqueue(.lowPowerMode)
        center.enqueue(.lowPowerMode) // deduplicated
        center.enqueue(.audioSampleRate(deviceID: 42, currentSampleRate: 96000))

        #expect(center.activeAlert == .lowPowerMode)
        center.dismissCurrent()
        #expect(center.activeAlert == .audioSampleRate(deviceID: 42, currentSampleRate: 96000))
        center.dismissCurrent()
        #expect(center.activeAlert == nil)
    }

    @Test
    func syncUserPluginsCopiesDylibsSidecarManifestsAndBundleSubdirs() throws {
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

        #expect(!fm.fileExists(atPath: targetDir.appendingPathComponent("Stale.dylib").path))
        #expect(fm.fileExists(atPath: targetDir.appendingPathComponent("Alpha.dylib").path))
        #expect(fm.fileExists(atPath: targetDir.appendingPathComponent("Alpha.manifest.json").path))
        #expect(!fm.fileExists(atPath: targetDir.appendingPathComponent("notes.json").path))
        #expect(!fm.fileExists(atPath: targetDir.appendingPathComponent("NoManifest").path))
        #expect(fm.fileExists(atPath: targetDir.appendingPathComponent("BetaBundle/PluginManifest.json").path))
        #expect(fm.fileExists(atPath: targetDir.appendingPathComponent("BetaBundle/libBeta.dylib").path))
        #expect(Set(signedFilenames) == ["Alpha.dylib", "libBeta.dylib"])

        // Empty store must remove existing targetDir cleanly without recreating it.
        let emptyStore = tempRoot.appendingPathComponent("EmptyStore", isDirectory: true)
        try fm.createDirectory(at: emptyStore, withIntermediateDirectories: true)
        try PlayTools.syncUserPlugins(from: emptyStore, into: targetDir) { _ in }
        #expect(!fm.fileExists(atPath: targetDir.path))
    }

    @Test
    @MainActor
    func alertPresenterQueueAndStartupSafeModeAlert() async {
        let center = StartupAlertCenter()
        center.enqueue(.safeModeActivated(
            appName: "MockApp",
            bundleID: "com.example.mock",
            breadcrumbPath: "/tmp/nonexistent/.launching_in_progress"
        ))
        #expect(
            center.activeAlert ==
                .safeModeActivated(
                    appName: "MockApp",
                    bundleID: "com.example.mock",
                    breadcrumbPath: "/tmp/nonexistent/.launching_in_progress"
                )
        )
        center.dismissCurrent()
        #expect(center.activeAlert == nil)

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
        #expect(first == PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true))
        #expect(recordedTitles == ["First"])

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
        #expect(autoResolved == PlayCoverAlertResponse(buttonIndex: 1, suppressionChecked: false))
    }

    @Test
    func appSettingsDataCompatibilityAndRestartDiff() throws {
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
        #expect(legacy.frameRateTarget == "adaptive")
        #expect(legacy.reportedIOSVersion == "automatic")
        #expect(legacy.frameRateTargetMode == .adaptive)
        #expect(legacy.reportedIOSVersionMode == .automatic)
        let gib: UInt64 = 1_073_741_824
        #expect(legacy.effectivePixelBudget(physicalMemoryBytes: 8 * gib).level == .over)
        #expect(legacy.effectivePixelBudget(physicalMemoryBytes: 16 * gib).level == .over)
        #expect(legacy.effectivePixelBudget(physicalMemoryBytes: 24 * gib).level == .caution)
        #expect(legacy.effectivePixelBudget(physicalMemoryBytes: 32 * gib).level == .ok)
        #expect(
            legacy.pixelBudget == legacy.effectivePixelBudget(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        )

        var configured = legacy
        configured.frameRateTarget = "fixed60"
        configured.reportedIOSVersion = "compat18_3"
        let encoded = try PropertyListEncoder().encode(configured)
        let roundTripped = try PropertyListDecoder().decode(AppSettingsData.self, from: encoded)
        #expect(roundTripped.frameRateTargetMode == .fixed60)
        #expect(roundTripped.reportedIOSVersionMode == .compat18_3)

        configured.reportedIOSVersion = "compat13_7"
        let compat13Encoded = try PropertyListEncoder().encode(configured)
        let compat13Decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: compat13Encoded)
        #expect(compat13Decoded.reportedIOSVersionMode == .compat13_7)
        #expect(compat13Decoded.reportedIOSVersion == "compat13_7")

        var invalidNormalized = configured
        invalidNormalized.frameRateTarget = "bogus"
        invalidNormalized.reportedIOSVersion = "bogus"
        let redecoded = try PropertyListDecoder().decode(
            AppSettingsData.self,
            from: try PropertyListEncoder().encode(invalidNormalized)
        )
        #expect(redecoded.frameRateTarget == "adaptive")
        #expect(redecoded.reportedIOSVersion == "automatic")

        var compat = legacy
        compat.windowCompatibility = .invertedMetrics
        #expect(compat.inverseScreenValues)
        #expect(compat.windowFixMethod == 0)
        #expect(compat.resolution == 6)

        compat.windowCompatibility = .standard
        #expect(!compat.inverseScreenValues)
        #expect(compat.windowFixMethod == 0)
        #expect(compat.resolution == 6)

        compat.windowCompatibility = .invertedLegacyResize
        #expect(compat.inverseScreenValues)
        #expect(compat.windowFixMethod == 1)
        #expect(compat.resolution == 0)

        #expect(legacy.restartRequiredChanges(comparedTo: legacy) == [])
        var updated = legacy
        updated.windowWidth = 2560
        updated.windowCompatibility = .invertedMetrics
        updated.frameRateTargetMode = .fixed30
        updated.reportedIOSVersionMode = .compat18_3
        #expect(
            updated.restartRequiredChanges(comparedTo: legacy) ==
                [.windowSize, .windowCompatibility, .frameRateTarget, .reportedIOSVersion]
        )

        var strictUpdated = legacy
        strictUpdated.strictEmulationMode = true
        strictUpdated.strictViewportOrientation = .portrait
        strictUpdated.strictViewportScaleMode = .native1x
        let strictDiff = strictUpdated.restartRequiredChanges(comparedTo: legacy)
        #expect(strictDiff.contains(.strictEmulationMode))
        #expect(strictDiff.contains(.strictViewportOrientation))
        #expect(strictDiff.contains(.strictViewportScaleMode))
        #expect(strictDiff.contains(.interceptInlineSyscalls))
    }

    @Test
    @MainActor
    func appSettingsObservableAndPresetsAndDeviceOptions() throws {
        let infoURL = tempDir.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.configtest",
            "CFBundleExecutable": "Sample",
            "CFBundleShortVersionString": "1.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: infoURL)
        let info = AppInfo(contentsOf: infoURL)
        let settingsURL = tempDir.appendingPathComponent("settings.plist")
        let appSettings = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.2)

        let notifications = Mutex(0)
        let token = appSettings.addChangeObserver {
            notifications.withLock { $0 += 1 }
        }
        defer { appSettings.removeChangeObserver(token) }

        let trackedSettingsChanges = Mutex(0)
        withObservationTracking {
            _ = appSettings.settings
        } onChange: {
            trackedSettingsChanges.withLock { $0 += 1 }
        }

        appSettings.settings.customScaler = 1.5
        appSettings.update { $0.frameRateTargetMode = .fixed60 }
        appSettings.openWithLLDB = true
        appSettings.reset()
        #expect(notifications.withLock { $0 } >= 4)
        #expect(trackedSettingsChanges.withLock { $0 } == 1)

        for preset in PlayAppSettingsPreset.allCases {
            var candidate = AppSettingsData()
            preset.apply(to: &candidate)
            #expect(preset.matches(candidate))
        }

        let dims1080 = AppSettingsData.computedDimensions(
            resolution: 2, aspectRatio: 1, customWidth: 0, customHeight: 0
        )
        #expect(dims1080.width == 1920)
        #expect(dims1080.height == 1080)

        let dimsCustom = AppSettingsData.computedDimensions(
            resolution: 5, aspectRatio: 0, customWidth: 1600, customHeight: 900
        )
        #expect(dimsCustom.width == 1600)
        #expect(dimsCustom.height == 900)

        var countData = AppSettingsData()
        #expect(
            countData.activeTroubleshootingCount(hasIntrospection: false, hasIosFrameworks: false, openWithLLDB: false) ==
                0
        )
        countData.metalHUD = true
        countData.rootWorkDir = false
        countData.blockSleepSpamming = true
        #expect(
            countData.activeTroubleshootingCount(hasIntrospection: true, hasIosFrameworks: false, openWithLLDB: true) == 5
        )

        #expect(DeviceProfileOption.isLegacyModel("iPad6,7"))
        #expect(DeviceProfileOption.isLegacyModel("iPad8,6"))
        #expect(DeviceProfileOption.isLegacyModel("iPhone12,5"))
        #expect(!DeviceProfileOption.isLegacyModel("iPad17,3"))
        #expect(DeviceProfileOption.supportsIOS13("iPad8,6"))
        #expect(DeviceProfileOption.supportsIOS13("iPhone12,5"))
        #expect(!DeviceProfileOption.supportsIOS13("iPad13,8"))
        #expect(!DeviceProfileOption.supportsIOS13("iPhone17,2"))
        #expect(DeviceProfileOption.recommendedIOS13Model(isIPhone: false) == "iPad8,6")
        #expect(DeviceProfileOption.recommendedIOS13Model(isIPhone: true) == "iPhone12,5")
        #expect(DeviceProfileOption.isIPhone("iPhone18,2"))
        #expect(!DeviceProfileOption.isIPhone("iPad17,3"))

        appSettings.update {
            $0.iosDeviceModel = "iPad13,8"
            $0.reportedIOSVersionMode = .compat13_7
        }
        appSettings.sync()
        #expect(appSettings.flush())
        #expect(appSettings.settings.iosDeviceModel == "iPad13,8")
        #expect(appSettings.settings.effectiveIOSDeviceModel == "iPad8,6")
        let reloadedPad = AppSettings(settingsUrl: settingsURL, info: info, debounceInterval: 0.2)
        #expect(reloadedPad.settings.iosDeviceModel == "iPad13,8")
        #expect(reloadedPad.settings.effectiveIOSDeviceModel == "iPad8,6")
        appSettings.update { $0.reportedIOSVersionMode = .automatic }
        #expect(appSettings.settings.iosDeviceModel == "iPad13,8")
        #expect(appSettings.settings.effectiveIOSDeviceModel == "iPad13,8")

        appSettings.update {
            $0.iosDeviceModel = "iPhone18,2"
            $0.reportedIOSVersionMode = .compat13_7
        }
        appSettings.sync()
        #expect(appSettings.flush())
        #expect(appSettings.settings.iosDeviceModel == "iPhone18,2")
        #expect(appSettings.settings.effectiveIOSDeviceModel == "iPhone12,5")
        appSettings.update { $0.reportedIOSVersionMode = .compat18_3 }
        #expect(appSettings.settings.iosDeviceModel == "iPhone18,2")
        #expect(appSettings.settings.effectiveIOSDeviceModel == "iPhone18,2")

        appSettings.update {
            $0.resolution = 1
            $0.windowWidth = 1234
            $0.windowHeight = 567
            $0.strictEmulationMode = true
        }
        appSettings.sync()
        #expect(appSettings.settings.windowWidth == 1234)
        #expect(appSettings.settings.windowHeight == 567)

        let defaultRules = try Entitlements.getDefaultRules()
        #expect(defaultRules.blocklist?.contains("/System/Library/CoreServices/Finder.app") ?? false)

        let sandboxAppDir = tempDir.appendingPathComponent("StrictSandboxProbe.app", isDirectory: true)
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
        #expect(!nonStrictSBPL.contains("/System/Library/CoreServices/Finder.app"))

        probeApp.settings.update {
            $0.bypass = false
            $0.strictEmulationMode = true
        }
        let strictEnts = try Entitlements.composeEntitlements(probeApp)
        let strictSBPL = (strictEnts["com.apple.security.temporary-exception.sbpl"] as? [String] ?? [])
            .joined(separator: "\n")
        #expect(strictSBPL.contains("/System/Library/CoreServices/Finder.app"))
    }

    @Test
    func commitAppBackupsReplacesOrInvalidatesStaleBackups() throws {
        let fm = FileManager.default
        let bundleID = "com.example.appbackups"
        let targetDir = tempDir.appendingPathComponent("AppBackups").appendingPathComponent(bundleID)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let oldExec = targetDir.appendingPathComponent("executable")
        try Data("v1-binary".utf8).write(to: oldExec)

        // Replacing with valid staged artifacts and manifest swaps in v2 + manifest.plist
        let stagingV2 = tempDir.appendingPathComponent("staging-v2")
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
        #expect(try String(contentsOf: oldExec, encoding: .utf8) == "v2-binary")
        let manifestURL = targetDir.appendingPathComponent(Installer.backupManifestFileName)
        #expect(fm.fileExists(atPath: manifestURL.path))

        // Upgrade with no applicable backup artifacts (e.g. Fat binary without mobileprovision)
        // must remove stale v2 backup so runtime does not serve old binary to v3 app.
        try Installer.commitAppBackups(
            .noneApplicable,
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: nil
        )
        #expect(!fm.fileExists(atPath: targetDir.path))

        // Failed or empty staging after app bundle wrap must also invalidate stale backup.
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data("v3-binary".utf8).write(to: oldExec)
        try Installer.commitAppBackups(
            .failed,
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: manifestV2
        )
        #expect(!fm.fileExists(atPath: targetDir.path))
    }

    @Test
    func appBackupManifestBindsGenerationAndBundleVersion() throws {
        let fm = FileManager.default
        let bundleID = "com.example.manifestbind"
        let targetDir = tempDir.appendingPathComponent("AppBackups").appendingPathComponent(bundleID)
        let appDir = tempDir.appendingPathComponent("Sample.app", isDirectory: true)
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
        let stagingClean = tempDir.appendingPathComponent("staging-clean-info")
        let baseSampleApp = BaseApp(appUrl: appDir)
        if case .staged(let stagedURL) = Installer.stageAppBackups(for: baseSampleApp, in: stagingClean) {
            let stagedInfoData = try Data(contentsOf: stagedURL.appendingPathComponent("Info.plist"))
            let stagedParsed = try #require(
                PropertyListSerialization.propertyList(from: stagedInfoData, format: nil) as? [String: Any]
            )
            #expect(stagedParsed[Installer.installGenerationInfoKey] == nil)
            #expect((stagedParsed["MinimumOSVersion"] as? String) == "16.4")
        } else {
            Issue.record("Expected stageAppBackups to stage clean Info.plist")
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

        let stagingV1 = tempDir.appendingPathComponent("staging-v1")
        try fm.createDirectory(at: stagingV1, withIntermediateDirectories: true)
        try Data("v1-exec".utf8).write(to: stagingV1.appendingPathComponent("executable"))
        try Installer.commitAppBackups(
            .staged(stagingV1),
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: Installer.AppBackupManifest(appInfo: appInfo)
        )
        #expect(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Reinstall or crash-interrupted upgrade with a different installGeneration must reject stale backup
        appInfo[string: Installer.installGenerationInfoKey] = UUID().uuidString
        #expect(!Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Restore generation, mutate CFBundleVersion -> must reject mismatched version
        appInfo[string: Installer.installGenerationInfoKey] = v1Gen
        #expect(Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))
        appInfo[string: "CFBundleVersion"] = "46"
        #expect(!Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Legacy backup directory without manifest.plist must be rejected
        appInfo[string: "CFBundleVersion"] = "45"
        try fm.removeItem(at: targetDir.appendingPathComponent(Installer.backupManifestFileName))
        #expect(!Installer.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Committing staged artifacts without valid manifest must refuse and invalidate targetDir
        let stagingUnbound = tempDir.appendingPathComponent("staging-unbound")
        try fm.createDirectory(at: stagingUnbound, withIntermediateDirectories: true)
        try Data("unbound-exec".utf8).write(to: stagingUnbound.appendingPathComponent("executable"))
        try Installer.commitAppBackups(
            .staged(stagingUnbound),
            to: targetDir,
            bundleIdentifier: bundleID,
            manifest: nil
        )
        #expect(!fm.fileExists(atPath: targetDir.path))
    }

    @Test
    func appBackupsPreWrapQuarantineAndWrapReplacementSafety() throws {
        let fm = FileManager.default
        let bundleID = "com.example.txnsafety"
        let backupsRoot = tempDir.appendingPathComponent("AppBackups", isDirectory: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("v1-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))

        // Pre-wrap quarantine moves active AppBackups/<bundleID> out of runtime path immediately
        let quarantinedRaw = try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
        let quarantined = try #require(quarantinedRaw)
        #expect(!fm.fileExists(atPath: targetBackupDir.path))
        #expect(fm.fileExists(atPath: quarantined.path))

        // Pre-wrap failure restores quarantined backup when new .app was never published
        Installer.restoreQuarantinedAppBackups(quarantined, to: targetBackupDir, bundleIdentifier: bundleID)
        #expect(fm.fileExists(atPath: targetBackupDir.path))
        #expect(!fm.fileExists(atPath: quarantined.path))

        // Post-wrap commit cleans up quarantined directory and any orphan .invalidated-* siblings
        let quarantined2Raw = try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
        let quarantined2 = try #require(quarantined2Raw)
        let orphanInvalidated = backupsRoot.appendingPathComponent(".\(bundleID).invalidated-orphan")
        try fm.createDirectory(at: orphanInvalidated, withIntermediateDirectories: true)
        Installer.cleanupInvalidatedAppBackups(
            primary: quarantined2,
            in: backupsRoot,
            bundleIdentifier: bundleID
        )
        #expect(!fm.fileExists(atPath: quarantined2.path))
        #expect(!fm.fileExists(atPath: orphanInvalidated.path))

        // wrap(_:into:) replaces existing .app atomically and preserves existing .app if source fails
        let appsDir = tempDir.appendingPathComponent("Applications", isDirectory: true)
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
        let brokenCandidateURL = tempDir.appendingPathComponent("BrokenIncoming.app", isDirectory: true)
        try fm.createDirectory(at: brokenCandidateURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: v1Info, format: .xml, options: 0)
            .write(to: brokenCandidateURL.appendingPathComponent("Info.plist"))
        let brokenBaseApp = BaseApp(appUrl: brokenCandidateURL)
        try fm.removeItem(at: brokenCandidateURL)
        #expect(throws: (any Error).self) {
            try Installer.wrap(brokenBaseApp, into: appsDir)
        }
        #expect(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8) == "v1-live"
        )

        // Valid v2 incoming app swaps cleanly into Applications/<bundleID>.app
        let incomingV2URL = tempDir.appendingPathComponent("IncomingV2.app", isDirectory: true)
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
        #expect(wrappedURL.standardizedFileURL == existingAppURL.standardizedFileURL)
        #expect(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8) == "v2-live"
        )
        let appDirEntries = try fm.contentsOfDirectory(atPath: appsDir.path)
        #expect(appDirEntries == ["\(bundleID).app"])

        // Pre-swap sign/verify failure must keep existing v2 .app intact and clean up staging artifacts
        let failingSignCandidateURL = tempDir.appendingPathComponent("FailingSignV3.app", isDirectory: true)
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
        #expect(throws: (any Error).self) {
            try Installer.publishSignedBundle(
                failingSignApp,
                into: appsDir,
                prepareAndVerify: { stagedURL, targetLocation in
                    #expect(targetLocation.standardizedFileURL == existingAppURL.standardizedFileURL)
                    #expect(stagedURL.standardizedFileURL != existingAppURL.standardizedFileURL)
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
        }
        #expect(liveContentDuringStaging == "v2-live")
        #expect(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8) == "v2-live"
        )
        #expect(try fm.contentsOfDirectory(atPath: appsDir.path) == ["\(bundleID).app"])

        // Post-swap commit failure must atomically roll back to v2-live and leave no staging leftovers
        let failingPostSwapURL = tempDir.appendingPathComponent("FailingPostSwapV3.app", isDirectory: true)
        try fm.createDirectory(at: failingPostSwapURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: v3Info, format: .xml, options: 0)
            .write(to: failingPostSwapURL.appendingPathComponent("Info.plist"))
        try Data("v3-signed".utf8).write(to: failingPostSwapURL.appendingPathComponent("Sample"))
        let failingPostSwapApp = BaseApp(appUrl: failingPostSwapURL)

        var sawPublishedV3BeforeRollback = false
        #expect(throws: (any Error).self) {
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
        }
        #expect(sawPublishedV3BeforeRollback)
        #expect(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8) == "v2-live"
        )
        #expect(try fm.contentsOfDirectory(atPath: appsDir.path) == ["\(bundleID).app"])
    }

    @Test
    func rollbackFailureAndBackupCommitFailurePreservePreviousArtifacts() throws {
        let fm = FileManager.default
        let bundleID = "com.example.rollbackpreserve"

        // 1. Unrecoverable rollback failure must never delete the sole previous .app:
        //    (a) When target bundle is locked (UF_IMMUTABLE) while destinationDir is writable,
        //        previous .app is rescued beside location and stagingRoot is cleaned up.
        //    (b) When destinationDir itself is read-only (0o555), stagingRoot is retained intact
        //        so defer never deletes the previous .app's contents inside stagingRoot.
        let appsDir = tempDir.appendingPathComponent("ApplicationsRollback", isDirectory: true)
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

        let candidateImmutableURL = tempDir.appendingPathComponent("CandidateImmutableV2.app", isDirectory: true)
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
        #expect(throws: (any Error).self) {
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
        }
        if chflagsApplied {
            _ = Darwin.chflags(existingAppURL.path, 0)
            chflagsApplied = false
            let rescuedURL = try #require(reportedPreservedSiblingURL)
            #expect(
                rescuedURL.deletingLastPathComponent().standardizedFileURL == appsDir.standardizedFileURL
            )
            #expect(
                try String(contentsOf: rescuedURL.appendingPathComponent("Sample"), encoding: .utf8) == "v1-precious"
            )
            // Restore v1-precious back to existingAppURL for subtest (b)
            try fm.removeItem(at: existingAppURL)
            try fm.moveItem(at: rescuedURL, to: existingAppURL)
        }

        if Darwin.geteuid() != 0 {
            let candidateReadOnlyDirURL = tempDir.appendingPathComponent("CandidateReadOnlyV2.app", isDirectory: true)
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
            #expect(throws: (any Error).self) {
                try Installer.publishSignedBundle(
                    BaseApp(appUrl: candidateReadOnlyDirURL),
                    into: appsDir,
                    prepareAndVerify: { _, _ in },
                    afterSwap: { _ in
                        #expect(Darwin.chmod(appsDir.path, mode_t(0o555)) == 0)
                        lockedAppsDir = true
                        throw PlayCoverError.entitlementsError("post-swap failure with read-only parent")
                    },
                    onUnrecoverableRollbackFailure: { _, preservedURL in
                        reportedPreservedInStagingURL = preservedURL
                    }
                )
            }
            #expect(Darwin.chmod(appsDir.path, mode_t(0o755)) == 0)
            lockedAppsDir = false
            let preservedStagingBundle = try #require(reportedPreservedInStagingURL)
            #expect(
                try String(contentsOf: preservedStagingBundle.appendingPathComponent("Sample"), encoding: .utf8) ==
                    "v1-precious"
            )
        }

        // 2. commitAppBackups failure must restore previousDir -> targetDir, never delete existing backup,
        //    and always throw even when targetDir is absent (never treat missing targetDir as commit success).
        let backupsRoot = tempDir.appendingPathComponent("AppBackupsPreserve", isDirectory: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("v1-backup-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))

        let missingIncoming = backupsRoot.appendingPathComponent(".missing-incoming-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try Installer.replaceBackupDirectoryAtomically(
                incomingDir: missingIncoming,
                targetDir: targetBackupDir,
                parentDir: backupsRoot,
                bundleIdentifier: bundleID,
                allowRenameSwap: false
            )
        }
        #expect(
            try String(contentsOf: targetBackupDir.appendingPathComponent("executable"), encoding: .utf8) ==
                "v1-backup-exec"
        )

        if Darwin.geteuid() != 0 {
            let stagingV2 = tempDir.appendingPathComponent("staging-v2-fail", isDirectory: true)
            try fm.createDirectory(at: stagingV2, withIntermediateDirectories: true)
            try Data("v2-backup-exec".utf8).write(to: stagingV2.appendingPathComponent("executable"))
            let manifestV2 = Installer.AppBackupManifest(
                bundleIdentifier: bundleID,
                shortVersionString: "2.0",
                bundleVersion: "2",
                installGeneration: "GEN-V2"
            )
            #expect(Darwin.chmod(backupsRoot.path, mode_t(0o555)) == 0)
            defer { _ = Darwin.chmod(backupsRoot.path, mode_t(0o755)) }
            #expect(throws: (any Error).self) {
                try Installer.commitAppBackups(
                    .staged(stagingV2),
                    to: targetBackupDir,
                    bundleIdentifier: bundleID,
                    manifest: manifestV2
                )
            }
            // Even when targetDir does not exist (quarantined pre-swap), commit failure must throw!
            let quarantinedTargetDir = backupsRoot.appendingPathComponent("com.example.absenttarget", isDirectory: true)
            #expect(throws: (any Error).self) {
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
            }
            #expect(Darwin.chmod(backupsRoot.path, mode_t(0o755)) == 0)
            #expect(
                try String(contentsOf: targetBackupDir.appendingPathComponent("executable"), encoding: .utf8) ==
                    "v1-backup-exec"
            )
        }

        // 3. Unrestored quarantined AppBackups must NOT be deleted by cleanupInvalidatedAppBackups.
        let quarantinedRaw = try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
        let quarantined = try #require(quarantinedRaw)
        let orphanInvalidated = backupsRoot.appendingPathComponent(".\(bundleID).invalidated-stale-orphan")
        try fm.createDirectory(at: orphanInvalidated, withIntermediateDirectories: true)
        // Simulate obstruction at targetBackupDir causing restoreQuarantinedAppBackups to return false
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("obstructing-partial".utf8).write(to: targetBackupDir.appendingPathComponent("partial"))
        #expect(!Installer.restoreQuarantinedAppBackups(quarantined, to: targetBackupDir, bundleIdentifier: bundleID))
        Installer.cleanupInvalidatedAppBackups(
            primary: nil,
            in: backupsRoot,
            bundleIdentifier: bundleID,
            excluding: [quarantined]
        )
        #expect(!fm.fileExists(atPath: orphanInvalidated.path))
        #expect(fm.fileExists(atPath: quarantined.path))
        #expect(
            try String(contentsOf: quarantined.appendingPathComponent("executable"), encoding: .utf8) ==
                "v1-backup-exec"
        )
    }

    @Test
    func appBackupsDistinguishesENOENTFromLstatQueryErrors() throws {
        let fm = FileManager.default
        let bundleID = "com.example.lstatquery"
        let backupsRoot = tempDir.appendingPathComponent("AppBackupsQuery", isDirectory: true)
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let targetBackupDir = backupsRoot.appendingPathComponent(bundleID, isDirectory: true)

        let appDir = tempDir.appendingPathComponent("QuerySample.app", isDirectory: true)
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
        #expect(Installer.invalidateAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
        #expect(try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID) == nil)
        try Installer.validateOrInvalidateAppBackupsForLaunch(at: targetBackupDir, for: appInfo)

        // Create backup with mismatched manifest and verify launch validation evicts it when accessible.
        try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
        try Data("stale-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))
        try Installer.validateOrInvalidateAppBackupsForLaunch(at: targetBackupDir, for: appInfo)
        #expect(!fm.fileExists(atPath: targetBackupDir.path))

        // Re-create backup, remove search/read permissions on parent directory (0o000 -> EACCES on lstat),
        // and verify query failures return false / throw rather than silently succeeding.
        if Darwin.geteuid() != 0 {
            try fm.createDirectory(at: targetBackupDir, withIntermediateDirectories: true)
            try Data("protected-exec".utf8).write(to: targetBackupDir.appendingPathComponent("executable"))
            #expect(Darwin.chmod(backupsRoot.path, mode_t(0o000)) == 0)
            defer { _ = Darwin.chmod(backupsRoot.path, mode_t(0o755)) }

            #expect(!Installer.invalidateAppBackups(at: targetBackupDir, bundleIdentifier: bundleID))
            #expect(throws: (any Error).self) {
                try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
            }
            #expect(throws: (any Error).self) {
                try Installer.commitAppBackups(
                    .noneApplicable,
                    to: targetBackupDir,
                    bundleIdentifier: bundleID,
                    manifest: nil
                )
            }
            #expect(throws: (any Error).self) {
                try Installer.validateOrInvalidateAppBackupsForLaunch(at: targetBackupDir, for: appInfo)
            }

            #expect(Darwin.chmod(backupsRoot.path, mode_t(0o755)) == 0)
            #expect(
                try String(contentsOf: targetBackupDir.appendingPathComponent("executable"), encoding: .utf8) ==
                    "protected-exec"
            )
        }
    }

    @Test
    func afterSwapPreservesQuarantinedBackupsOnStagingOrValidationFailure() throws {
        let fm = FileManager.default
        let bundleID = "com.example.degradedbackups"
        let appsDir = tempDir.appendingPathComponent("ApplicationsDegraded", isDirectory: true)
        let backupsRoot = tempDir.appendingPathComponent("AppBackupsDegraded", isDirectory: true)
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
        let candidateV2URL = tempDir.appendingPathComponent("CandidateDegradedV2.app", isDirectory: true)
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
        let preservedQuarantinedURL = try #require(quarantinedV1Dir)
        #expect(publishedV2URL.standardizedFileURL == existingAppURL.standardizedFileURL)
        #expect(v2CommitOutcome == .degradedWithoutBackups)
        #expect(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8) == "v2-live"
        )
        #expect(!fm.fileExists(atPath: targetBackupDir.path))
        #expect(fm.fileExists(atPath: preservedQuarantinedURL.path))
        #expect(
            try String(contentsOf: preservedQuarantinedURL.appendingPathComponent("executable"), encoding: .utf8) ==
                "v1-precious-backup"
        )

        // 2. Subsequent upgrade v3 with .staged validation failure (nil manifest) must also succeed
        //    without rolling back v3 and without wiping previously preserved .invalidated-* backups.
        let candidateV3URL = tempDir.appendingPathComponent("CandidateDegradedV3.app", isDirectory: true)
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
        let invalidStagedV3 = tempDir.appendingPathComponent("staging-v3-unbound", isDirectory: true)
        try fm.createDirectory(at: invalidStagedV3, withIntermediateDirectories: true)
        try Data("v3-exec".utf8).write(to: invalidStagedV3.appendingPathComponent("executable"))

        var v3CommitOutcome: Installer.AppBackupCommitOutcome?
        _ = try Installer.publishSignedBundle(
            BaseApp(appUrl: candidateV3URL),
            into: appsDir,
            prepareAndVerify: { _, _ in },
            beforeSwap: {
                do {
                    let result = try Installer.quarantineAppBackups(at: targetBackupDir, bundleIdentifier: bundleID)
                    #expect(result == nil)
                } catch {
                    Issue.record(error)
                }
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
        #expect(v3CommitOutcome == .degradedWithoutBackups)
        #expect(
            try String(contentsOf: existingAppURL.appendingPathComponent("Sample"), encoding: .utf8) == "v3-live"
        )
        #expect(!fm.fileExists(atPath: invalidStagedV3.path))
        #expect(fm.fileExists(atPath: preservedQuarantinedURL.path))

        // 3. .noneApplicable (new app genuinely needs no backups) still cleans up invalidated backups.
        let noneOutcome = try Installer.finalizeAppBackupsAfterSwap(
            .noneApplicable,
            to: targetBackupDir,
            bundleIdentifier: bundleID,
            manifest: nil,
            quarantinedDir: preservedQuarantinedURL
        )
        #expect(noneOutcome == .noneApplicable)
        #expect(!fm.fileExists(atPath: preservedQuarantinedURL.path))
    }

    @Test
    func appBackupsRejectsPathTraversalSymlinkStagingAndPreservesUnreadableRollbackFiles() throws {
        let fm = FileManager.default

        // 1. Path-traversal and malformed bundle identifiers must never touch sibling directories.
        let backupsRoot = tempDir.appendingPathComponent("AppBackupsTraversal", isDirectory: true)
        let victimDir = backupsRoot.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victimDir, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: victimDir.appendingPathComponent("keep.txt"))

        let maliciousIDs = ["../victim", "nested/id", "..", ".", ".hidden", ""]
        for badID in maliciousIDs {
            #expect(!Installer.isSafeBundleIdentifierForStorage(badID))
            let escapedTarget = backupsRoot.appendingPathComponent("sub", isDirectory: true)
                .appendingPathComponent(badID, isDirectory: true)
            #expect(!Installer.invalidateAppBackups(at: escapedTarget, bundleIdentifier: badID))
            #expect(throws: (any Error).self) {
                try Installer.quarantineAppBackups(at: victimDir, bundleIdentifier: badID)
            }
            #expect(throws: (any Error).self) {
                try Installer.commitAppBackups(
                    .noneApplicable,
                    to: victimDir,
                    bundleIdentifier: badID,
                    manifest: nil
                )
            }
            Installer.cleanupInvalidatedAppBackups(
                primary: victimDir,
                in: backupsRoot,
                bundleIdentifier: badID
            )
        }
        #expect(fm.fileExists(atPath: victimDir.appendingPathComponent("keep.txt").path))

        // 2. stageAppBackups must refuse symlinked Info.plist, embedded.mobileprovision, and executable.
        let secretURL = tempDir.appendingPathComponent("secret-outside.txt")
        try Data("SECRET_HOST_DATA".utf8).write(to: secretURL)
        let symAppDir = tempDir.appendingPathComponent("SymlinkLeak.app", isDirectory: true)
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

        let symStagingDir = tempDir.appendingPathComponent("StagingSymlinkPartial", isDirectory: true)
        let partialStage = Installer.stageAppBackups(for: BaseApp(appUrl: symAppDir), in: symStagingDir)
        guard case .staged(let stagedURL) = partialStage else {
            Issue.record("Expected Info.plist alone to still stage safely")
            return
        }
        #expect(fm.fileExists(atPath: stagedURL.appendingPathComponent("Info.plist").path))
        #expect(!fm.fileExists(atPath: stagedURL.appendingPathComponent("embedded.mobileprovision").path))
        #expect(!fm.fileExists(atPath: stagedURL.appendingPathComponent("executable").path))

        // Replace Info.plist with a symlink too -> nothing regular remains -> .noneApplicable.
        try fm.removeItem(at: symInfoURL)
        try fm.createSymbolicLink(at: symInfoURL, withDestinationURL: secretURL)
        let noneStage = Installer.stageAppBackups(
            for: BaseApp(appUrl: symAppDir),
            in: tempDir.appendingPathComponent("StagingSymlinkNone", isDirectory: true)
        )
        guard case .noneApplicable = noneStage else {
            Issue.record("Expected all-symlink bundle artifacts to yield .noneApplicable")
            return
        }

        // 3. Rollback restoration helper must delete newly created files, restore readable originals,
        //    and NEVER delete pre-existing unreadable files.
        let freshFile = tempDir.appendingPathComponent("fresh-settings.plist")
        try Data("new".utf8).write(to: freshFile)
        Installer.restoreRollbackFile(at: freshFile, existedBefore: false, previousData: nil, label: "settings")
        #expect(!fm.fileExists(atPath: freshFile.path))

        let existingFile = tempDir.appendingPathComponent("existing-settings.plist")
        try Data("updated".utf8).write(to: existingFile)
        Installer.restoreRollbackFile(
            at: existingFile,
            existedBefore: true,
            previousData: Data("original".utf8),
            label: "settings"
        )
        #expect(try String(contentsOf: existingFile, encoding: .utf8) == "original")

        let unreadableFile = tempDir.appendingPathComponent("unreadable-entitlements.plist")
        try Data("locked".utf8).write(to: unreadableFile)
        Installer.restoreRollbackFile(
            at: unreadableFile,
            existedBefore: true,
            previousData: nil,
            label: "entitlements"
        )
        #expect(fm.fileExists(atPath: unreadableFile.path))
    }

    @Test
    func appsVMInvalidatesCachedPlayAppWhenOnDiskInfoChanges() throws {
        let appURL = tempDir.appendingPathComponent("Sample.app", isDirectory: true)
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
        #expect(AppsVM.shouldReuseExistingApp(existing, at: appURL))

        // Overwrite-reinstall with a new PCInstallGeneration must invalidate cached PlayApp.
        plistDict[Installer.installGenerationInfoKey] = "gen-2"
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        #expect(!AppsVM.shouldReuseExistingApp(existing, at: appURL))

        // Reset generation, then bump CFBundleVersion / CFBundleShortVersionString -> also invalidates.
        plistDict[Installer.installGenerationInfoKey] = "gen-1"
        plistDict["CFBundleVersion"] = "101"
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        #expect(!AppsVM.shouldReuseExistingApp(existing, at: appURL))

        plistDict["CFBundleVersion"] = "100"
        plistDict["CFBundleShortVersionString"] = "1.0.1"
        try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        #expect(!AppsVM.shouldReuseExistingApp(existing, at: appURL))
    }

    @Test
    func uninstallerResolvesSVCPatchesBundleIdentifier() {
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.game.json"),
                in: "SVCPatches"
            ) == "com.example.game"
        )
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.json.json"),
                in: "SVCPatches"
            ) == "com.example.json"
        )
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.game"),
                in: "SVCPatches"
            ) == "com.example.game"
        )
    }

    @Test
    func localDataCacheRoundTripAndCleanup() throws {
        let cache = LocalDataCache(name: "TestCache", cacheDirectory: tempDir.appendingPathComponent("cache"))
        let sampleData = Data("hello-macover".utf8)
        cache.write(data: sampleData, forKey: "k-data")
        #expect(cache.hasData(forKey: "k-data"))
        #expect(cache.readData(forKey: "k-data") == sampleData)

        cache.write(string: "cached-version", forKey: "k-string")
        #expect(cache.readString(forKey: "k-string") == "cached-version")

        struct Payload: Codable, Equatable {
            let name: String
            let count: Int
        }
        let payload = Payload(name: "sample", count: 7)
        try cache.write(codable: payload, forKey: "k-codable")
        #expect(try cache.readCodable(forKey: "k-codable") == payload)

        cache.clean(byKey: "k-data")
        #expect(!cache.hasData(forKey: "k-data"))
        #expect(cache.readString(forKey: "k-string") == "cached-version")

        cache.cleanAll()
        #expect(!cache.hasData(forKey: "k-string"))
    }

    @Test
    func nativeDownloadManagerDownloadsLocalFile() async throws {
        let sourceURL = tempDir.appendingPathComponent("sample.ipa")
        let payload = Data("mock-ipa-payload".utf8)
        try payload.write(to: sourceURL)

        let destinationDir = tempDir.appendingPathComponent("downloads", isDirectory: true)
        let (error, downloadedURL): ((any Error)?, URL?) = await withCheckedContinuation { continuation in
            let settled = Mutex<CheckedContinuation<((any Error)?, URL?), Never>?>(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) {
                if let pending = settled.withLock({ cont -> CheckedContinuation<((any Error)?, URL?), Never>? in
                    let current = cont
                    cont = nil
                    return current
                }) {
                    pending.resume(
                        returning: (NSError(domain: "TestTimeout", code: 1), nil)
                    )
                }
            }
            NativeDownloadManager.shared.addDownload(
                url: sourceURL,
                destinationURL: destinationDir,
                onProgress: { _ in },
                onCompletion: { error, fileURL in
                    if let pending = settled.withLock({ cont -> CheckedContinuation<((any Error)?, URL?), Never>? in
                        let current = cont
                        cont = nil
                        return current
                    }) {
                        pending.resume(returning: (error, fileURL))
                    }
                }
            )
        }
        #expect(error == nil)
        let resolvedURL = try #require(downloadedURL)
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
        #expect(try Data(contentsOf: resolvedURL) == payload)
    }

    @Test
    func keyCoverLocalStorageVerifierAndLegacyMigration() async throws {
        let sampleDBBytes = Data("mock-playchain-sqlite-payload".utf8)

        // 1. User-provided password: stores salted PBKDF2 verifier (0600, no plaintext), encrypts/validates/removes cleanly
        do {
            let storeDir = tempDir.appendingPathComponent("kc-user-store", isDirectory: true)
            let chainDir = tempDir.appendingPathComponent("kc-user-chains", isDirectory: true)
            try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)

            let dbURL = chainDir.appendingPathComponent("com.example.user.db")
            try sampleDBBytes.write(to: dbURL)

            let suiteName = "KeyCoverUserTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let keychainReadCount = Mutex(0)
            let keychainDeleteCount = Mutex(0)

            let preferences = KeyCoverPreferences(userDefaults: defaults)
            let observable = await MainActor.run { KeyCoverObservable(preferences: preferences) }
            let passwordStore = KeyCoverPassword(
                preferences: preferences,
                observable: observable,
                storeDirectory: storeDir,
                playChainDirectory: chainDir,
                legacyKeychainReader: {
                    keychainReadCount.withLock { $0 += 1 }
                    return nil
                },
                legacyKeychainDeleter: {
                    keychainDeleteCount.withLock { $0 += 1 }
                }
            )
            let keyCover = KeyCover(
                preferences: preferences,
                passwordStore: passwordStore,
                observable: observable,
                playChainDirectory: chainDir
            )
            passwordStore.attachKeyCover(keyCover)
            await MainActor.run {
                observable.attachKeyCover(keyCover)
            }

            #expect(passwordStore.setKeyCoverPassword("secret-pass-1", mode: .userProvidedPassword))
            preferences.keyCoverEnabled = .userProvidedPassword

            let recordURL = storeDir.appendingPathComponent("keycover.json")
            #expect(FileManager.default.fileExists(atPath: recordURL.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: recordURL.path)
            let posixMode = (attrs[.posixPermissions] as? NSNumber)?.intValue
            #expect(posixMode == 0o600)

            let storedText = try String(contentsOf: recordURL, encoding: .utf8)
            #expect(!storedText.contains("secret-pass-1"))
            #expect(storedText.contains("passwordVerifier"))

            let chain = KeyCoverKey(appBundleID: "com.example.user", playChainDirectory: chainDir)
            #expect(chain.chainEncryptionStatus)
            #expect(!FileManager.default.fileExists(atPath: dbURL.path))

            #expect(!passwordStore.validatePassword("wrong-pass"))
            #expect(passwordStore.validatePassword("secret-pass-1"))
            #expect(keychainReadCount.withLock { $0 } == 0)

            #expect(
                passwordStore.setKeyCoverPassword(
                    "secret-pass-2",
                    mode: .userProvidedPassword,
                    currentPassword: "secret-pass-1"
                )
            )
            #expect(!passwordStore.validatePassword("secret-pass-1"))
            #expect(passwordStore.validatePassword("secret-pass-2"))

            #expect(passwordStore.removeKeyCoverPassword(currentPassword: "secret-pass-2"))
            #expect(preferences.keyCoverEnabled == .disabled)
            #expect(!chain.chainEncryptionStatus)
            #expect(try Data(contentsOf: dbURL) == sampleDBBytes)
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
            #expect(keychainReadCount.withLock { $0 } == 0)
        }

        // 2. Self-generated password: KeyCover.init loads purely from 0600 local store with 0 Keychain reads
        do {
            let storeDir = tempDir.appendingPathComponent("kc-managed-store", isDirectory: true)
            let chainDir = tempDir.appendingPathComponent("kc-managed-chains", isDirectory: true)
            try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)

            let dbURL = chainDir.appendingPathComponent("com.example.managed.db")
            try sampleDBBytes.write(to: dbURL)

            let suiteName = "KeyCoverManagedTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let keychainReadCount = Mutex(0)
            let preferences = KeyCoverPreferences(userDefaults: defaults)
            let observable = await MainActor.run { KeyCoverObservable(preferences: preferences) }
            let passwordStore = KeyCoverPassword(
                preferences: preferences,
                observable: observable,
                storeDirectory: storeDir,
                playChainDirectory: chainDir,
                legacyKeychainReader: {
                    keychainReadCount.withLock { $0 += 1 }
                    return nil
                },
                legacyKeychainDeleter: {}
            )
            let keyCover = KeyCover(
                preferences: preferences,
                passwordStore: passwordStore,
                observable: observable,
                playChainDirectory: chainDir
            )
            passwordStore.attachKeyCover(keyCover)

            let generated = passwordStore.generateVerySecurePassword()
            #expect(passwordStore.setKeyCoverPassword(generated, mode: .selfGeneratedPassword))
            preferences.keyCoverEnabled = .selfGeneratedPassword

            let recordURL = storeDir.appendingPathComponent("keycover.json")
            let attrs = try FileManager.default.attributesOfItem(atPath: recordURL.path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

            let reloadedStore = KeyCoverPassword(
                preferences: preferences,
                storeDirectory: storeDir,
                playChainDirectory: chainDir,
                legacyKeychainReader: {
                    keychainReadCount.withLock { $0 += 1 }
                    return nil
                },
                legacyKeychainDeleter: {}
            )
            let reloadedKeyCover = KeyCover(
                preferences: preferences,
                passwordStore: reloadedStore,
                playChainDirectory: chainDir
            )
            #expect(reloadedKeyCover.keyCoverPlainTextKey == generated)
            #expect(keychainReadCount.withLock { $0 } == 0)

            #expect(reloadedStore.removeKeyCoverPassword())
            #expect(preferences.keyCoverEnabled == .disabled)
            #expect(try Data(contentsOf: dbURL) == sampleDBBytes)
        }

        // 3A. Legacy upgrade (selfGeneratedPassword + no local file + no .keyCover): auto-disables with 0 Keychain reads
        do {
            let storeDir = tempDir.appendingPathComponent("kc-legacy-a-store", isDirectory: true)
            let chainDir = tempDir.appendingPathComponent("kc-legacy-a-chains", isDirectory: true)
            try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)

            let suiteName = "KeyCoverLegacyA.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let keychainReadCount = Mutex(0)
            let keychainDeleteCount = Mutex(0)
            let preferences = KeyCoverPreferences(userDefaults: defaults)
            preferences.keyCoverEnabled = .selfGeneratedPassword

            let passwordStore = KeyCoverPassword(
                preferences: preferences,
                storeDirectory: storeDir,
                playChainDirectory: chainDir,
                legacyKeychainReader: {
                    keychainReadCount.withLock { $0 += 1 }
                    return "legacy-key-unused"
                },
                legacyKeychainDeleter: {
                    keychainDeleteCount.withLock { $0 += 1 }
                }
            )
            _ = KeyCover(
                preferences: preferences,
                passwordStore: passwordStore,
                playChainDirectory: chainDir
            )

            #expect(preferences.keyCoverEnabled == .disabled)
            #expect(keychainReadCount.withLock { $0 } == 0)
            #expect(keychainDeleteCount.withLock { $0 } == 1)
        }

        // 3B. Legacy upgrade (selfGeneratedPassword + encrypted .keyCover): lazy one-time read on unlock, then local
        do {
            let storeDir = tempDir.appendingPathComponent("kc-legacy-b-store", isDirectory: true)
            let chainDir = tempDir.appendingPathComponent("kc-legacy-b-chains", isDirectory: true)
            try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)

            let dbURL = chainDir.appendingPathComponent("com.example.legacy.db")
            try sampleDBBytes.write(to: dbURL)
            let chain = KeyCoverKey(appBundleID: "com.example.legacy", playChainDirectory: chainDir)
            try chain.encryptKeyDB(plainTextKey: "legacy-managed-secret")

            let suiteName = "KeyCoverLegacyB.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let keychainReadCount = Mutex(0)
            let keychainDeleteCount = Mutex(0)
            let preferences = KeyCoverPreferences(userDefaults: defaults)
            preferences.keyCoverEnabled = .selfGeneratedPassword

            let passwordStore = KeyCoverPassword(
                preferences: preferences,
                storeDirectory: storeDir,
                playChainDirectory: chainDir,
                legacyKeychainReader: {
                    keychainReadCount.withLock { $0 += 1 }
                    return "legacy-managed-secret"
                },
                legacyKeychainDeleter: {
                    keychainDeleteCount.withLock { $0 += 1 }
                }
            )
            let keyCover = KeyCover(
                preferences: preferences,
                passwordStore: passwordStore,
                playChainDirectory: chainDir
            )
            passwordStore.attachKeyCover(keyCover)

            // Startup never reads Keychain eagerly
            #expect(keychainReadCount.withLock { $0 } == 0)
            #expect(preferences.keyCoverEnabled == .selfGeneratedPassword)

            try await keyCover.unlockChain(chain)
            #expect(keychainReadCount.withLock { $0 } == 1)
            #expect(keychainDeleteCount.withLock { $0 } == 1)
            #expect(!chain.chainEncryptionStatus)
            #expect(try Data(contentsOf: dbURL) == sampleDBBytes)

            // Subsequent startup reads purely from local 0600 store with 0 new Keychain reads
            let secondKeyCover = KeyCover(
                preferences: preferences,
                passwordStore: passwordStore,
                playChainDirectory: chainDir
            )
            #expect(secondKeyCover.keyCoverPlainTextKey == "legacy-managed-secret")
            #expect(keychainReadCount.withLock { $0 } == 1)
        }

        // 3C. Legacy upgrade (userProvidedPassword + encrypted .keyCover): trial decrypt migrates with 0 Keychain reads
        do {
            let storeDir = tempDir.appendingPathComponent("kc-legacy-c-store", isDirectory: true)
            let chainDir = tempDir.appendingPathComponent("kc-legacy-c-chains", isDirectory: true)
            try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)

            let dbURL = chainDir.appendingPathComponent("com.example.legacyuser.db")
            try sampleDBBytes.write(to: dbURL)
            let chain = KeyCoverKey(appBundleID: "com.example.legacyuser", playChainDirectory: chainDir)
            try chain.encryptKeyDB(plainTextKey: "legacy-user-secret")

            let suiteName = "KeyCoverLegacyC.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let keychainReadCount = Mutex(0)
            let keychainDeleteCount = Mutex(0)
            let preferences = KeyCoverPreferences(userDefaults: defaults)
            preferences.keyCoverEnabled = .userProvidedPassword

            let passwordStore = KeyCoverPassword(
                preferences: preferences,
                storeDirectory: storeDir,
                playChainDirectory: chainDir,
                legacyKeychainReader: {
                    keychainReadCount.withLock { $0 += 1 }
                    return "legacy-user-secret"
                },
                legacyKeychainDeleter: {
                    keychainDeleteCount.withLock { $0 += 1 }
                }
            )

            #expect(!passwordStore.validatePassword("wrong-legacy-secret"))
            #expect(passwordStore.validatePassword("legacy-user-secret"))
            #expect(keychainReadCount.withLock { $0 } == 0)
            #expect(keychainDeleteCount.withLock { $0 } == 1)
            #expect(passwordStore.hasLocalRecord())
        }
    }

    @Test
    @MainActor
    func mitmProxyCoordinatorLifecyclePreparesStopsAndCleansUp() async throws {
        let suiteName = "MITMCoordinatorTest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let certsDir = tempDir.appendingPathComponent("coord-certs", isDirectory: true)
        let settingsDir = tempDir.appendingPathComponent("coord-settings", isDirectory: true)
        let appURL = tempDir.appendingPathComponent("MockMITMCoord.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)

        let bundleID = "com.example.mitmcoord.\(UUID().uuidString.prefix(8))"
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleID,
                "CFBundleExecutable": "MockMITMCoord",
                "CFBundleDisplayName": "Mock MITM Coord",
                "MinimumOSVersion": "17.0"
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: appURL.appendingPathComponent("Info.plist"))

        let deps = PlayCoverDependencies(userDefaults: defaults, loadInitialData: false, configureDiagnostics: false)
        let app = PlayApp(appUrl: appURL, dependencies: deps)
        defer { try? FileManager.default.removeItem(at: app.settings.settingsUrl) }

        app.settings.update {
            $0.networkProxyMode = "builtInMITM"
            $0.mitmPort = 0
        }

        let coordinator = MITMProxyCoordinator(certificatesBaseURL: certsDir, appSettingsBaseURL: settingsDir)
        try await coordinator.prepareForLaunch(app: app, safeModeOneShot: false)
        let startedPort = try #require(coordinator.activePorts[bundleID])
        #expect(startedPort > 0)
        #expect(app.settings.settings.mitmRuntimePort == Int(startedPort))

        await coordinator.handleAppTermination(bundleID: bundleID, settings: app.settings)
        #expect(coordinator.activePorts[bundleID] == nil)
        #expect(app.settings.settings.mitmRuntimePort == 0)

        try await coordinator.prepareForLaunch(app: app, safeModeOneShot: false)
        #expect(coordinator.activePorts[bundleID] != nil)
        await coordinator.stopAllServers(apps: [app])
        #expect(coordinator.activePorts.isEmpty)
        #expect(app.settings.settings.mitmRuntimePort == 0)
    }

    @Test
    func uninstallerResolvePruneBundleIdentifierHandlesInvalidatedAppBackups() {
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/AppBackups/.com.example.demo.invalidated-123"),
                in: "AppBackups"
            ) == "com.example.demo"
        )
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/App Settings/com.example.demo.invalid.plist"),
                in: "App Settings"
            ) == "com.example.demo"
        )
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/PlayChain/com.example.demo.db-wal"),
                in: "PlayChain"
            ) == "com.example.demo"
        )
        #expect(
            Uninstaller.resolvePruneBundleIdentifier(
                for: URL(fileURLWithPath: "/tmp/SVCPatches/com.example.demo.json"),
                in: "SVCPatches"
            ) == "com.example.demo"
        )
    }

    @Test
    @MainActor
    func concurrentAsyncHelpersExecuteSafelyFromMainActor() async {
        let missing = await Cacher().loadRemoteImage(from: "file:///nonexistent-\(UUID().uuidString).png")
        #expect(missing == nil)
    }

    @Test
    func xcstringsFilesHaveValidEnglishAndNoEmptyTranslations() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURLs = [
            repoRoot.appendingPathComponent("PlayCover/Localizable.xcstrings"),
            repoRoot.appendingPathComponent("PlayTools/PlayTools/Playtools.xcstrings")
        ]

        for catalogURL in catalogURLs {
            let data = try Data(contentsOf: catalogURL)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            #expect(!strings.isEmpty, "Empty catalog at \(catalogURL.path)")

            for (key, rawEntry) in strings {
                let entry = try #require(rawEntry as? [String: Any])
                let locs = try #require(entry["localizations"] as? [String: Any], "Missing locs for \(key)")
                let enLoc = try #require(locs["en"] as? [String: Any], "Missing en for \(key)")
                let enUnit = try #require(enLoc["stringUnit"] as? [String: Any])
                let enVal = try #require(enUnit["value"] as? String)
                #expect(!enVal.isEmpty, "Empty en string for \(key)")

                for (lang, rawLang) in locs {
                    if let langObj = rawLang as? [String: Any],
                       let unit = langObj["stringUnit"] as? [String: Any],
                       let val = unit["value"] as? String {
                        #expect(!val.isEmpty, "Empty translation for \(key) [\(lang)] in \(catalogURL.lastPathComponent)")
                    }
                }
            }
        }
    }
}
}
