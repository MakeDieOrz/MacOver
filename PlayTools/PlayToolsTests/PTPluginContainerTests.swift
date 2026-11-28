import Foundation
import Testing

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
final class PTPluginContainerTests {
    private let tempDir: URL
    private let signedDylibTemplateURL: URL

    init() throws {
        pt_reset_hidden_registry_for_testing()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTPluginContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        signedDylibTemplateURL = try Self.buildSignedTestDylibTemplate(in: dir)
    }

    deinit {
        pt_reset_hidden_registry_for_testing()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func buildSignedTestDylibTemplate(in dir: URL) throws -> URL {
        let srcURL = dir.appendingPathComponent("_pt_stub.c")
        let dylibURL = dir.appendingPathComponent("_pt_stub_template.dylib")
        try Data("void pt_test_plugin_stub(void) {}\n".utf8).write(to: srcURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        proc.arguments = ["-arch", "arm64", "-dynamiclib", "-o", dylibURL.path, srcURL.path]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        return dylibURL
    }

    private func writeSignedDylib(to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: signedDylibTemplateURL, to: destination)
    }

    @Test
    func manifestDecodingAndSemanticVersionComparison() throws {
        let json = """
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.plugin.sample-sync",
          "name": "Sample Sync Plugin",
          "version": "1.2.0",
          "minPlayToolsVersion": "4.2.0",
          "targetBundleIdentifiers": ["*"],
          "loadPriority": 50,
          "capabilities": ["sample-bridge", "sample-hooks"],
          "entrypoint": "SampleLegacyPlugin.dylib"
        }
        """
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(decoded.manifestVersion == "1.0")
        #expect(decoded.identifier == "com.example.plugin.sample-sync")
        #expect(decoded.loadPriority == 50)
        #expect(decoded.capabilities == ["sample-bridge", "sample-hooks"])

        #expect(try #require(PTSemanticVersion("4.2.0")) < #require(PTSemanticVersion("5.0.0")))
        #expect(try #require(PTSemanticVersion("4.2")) < #require(PTSemanticVersion("4.2.1")))
        #expect(try #require(PTSemanticVersion("5.0")) == #require(PTSemanticVersion("5.0.0")))
        #expect(PTSemanticVersion("") == nil)
        #expect(PTSemanticVersion("invalid") == nil)
    }

    @Test
    func priorityOrderingLegacySynthesisValidationAndDynamicRegistration() throws {
        let pluginsDir = tempDir.appendingPathComponent("UserPlugins", isDirectory: true)
        let logURL = tempDir.appendingPathComponent("plugin-diag.log")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        // 1. Subdir manifest plugin with priority 10
        let fastDir = pluginsDir.appendingPathComponent("FastMod", isDirectory: true)
        try FileManager.default.createDirectory(at: fastDir, withIntermediateDirectories: true)
        try writeSignedDylib(to: fastDir.appendingPathComponent("libSampleFastPlugin.dylib"))
        let fastManifest = """
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.fast",
          "name": "Fast Sample",
          "version": "1.0.0",
          "minPlayToolsVersion": "5.0.0",
          "targetBundleIdentifiers": ["com.example.target"],
          "loadPriority": 10,
          "capabilities": [],
          "entrypoint": "libSampleFastPlugin.dylib"
        }
        """
        try Data(fastManifest.utf8).write(to: fastDir.appendingPathComponent("PluginManifest.json"))

        // 2. Sidecar manifest plugin with priority 200 (runs after legacy=100)
        try writeSignedDylib(to: pluginsDir.appendingPathComponent("SlowHelper.dylib"))
        let slowManifest = """
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.slow",
          "name": "Slow Helper",
          "version": "1.0.0",
          "minPlayToolsVersion": "4.0",
          "targetBundleIdentifiers": ["*"],
          "loadPriority": 200,
          "entrypoint": "SlowHelper.dylib"
        }
        """
        try Data(slowManifest.utf8).write(to: pluginsDir.appendingPathComponent("SlowHelper.manifest.json"))

        // 3. Bare legacy dylib (priority 100, synthesized manifest)
        try writeSignedDylib(to: pluginsDir.appendingPathComponent("SampleLegacyPlugin.dylib"))

        // 4. Target bundle mismatch (skipped)
        let otherDir = pluginsDir.appendingPathComponent("OtherOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try writeSignedDylib(to: otherDir.appendingPathComponent("OtherOnly.dylib"))
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.other",
          "name": "Other",
          "version": "1.0.0",
          "targetBundleIdentifiers": ["com.some.other.app"],
          "entrypoint": "OtherOnly.dylib"
        }
        """.utf8).write(to: otherDir.appendingPathComponent("PluginManifest.json"))

        // 5. Path traversal entrypoint & minPlayToolsVersion > 5.0.0 & unsupported manifestVersion
        let badDir = pluginsDir.appendingPathComponent("Traversal", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.badpath",
          "name": "BadPath",
          "version": "1.0.0",
          "entrypoint": "../escape.dylib"
        }
        """.utf8).write(to: badDir.appendingPathComponent("PluginManifest.json"))

        let tooNewDir = pluginsDir.appendingPathComponent("TooNew", isDirectory: true)
        try FileManager.default.createDirectory(at: tooNewDir, withIntermediateDirectories: true)
        try Data().write(to: tooNewDir.appendingPathComponent("TooNew.dylib"))
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.toonew",
          "name": "TooNew",
          "version": "1.0.0",
          "minPlayToolsVersion": "9.0.0",
          "entrypoint": "TooNew.dylib"
        }
        """.utf8).write(to: tooNewDir.appendingPathComponent("PluginManifest.json"))

        let badSchemaDir = pluginsDir.appendingPathComponent("BadSchema", isDirectory: true)
        try FileManager.default.createDirectory(at: badSchemaDir, withIntermediateDirectories: true)
        try Data().write(to: badSchemaDir.appendingPathComponent("BadSchema.dylib"))
        try Data("""
        {
          "manifestVersion": "2.0",
          "identifier": "com.example.v2",
          "name": "V2",
          "version": "1.0.0",
          "entrypoint": "BadSchema.dylib"
        }
        """.utf8).write(to: badSchemaDir.appendingPathComponent("PluginManifest.json"))

        var openedPaths: [String] = []
        var openedModes: [Int32] = []
        var pendingError: String?
        let container = PTPluginContainer(
            dlopenHandler: { path, mode in
                openedPaths.append(URL(fileURLWithPath: path).lastPathComponent)
                openedModes.append(mode)
                if path.hasSuffix("SlowHelper.dylib") {
                    pendingError = "dlopen(\(path)): symbol not found _missing_sym"
                    return nil
                }
                pendingError = nil
                return UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF)
            },
            dlerrorHandler: {
                let err = pendingError
                pendingError = nil
                return err
            }
        )

        let records = container.loadPlugins(
            in: pluginsDir,
            currentBundleIdentifier: "com.example.target",
            currentPlayToolsVersion: "5.0.0",
            isSafeModeActive: false,
            diagnosticLogURL: logURL
        )

        // Execution order: priority 10 (libSampleFastPlugin) -> legacy 100 -> priority 200 (SlowHelper)
        #expect(openedPaths == [
            "libSampleFastPlugin.dylib",
            "SampleLegacyPlugin.dylib",
            "SlowHelper.dylib"
        ])
        #expect(openedModes.allSatisfy { $0 == (RTLD_NOW | RTLD_LOCAL) })

        // Dynamic anti-detection registration includes lib-stripped "SampleFastPlugin" & synthesized legacy module
        #expect(pt_is_registered_hidden_module("SampleFastPlugin"))
        #expect(pt_is_registered_hidden_module("libSampleFastPlugin.dylib"))
        #expect(pt_is_registered_hidden_module("SampleLegacyPlugin.dylib"))
        #expect(pt_is_registered_hidden_module("com.example.fast"))

        // SlowHelper failure captured dlerror and wrote diagnostic log
        #expect(records.contains {
            $0.identifier == "com.example.fast" && $0.status == .loaded && !$0.isLegacySynthesized
        })
        #expect(records.contains {
            $0.identifier == "legacy.SampleLegacyPlugin" && $0.status == .loaded && $0.isLegacySynthesized
        })
        let resolvedSlowPath = pluginsDir.appendingPathComponent("SlowHelper.dylib").resolvingSymlinksInPath().path
        #expect(records.contains {
            $0.identifier == "com.example.slow" &&
            $0.status == .failed("dlopen(\(resolvedSlowPath)): symbol not found _missing_sym")
        })
        #expect(records.contains {
            $0.identifier == "com.example.other" && $0.status == .skippedBundleMismatch
        })
        #expect(
            records.filter {
                if case .validationFailed = $0.status { return true }
                return false
            }.count == 3
        )

        let diagText = try String(contentsOf: logURL, encoding: .utf8)
        #expect(diagText.contains("symbol not found _missing_sym"))
    }

    @Test
    func safeModeBlocksUserPluginsAndRecoversPostMortemBreadcrumb() async throws {
        let stateDir = tempDir.appendingPathComponent("SafeModeState", isDirectory: true)
        let safeMode = PTSafeMode(stateDirectory: stateDir, bundleIdentifier: "com.example.crashy")

        // First launch: clean -> writes .launching_in_progress, Safe Mode inactive
        #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(!safeMode.isSafeModeActive)
        #expect(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))

        // Simulate crash before stabilityWindow: second launch sees stale breadcrumb -> enters Safe Mode!
        #expect(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(safeMode.isSafeModeActive)
        #expect(!FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))
        #expect(FileManager.default.fileExists(atPath: safeMode.lastTriggeredURL.path))

        // While Safe Mode is active, PTPluginContainer skips dlopen completely
        let pluginsDir = tempDir.appendingPathComponent("UserPlugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try Data().write(to: pluginsDir.appendingPathComponent("AnyLegacy.dylib"))

        var dlopenCalls = 0
        let container = PTPluginContainer(
            dlopenHandler: { _, _ in
                dlopenCalls += 1
                return UnsafeMutableRawPointer(bitPattern: 0x1234)
            },
            dlerrorHandler: { nil }
        )
        let blocked = container.loadPlugins(
            in: pluginsDir,
            currentBundleIdentifier: "com.example.crashy",
            currentPlayToolsVersion: "5.0.0",
            isSafeModeActive: safeMode.isSafeModeActive
        )
        #expect(dlopenCalls == 0)
        #expect(blocked.count == 1)
        #expect(blocked.first?.status == .blockedBySafeMode)

        // Third launch after Safe Mode recovers to normal and clears breadcrumb after stability window
        #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 0.05))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))

        // Environment override tests ("1" forces ON, "0" forces OFF)
        #expect(safeMode.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"], stabilityWindow: 5.0))
        #expect(safeMode.isSafeModeActive)
        #expect(!safeMode.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"], stabilityWindow: 5.0))
        #expect(!safeMode.isSafeModeActive)
        safeMode.markGracefulTermination()
        #expect(!FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))
    }

    @Test
    func diagnosticLoggerDefaultLogURLUsesProcessTemporaryDirectory() {
        let logURL = PTDiagnosticLogger.defaultLogURL(bundleIdentifier: "com.example.app")
        let expectedDir = FileManager.default.temporaryDirectory.standardizedFileURL
        #expect(logURL.deletingLastPathComponent().standardizedFileURL == expectedDir)
        #expect(logURL.lastPathComponent == "PlayTools-com.example.app.log")

        let globalTmp = URL(fileURLWithPath: "/private/tmp").standardizedFileURL
        if expectedDir != globalTmp {
            #expect(logURL.deletingLastPathComponent().standardizedFileURL != globalTmp)
        }
    }

    @Test
    func macOverVersionCompatibilityAcceptsPlayCoverEraPluginsAndRejectsHigherVersions() throws {
        let pluginsDir = tempDir.appendingPathComponent("UserPluginsCompat", isDirectory: true)
        let logURL = tempDir.appendingPathComponent("compat-diag.log")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        let cases: [(id: String, minVer: String, shouldLoad: Bool)] = [
            ("com.example.macover100", "1.0.0", true),
            ("com.example.pc420", "4.2.0", true),
            ("com.example.pc500", "5.0.0", true),
            ("com.example.pc510", "5.1.0", true),
            ("com.example.macover110", "1.1.0", false),
            ("com.example.pc520", "5.2.0", false),
            ("com.example.future900", "9.0.0", false)
        ]

        for (index, item) in cases.enumerated() {
            let dylibName = "CompatPlugin\(index).dylib"
            try writeSignedDylib(to: pluginsDir.appendingPathComponent(dylibName))
            let manifest = """
            {
              "manifestVersion": "1.0",
              "identifier": "\(item.id)",
              "name": "\(item.id)",
              "version": "1.0.0",
              "minPlayToolsVersion": "\(item.minVer)",
              "targetBundleIdentifiers": ["*"],
              "entrypoint": "\(dylibName)"
            }
            """
            try Data(manifest.utf8).write(
                to: pluginsDir.appendingPathComponent("CompatPlugin\(index).manifest.json")
            )
        }

        let container = PTPluginContainer(
            dlopenHandler: { _, _ in UnsafeMutableRawPointer(bitPattern: 0xCAFE_BABE) },
            dlerrorHandler: { nil }
        )
        let records = container.loadPlugins(
            in: pluginsDir,
            currentBundleIdentifier: "com.example.app",
            currentPlayToolsVersion: "1.0.2",
            isSafeModeActive: false,
            diagnosticLogURL: logURL
        )

        for item in cases {
            let record = try #require(
                records.first(where: { $0.identifier == item.id }),
                "Missing record for \(item.id)"
            )
            if item.shouldLoad {
                #expect(record.status == .loaded, "Expected \(item.id) (\(item.minVer)) to load on 1.0.2")
            } else if case .validationFailed = record.status {
                // Expected rejection
            } else {
                Issue.record("Expected \(item.id) (\(item.minVer)) to fail validation on 1.0.2, got \(record.status)")
            }
        }
    }

    @Test
    func directPluginDirectoryManifestLoadsWithRTLDLocal() throws {
        let bridgeDir = tempDir.appendingPathComponent("BuiltInPlugins/CoverUseBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
        try writeSignedDylib(to: bridgeDir.appendingPathComponent("CoverUseBridge.dylib"))
        let manifest = """
        {
          "manifestVersion": "1.0",
          "identifier": "app.makedie.macover.coverusebridge",
          "name": "CoverUseBridge",
          "version": "1.0.10",
          "minPlayToolsVersion": "1.0.0",
          "targetBundleIdentifiers": ["*"],
          "loadPriority": 10,
          "entrypoint": "CoverUseBridge.dylib"
        }
        """
        try Data(manifest.utf8).write(to: bridgeDir.appendingPathComponent("PluginManifest.json"))

        var openedPath: String?
        var openedMode: Int32 = 0
        let container = PTPluginContainer(
            dlopenHandler: { path, mode in
                openedPath = path
                openedMode = mode
                return UnsafeMutableRawPointer(bitPattern: 0xBEEF_1010)
            },
            dlerrorHandler: { nil }
        )

        let records = container.loadPlugins(
            in: bridgeDir,
            currentBundleIdentifier: "com.example.app",
            currentPlayToolsVersion: "1.0.9",
            isSafeModeActive: false,
            appendToRecords: true
        )
        #expect(records.count == 1)
        #expect(records.first?.status == .loaded)
        #expect(records.first?.isLegacySynthesized == false)
        let resolvedBridgePath = bridgeDir
            .appendingPathComponent("CoverUseBridge.dylib")
            .resolvingSymlinksInPath()
            .path
        #expect(openedPath == resolvedBridgePath)
        #expect(openedMode == (RTLD_NOW | RTLD_LOCAL))
        #expect(pt_is_registered_hidden_module("CoverUseBridge.dylib"))
    }

    @Test
    func rejectsSymlinkEscapeUnsignedAndTamperedDylibs() throws {
        let pluginsDir = tempDir.appendingPathComponent("SecurityPlugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        // 1. Symlink escaping plugin root
        let outsideDylib = tempDir.appendingPathComponent("OutsideSigned.dylib")
        try writeSignedDylib(to: outsideDylib)
        let symlinkDylib = pluginsDir.appendingPathComponent("Escaped.dylib")
        try FileManager.default.createSymbolicLink(at: symlinkDylib, withDestinationURL: outsideDylib)
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.symlink",
          "name": "Symlink",
          "version": "1.0.0",
          "entrypoint": "Escaped.dylib"
        }
        """.utf8).write(to: pluginsDir.appendingPathComponent("Escaped.manifest.json"))

        // 2. Bare symlink dylib (must be skipped at discovery)
        let bareSymlink = pluginsDir.appendingPathComponent("BareEscape.dylib")
        try FileManager.default.createSymbolicLink(at: bareSymlink, withDestinationURL: outsideDylib)

        // 3. Unsigned / empty dylib
        try Data("not-a-macho".utf8).write(to: pluginsDir.appendingPathComponent("Unsigned.dylib"))
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.unsigned",
          "name": "Unsigned",
          "version": "1.0.0",
          "entrypoint": "Unsigned.dylib"
        }
        """.utf8).write(to: pluginsDir.appendingPathComponent("Unsigned.manifest.json"))

        // 4. Tampered dylib (valid ad-hoc binary with corrupted tail bytes)
        let tamperedURL = pluginsDir.appendingPathComponent("Tampered.dylib")
        var tamperedBytes = try Data(contentsOf: signedDylibTemplateURL)
        if !tamperedBytes.isEmpty {
            tamperedBytes[tamperedBytes.count / 2] ^= 0xFF
        }
        try tamperedBytes.write(to: tamperedURL)
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.tampered",
          "name": "Tampered",
          "version": "1.0.0",
          "entrypoint": "Tampered.dylib"
        }
        """.utf8).write(to: pluginsDir.appendingPathComponent("Tampered.manifest.json"))

        // 5. Valid ad-hoc signed dylib
        try writeSignedDylib(to: pluginsDir.appendingPathComponent("Valid.dylib"))
        try Data("""
        {
          "manifestVersion": "1.0",
          "identifier": "com.example.valid",
          "name": "Valid",
          "version": "1.0.0",
          "entrypoint": "Valid.dylib"
        }
        """.utf8).write(to: pluginsDir.appendingPathComponent("Valid.manifest.json"))

        var opened: [String] = []
        let container = PTPluginContainer(
            dlopenHandler: { path, _ in
                opened.append(URL(fileURLWithPath: path).lastPathComponent)
                return UnsafeMutableRawPointer(bitPattern: 0x1234_5678)
            },
            dlerrorHandler: { nil }
        )

        let records = container.loadPlugins(
            in: pluginsDir,
            currentBundleIdentifier: "com.example.app",
            currentPlayToolsVersion: "5.0.0",
            isSafeModeActive: false
        )

        #expect(opened == ["Valid.dylib"])
        #expect(records.contains { $0.identifier == "com.example.valid" && $0.status == .loaded })
        for rejectedID in ["com.example.symlink", "com.example.unsigned", "com.example.tampered"] {
            let rec = try #require(records.first { $0.identifier == rejectedID })
            if case .validationFailed = rec.status {
                // Expected
            } else {
                Issue.record("Expected \(rejectedID) to fail validation, got \(rec.status)")
            }
        }
        #expect(!records.contains { $0.identifier == "legacy.BareEscape" })
    }

    @Test
    func safeModeIgnoresLiveOtherPIDStaleOrForeignBundleBreadcrumbs() throws {
        let stateDir = tempDir.appendingPathComponent("SafeModePID", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let safeMode = PTSafeMode(stateDirectory: stateDir, bundleIdentifier: "com.example.target")

        // 1. Different bundle ID breadcrumb -> should NOT trigger Safe Mode
        let now = Date().timeIntervalSince1970
        let otherBundle = "bundleIdentifier=com.example.other\npid=999999\nstartedAt=\(now)\n"
        try Data(otherBundle.utf8).write(to: safeMode.breadcrumbURL)
        #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(!safeMode.isSafeModeActive)

        // 2. Live other process (PID 1 launchd) -> should NOT trigger Safe Mode
        let liveOther = "bundleIdentifier=com.example.target\npid=1\nstartedAt=\(now)\n"
        try Data(liveOther.utf8).write(to: safeMode.breadcrumbURL)
        #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(!safeMode.isSafeModeActive)

        // 3. Stale breadcrumb older than maxBreadcrumbAge -> should NOT trigger Safe Mode
        let stale = "bundleIdentifier=com.example.target\npid=999999\nstartedAt=\(now - 900.0)\n"
        try Data(stale.utf8).write(to: safeMode.breadcrumbURL)
        #expect(!safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(!safeMode.isSafeModeActive)

        // 4. Fresh dead-PID breadcrumb for same bundle -> DOES trigger Safe Mode
        let crashed = "bundleIdentifier=com.example.target\npid=999999\nstartedAt=\(now)\n"
        try Data(crashed.utf8).write(to: safeMode.breadcrumbURL)
        #expect(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        #expect(safeMode.isSafeModeActive)
    }
}
}
