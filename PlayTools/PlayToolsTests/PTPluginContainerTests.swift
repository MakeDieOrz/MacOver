import Foundation
import XCTest

final class PTPluginContainerTests: XCTestCase {
    private var tempDir: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        pt_reset_hidden_registry_for_testing()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTPluginContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        pt_reset_hidden_registry_for_testing()
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testManifestDecodingAndSemanticVersionComparison() throws {
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
        XCTAssertEqual(decoded.manifestVersion, "1.0")
        XCTAssertEqual(decoded.identifier, "com.example.plugin.sample-sync")
        XCTAssertEqual(decoded.loadPriority, 50)
        XCTAssertEqual(decoded.capabilities, ["sample-bridge", "sample-hooks"])

        XCTAssertLessThan(try XCTUnwrap(PTSemanticVersion("4.2.0")), try XCTUnwrap(PTSemanticVersion("5.0.0")))
        XCTAssertLessThan(try XCTUnwrap(PTSemanticVersion("4.2")), try XCTUnwrap(PTSemanticVersion("4.2.1")))
        XCTAssertEqual(try XCTUnwrap(PTSemanticVersion("5.0")), try XCTUnwrap(PTSemanticVersion("5.0.0")))
        XCTAssertNil(PTSemanticVersion(""))
        XCTAssertNil(PTSemanticVersion("invalid"))
    }

