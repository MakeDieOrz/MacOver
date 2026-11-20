import Foundation
import MachO
import XCTest
@testable import PlayCoverCore
@testable import PlayCoverMachO

final class PlayCoverMachOSPMTests: XCTestCase {
    private func makeSyntheticArm64MachO(
        dylibPath: String = "/System/Library/Frameworks/Foundation.framework/Foundation",
        platform: UInt32 = UInt32(PLATFORM_MACCATALYST)
    ) -> Data {
        var header = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 2,
            sizeofcmds: 0,
            flags: 0,
            reserved: 0
        )

        // LC_BUILD_VERSION
        var buildCmd = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: UInt32(MemoryLayout<build_version_command>.size),
            platform: platform,
            minos: 0x000F0000,
            sdk: 0x000F0000,
            ntools: 0
        )

        // LC_LOAD_DYLIB padded to 8 bytes
        let strData = Data(dylibPath.utf8) + Data([0])
        let baseDylibSize = MemoryLayout<dylib_command>.size
        let totalDylibSize = (baseDylibSize + strData.count + 7) & ~7
        var dylibCmd = dylib_command(
            cmd: UInt32(LC_LOAD_DYLIB),
            cmdsize: UInt32(totalDylibSize),
            dylib: dylib(
                name: lc_str(offset: UInt32(baseDylibSize)),
                timestamp: 0,
                current_version: 0x00010000,
                compatibility_version: 0x00010000
            )
        )

        var commandsData = Data()
        commandsData.append(Data(bytes: &buildCmd, count: MemoryLayout<build_version_command>.size))
        commandsData.append(Data(bytes: &dylibCmd, count: baseDylibSize))
        commandsData.append(strData)
        if totalDylibSize > baseDylibSize + strData.count {
            commandsData.append(Data(repeating: 0, count: totalDylibSize - (baseDylibSize + strData.count)))
        }

        header.sizeofcmds = UInt32(commandsData.count)

        var binary = Data(bytes: &header, count: MemoryLayout<mach_header_64>.size)
        binary.append(commandsData)
        // Add generous load command padding + minimal __TEXT payload so EarliestContentOffset permits injection.
        let paddingNeeded = max(0, 4096 - binary.count)
        binary.append(Data(repeating: 0, count: paddingNeeded))
        return binary
    }

    func testInspectAndValidationOnSyntheticArm64Binary() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMachOSPMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let binURL = tmpDir.appendingPathComponent("SyntheticBin")
        try makeSyntheticArm64MachO().write(to: binURL)

        XCTAssertTrue(try Macho.isMachoValidArch(binURL))
        XCTAssertFalse(try Macho.isMachoEncrypted(atURL: binURL))

        let mockPath =
            "/Users/test/Library/Containers/app.makedie.MacOver/" +
            "Frameworks/PlayTools.framework/PlayTools"
        let inspected = try Macho.inspectBinary(
            atURL: binURL,
            playToolsPath: mockPath
        )
        XCTAssertFalse(inspected.hasPlayTools)
        XCTAssertTrue(inspected.isCatalyst)

        let iosBinURL = tmpDir.appendingPathComponent("SyntheticIOSBin")
        try makeSyntheticArm64MachO(platform: UInt32(PLATFORM_IOS)).write(to: iosBinURL)
        XCTAssertFalse(try Macho.isMachoValidArch(iosBinURL))

        let invalidURL = tmpDir.appendingPathComponent("Invalid")
        try Data("not-macho".utf8).write(to: invalidURL)
        XCTAssertThrowsError(try Macho.isMachoValidArch(invalidURL))
    }

    func testSyncUserPluginsWithStubbedSigner() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMachOPlugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let storeDir = tmpDir.appendingPathComponent("Store", isDirectory: true)
        let targetDir = tmpDir.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: storeDir.appendingPathComponent("Plugin.dylib"))
        try Data("{\"identifier\":\"com.example.p\"}".utf8)
            .write(to: storeDir.appendingPathComponent("Plugin.manifest.json"))

        var signed: [String] = []
        try PlayTools.syncUserPlugins(from: storeDir, into: targetDir) { signed.append($0.lastPathComponent) }
        XCTAssertEqual(signed, ["Plugin.dylib"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("Plugin.dylib").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("Plugin.manifest.json").path))
    }

    func testPlayToolsPathIsIsolatedInsideMacOverContainer() {
        let path = PlayTools.playToolsPath.path
        let expectedSuffix =
            "/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework/PlayTools"
        XCTAssertTrue(path.hasSuffix(expectedSuffix))
        XCTAssertFalse(path.hasSuffix("/Library/Frameworks/PlayTools.framework/PlayTools"))
    }
}
