import Foundation
import MachO
import PlayCoverCore
import PlayCoverInstaller
import PlayCoverMachO
import Testing

@Suite
struct PlayCoverInstallerSPMTests {
    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTestAppInfo(bundleID: String, generation: String) throws -> AppInfo {
        let dir = try makeTempDir("PlayCoverAppInfoTest")
        let plistURL = dir.appendingPathComponent("Info.plist")
        let dict: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "Game",
            AppBackupManifest.installGenerationInfoKey: generation
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL)
        return AppInfo(contentsOf: plistURL)
    }

    @Test
    func backupTransactionStageCommitVerifyQuarantineRestoreCleanup() throws {
        let root = try makeTempDir("PlayCoverBackupTransactionTest")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("Sample.app", isDirectory: true)
        let codeSigDir = bundleURL.appendingPathComponent("_CodeSignature", isDirectory: true)
        try FileManager.default.createDirectory(at: codeSigDir, withIntermediateDirectories: true)

        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        let provisionURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        let codeResourcesURL = codeSigDir.appendingPathComponent("CodeResources")
        let execURL = bundleURL.appendingPathComponent("Game")

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.game",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "42",
                "CFBundleExecutable": "Game",
                AppBackupManifest.installGenerationInfoKey: "GEN-1"
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: infoURL)
        try Data("prov".utf8).write(to: provisionURL)
        try Data("cr".utf8).write(to: codeResourcesURL)
        var header = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 1,
            sizeofcmds: 0,
            flags: 0,
            reserved: 0
        )
        var buildCmd = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: UInt32(MemoryLayout<build_version_command>.size),
            platform: UInt32(PLATFORM_IOS),
            minos: 0x000F0000,
            sdk: 0x000F0000,
            ntools: 0
        )
        let commandsData = Data(bytes: &buildCmd, count: MemoryLayout<build_version_command>.size)
        header.sizeofcmds = UInt32(commandsData.count)
        var machData = Data(bytes: &header, count: MemoryLayout<mach_header_64>.size)
        machData.append(commandsData)
        machData.append(Data(repeating: 0, count: max(0, 4096 - machData.count)))
        try machData.write(to: execURL)

        let stagingDir = root.appendingPathComponent("Staging", isDirectory: true)
        let staged = BackupTransactionStore.stageAppBackups(
            bundleURL: bundleURL,
            executableURL: execURL,
            in: stagingDir
        )
        guard case let .staged(stagedURL) = staged else {
            Issue.record("Expected staged result, got \(staged)")
            return
        }

        let backupsRoot = root.appendingPathComponent("AppBackups", isDirectory: true)
        let targetDir = backupsRoot.appendingPathComponent("com.example.game", isDirectory: true)
        let appInfo = try makeTestAppInfo(bundleID: "com.example.game", generation: "GEN-1")
        defer { try? FileManager.default.removeItem(at: appInfo.url.deletingLastPathComponent()) }

        let manifest = AppBackupManifest(appInfo: appInfo)
        let outcome = try BackupTransactionStore.commitAppBackups(
            .staged(stagedURL),
            to: targetDir,
            bundleIdentifier: "com.example.game",
            manifest: manifest
        )
        #expect(outcome == .committed)
        #expect(BackupTransactionStore.verifyAppBackupManifest(in: targetDir, for: appInfo))

        // Quarantine and restore
        let quarantined = try BackupTransactionStore.quarantineAppBackups(
            at: targetDir,
            bundleIdentifier: "com.example.game"
        )
        #expect(quarantined != nil)
        #expect(BackupTransactionStore.probePathPresence(at: targetDir) == .absent)
        if let quarantined {
            #expect(
                BackupTransactionStore.restoreQuarantinedAppBackups(
                    quarantined,
                    to: targetDir,
                    bundleIdentifier: "com.example.game"
                )
            )
            #expect(BackupTransactionStore.probePathPresence(at: targetDir) == .present)
        }

        // Launch validation invalidates mismatched generation
        let nextInfo = try makeTestAppInfo(bundleID: "com.example.game", generation: "GEN-2")
        defer { try? FileManager.default.removeItem(at: nextInfo.url.deletingLastPathComponent()) }
        try BackupTransactionStore.validateOrInvalidateAppBackupsForLaunch(at: targetDir, for: nextInfo)
        #expect(BackupTransactionStore.probePathPresence(at: targetDir) == .absent)

        // Reject unsafe bundle identifiers
        #expect(!BackupTransactionStore.isSafeBundleIdentifierForStorage("../escape"))
        #expect(!BackupTransactionStore.invalidateAppBackups(at: targetDir, bundleIdentifier: "../escape"))

        // restoreRollbackFile removes newly created files and restores prior data
        let rollbackTarget = root.appendingPathComponent("rollback.plist")
        try Data("new".utf8).write(to: rollbackTarget)
        BackupTransactionStore.restoreRollbackFile(
            at: rollbackTarget,
            existedBefore: false,
            previousData: nil,
            label: "test"
        )
        #expect(!FileManager.default.fileExists(atPath: rollbackTarget.path))

        BackupTransactionStore.restoreRollbackFile(
            at: rollbackTarget,
            existedBefore: true,
            previousData: Data("old".utf8),
            label: "test"
        )
        #expect(try Data(contentsOf: rollbackTarget) == Data("old".utf8))
    }

    @Test
    func launchEnvironmentPatcherStripAndRestoreRoundTrip() {
        let initial: [String: String] = [
            "DYLD_LIBRARY_PATH": [
                LaunchEnvironmentPatcher.introspectionLibraryPath,
                "/custom/lib",
                LaunchEnvironmentPatcher.iosFrameworksLibraryPath
            ].joined(separator: ":"),
            "OTHER": "1"
        ]

        let stripped = LaunchEnvironmentPatcher.stripForStrictLaunch(env: initial)
        #expect(stripped.changed)
        #expect(stripped.discoveredIntrospection)
        #expect(stripped.discoveredIosFrameworks)
        #expect(stripped.env["DYLD_LIBRARY_PATH"] == "/custom/lib")
        #expect(stripped.env["OTHER"] == "1")

        let secondStrip = LaunchEnvironmentPatcher.stripForStrictLaunch(env: stripped.env)
        #expect(!secondStrip.changed)

        let restored = LaunchEnvironmentPatcher.restoreForNonStrictLaunch(
            env: stripped.env,
            storedHasIntrospection: true,
            storedHasIosFrameworks: true
        )
        #expect(restored.changed)
        #expect(
            LaunchEnvironmentPatcher.containsLibraryPath(
                LaunchEnvironmentPatcher.introspectionLibraryPath,
                in: restored.env
            )
        )
        #expect(
            LaunchEnvironmentPatcher.containsLibraryPath(
                LaunchEnvironmentPatcher.iosFrameworksLibraryPath,
                in: restored.env
            )
        )

        #expect(LaunchEnvironmentPatcher.sanitizedLSEnvironment(["DYLD_LIBRARY_PATH": "", "A": "B"]) == ["A": "B"])
    }

    @Test
    func stageAppBackupsExtractsArm64SliceFromUniversalBinary() throws {
        let root = try makeTempDir("PlayCoverFatStageTest")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("FatGame.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.fatstage",
                "CFBundleExecutable": "FatGame"
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))

        var buildCmd = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: UInt32(MemoryLayout<build_version_command>.size),
            platform: UInt32(PLATFORM_IOS),
            minos: 0x000F_0000,
            sdk: 0x000F_0000,
            ntools: 0
        )
        let cmdData = Data(bytes: &buildCmd, count: MemoryLayout<build_version_command>.size)
        var armHeader = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 1,
            sizeofcmds: UInt32(cmdData.count),
            flags: 0,
            reserved: 0
        )
        var armSlice = Data(bytes: &armHeader, count: MemoryLayout<mach_header_64>.size)
        armSlice.append(cmdData)
        armSlice.append(Data(repeating: 0xA5, count: 4096 - armSlice.count))

        let x86Offset = 0x1000
        let x86Size = 0x1000
        let armOffset = 0x4000
        var fatData = Data(count: armOffset + armSlice.count)
        var fatHdr = fat_header(magic: FAT_MAGIC.bigEndian, nfat_arch: UInt32(2).bigEndian)
        var x86Arch = fat_arch(
            cputype: Int32(bitPattern: UInt32(bitPattern: CPU_TYPE_X86_64).bigEndian),
            cpusubtype: Int32(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_X86_64_ALL).bigEndian),
            offset: UInt32(x86Offset).bigEndian,
            size: UInt32(x86Size).bigEndian,
            align: UInt32(12).bigEndian
        )
        var armArch = fat_arch(
            cputype: Int32(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: Int32(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_ARM64_ALL).bigEndian),
            offset: UInt32(armOffset).bigEndian,
            size: UInt32(armSlice.count).bigEndian,
            align: UInt32(14).bigEndian
        )
        var cursor = 0
        withUnsafeBytes(of: &fatHdr) {
            fatData.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &x86Arch) {
            fatData.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &armArch) {
            fatData.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        fatData.replaceSubrange(armOffset..<(armOffset + armSlice.count), with: armSlice)

        let execURL = bundleURL.appendingPathComponent("FatGame")
        try fatData.write(to: execURL)

        let stagingDir = root.appendingPathComponent("Staging", isDirectory: true)
        let staged = BackupTransactionStore.stageAppBackups(
            bundleURL: bundleURL,
            executableURL: execURL,
            in: stagingDir
        )
        guard case let .staged(stagedURL) = staged else {
            Issue.record("Expected staged result for universal binary, got \(staged)")
            return
        }
        let stagedExec = stagedURL.appendingPathComponent("executable")
        let extractedData = try Data(contentsOf: stagedExec)
        #expect(extractedData == armSlice)
        let attrs = try FileManager.default.attributesOfItem(atPath: stagedExec.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o755)
    }
}