    func testPriorityOrderingLegacySynthesisValidationAndDynamicRegistration() throws {
        let root = try XCTUnwrap(tempDir)
        let pluginsDir = root.appendingPathComponent("UserPlugins", isDirectory: true)
        let logURL = root.appendingPathComponent("plugin-diag.log")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        // 1. Subdir manifest plugin with priority 10
        let fastDir = pluginsDir.appendingPathComponent("FastMod", isDirectory: true)
        try FileManager.default.createDirectory(at: fastDir, withIntermediateDirectories: true)
        try Data().write(to: fastDir.appendingPathComponent("libSampleFastPlugin.dylib"))
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
        try Data().write(to: pluginsDir.appendingPathComponent("SlowHelper.dylib"))
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
        try Data().write(to: pluginsDir.appendingPathComponent("SampleLegacyPlugin.dylib"))

        // 4. Target bundle mismatch (skipped)
        let otherDir = pluginsDir.appendingPathComponent("OtherOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try Data().write(to: otherDir.appendingPathComponent("OtherOnly.dylib"))
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
        var pendingError: String?
        let container = PTPluginContainer(
            dlopenHandler: { path, _ in
                openedPaths.append(URL(fileURLWithPath: path).lastPathComponent)
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

        // Execution order: priority 10 (libSampleFastPlugin) -> legacy 100 (SampleLegacyPlugin) -> priority 200 (SlowHelper)
        XCTAssertEqual(openedPaths, [
            "libSampleFastPlugin.dylib",
            "SampleLegacyPlugin.dylib",
            "SlowHelper.dylib"
        ])

        // Dynamic anti-detection registration includes lib-stripped "SampleFastPlugin" & synthesized legacy module
        XCTAssertTrue(pt_is_registered_hidden_module("SampleFastPlugin"))
        XCTAssertTrue(pt_is_registered_hidden_module("libSampleFastPlugin.dylib"))
        XCTAssertTrue(pt_is_registered_hidden_module("SampleLegacyPlugin.dylib"))
        XCTAssertTrue(pt_is_registered_hidden_module("com.example.fast"))

        // SlowHelper failure captured dlerror and wrote diagnostic log
        XCTAssertTrue(records.contains {
            $0.identifier == "com.example.fast" && $0.status == .loaded && !$0.isLegacySynthesized
        })
        XCTAssertTrue(records.contains {
            $0.identifier == "legacy.SampleLegacyPlugin" && $0.status == .loaded && $0.isLegacySynthesized
        })
        XCTAssertTrue(records.contains {
            $0.identifier == "com.example.slow" &&
            $0.status == .failed("dlopen(\(pluginsDir.appendingPathComponent("SlowHelper.dylib").path)): symbol not found _missing_sym")
        })
        XCTAssertTrue(records.contains {
            $0.identifier == "com.example.other" && $0.status == .skippedBundleMismatch
        })
        XCTAssertEqual(
            records.filter {
                if case .validationFailed = $0.status { return true }
                return false
            }.count,
            3
        )

        let diagText = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(diagText.contains("symbol not found _missing_sym"))
    }

    func testSafeModeBlocksUserPluginsAndRecoversPostMortemBreadcrumb() throws {
        let root = try XCTUnwrap(tempDir)
        let stateDir = root.appendingPathComponent("SafeModeState", isDirectory: true)
        let safeMode = PTSafeMode(stateDirectory: stateDir, bundleIdentifier: "com.example.crashy")

        // First launch: clean -> writes .launching_in_progress, Safe Mode inactive
        XCTAssertFalse(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        XCTAssertFalse(safeMode.isSafeModeActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))

        // Simulate crash before stabilityWindow: second launch sees stale breadcrumb -> enters Safe Mode!
        XCTAssertTrue(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 5.0))
        XCTAssertTrue(safeMode.isSafeModeActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeMode.lastTriggeredURL.path))

        // While Safe Mode is active, PTPluginContainer skips dlopen completely
        let pluginsDir = root.appendingPathComponent("UserPlugins", isDirectory: true)
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
        XCTAssertEqual(dlopenCalls, 0)
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?.status, .blockedBySafeMode)

        // Third launch after Safe Mode recovers to normal and clears breadcrumb after stability window
        XCTAssertFalse(safeMode.evaluateAndBeginLaunch(environment: [:], stabilityWindow: 0.05))
        let exp = expectation(description: "stability timer removes breadcrumb")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))

        // Environment override tests ("1" forces ON, "0" forces OFF)
        XCTAssertTrue(safeMode.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "1"], stabilityWindow: 5.0))
        XCTAssertTrue(safeMode.isSafeModeActive)
        XCTAssertFalse(safeMode.evaluateAndBeginLaunch(environment: ["PLAYTOOLS_SAFE_MODE": "0"], stabilityWindow: 5.0))
        XCTAssertFalse(safeMode.isSafeModeActive)
        safeMode.markGracefulTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: safeMode.breadcrumbURL.path))
    }

    func testDiagnosticLoggerDefaultLogURLUsesProcessTemporaryDirectory() throws {
        let logURL = PTDiagnosticLogger.defaultLogURL(bundleIdentifier: "com.example.app")
        let expectedDir = FileManager.default.temporaryDirectory.standardizedFileURL
        XCTAssertEqual(logURL.deletingLastPathComponent().standardizedFileURL, expectedDir)
        XCTAssertEqual(logURL.lastPathComponent, "PlayTools-com.example.app.log")

        let globalTmp = URL(fileURLWithPath: "/private/tmp").standardizedFileURL
        if expectedDir != globalTmp {
            XCTAssertNotEqual(logURL.deletingLastPathComponent().standardizedFileURL, globalTmp)
        }
    }

    func testMacOverVersionCompatibilityAcceptsPlayCoverEraPluginsAndRejectsHigherVersions() throws {
        let root = try XCTUnwrap(tempDir)
        let pluginsDir = root.appendingPathComponent("UserPluginsCompat", isDirectory: true)
        let logURL = root.appendingPathComponent("compat-diag.log")
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
            try Data().write(to: pluginsDir.appendingPathComponent(dylibName))
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
            guard let record = records.first(where: { $0.identifier == item.id }) else {
                return XCTFail("Missing record for \(item.id)")
            }
            if item.shouldLoad {
                XCTAssertEqual(record.status, .loaded, "Expected \(item.id) (\(item.minVer)) to load on 1.0.2")
            } else if case .validationFailed = record.status {
                // Expected rejection
            } else {
                XCTFail("Expected \(item.id) (\(item.minVer)) to fail validation on 1.0.2, got \(record.status)")
            }
        }
    }
}
