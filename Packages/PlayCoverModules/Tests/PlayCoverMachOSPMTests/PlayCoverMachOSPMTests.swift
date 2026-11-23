import CryptoKit
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
        let manifestTarget = targetDir.appendingPathComponent("Plugin.manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestTarget.path))
    }

    func testPlayToolsPathIsIsolatedInsideMacOverContainer() {
        let path = PlayTools.playToolsPath.path
        let expectedSuffix =
            "/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework/PlayTools"
        XCTAssertTrue(path.hasSuffix(expectedSuffix))
        XCTAssertFalse(path.hasSuffix("/Library/Frameworks/PlayTools.framework/PlayTools"))
    }

    private struct SyntheticSVCBinary {
        let data: Data
        let codeSvcFileOffsets: [Int]
        let codeSvcVMOffsets: [UInt64]
        let dataInCodeSvcFileOffset: Int
        let dataConstSvcFileOffset: Int
        let linkeditDummyOffset: Int
    }

    private func appendFixed16String(_ string: String) -> (
        Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
        Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8
    ) {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (idx, b) in string.utf8.prefix(16).enumerated() {
            bytes[idx] = b
        }
        return (
            Int8(bitPattern: bytes[0]), Int8(bitPattern: bytes[1]),
            Int8(bitPattern: bytes[2]), Int8(bitPattern: bytes[3]),
            Int8(bitPattern: bytes[4]), Int8(bitPattern: bytes[5]),
            Int8(bitPattern: bytes[6]), Int8(bitPattern: bytes[7]),
            Int8(bitPattern: bytes[8]), Int8(bitPattern: bytes[9]),
            Int8(bitPattern: bytes[10]), Int8(bitPattern: bytes[11]),
            Int8(bitPattern: bytes[12]), Int8(bitPattern: bytes[13]),
            Int8(bitPattern: bytes[14]), Int8(bitPattern: bytes[15])
        )
    }

    private func buildSyntheticArm64BinaryWithSVC(
        filetype: UInt32 = UInt32(MH_EXECUTE),
        textSegmentVMAddr: UInt64 = 0x1_0000_0000,
        codeSvcCount: Int = 2
    ) -> SyntheticSVCBinary {
        let textFileStart = 0x1000
        let textSectionVMAddr = textSegmentVMAddr + UInt64(textFileStart)
        let svcWord = InlineSyscallPatcher.svcInstruction
        let nopWord: UInt32 = 0xD503_201F
        let retWord: UInt32 = 0xD65F_03C0

        var codeWords: [UInt32] = [nopWord]
        var codeSvcRelOffsets: [Int] = []
        codeWords.append(svcWord)
        codeSvcRelOffsets.append(textFileStart + (codeWords.count - 1) * 4)

        let dicRelOffset = textFileStart + codeWords.count * 4
        codeWords.append(svcWord) // Must remain untouched because covered by LC_DATA_IN_CODE

        if codeSvcCount >= 2 {
            codeWords.append(retWord)
            codeWords.append(svcWord)
            codeSvcRelOffsets.append(textFileStart + (codeWords.count - 1) * 4)
        }
        codeWords.append(retWord)

        let codeSize = codeWords.count * 4
        let dataConstFileOffset = 0x2000
        let linkeditFileOffset = 0x3000
        let dicTableOffset = linkeditFileOffset
        let dicTableSize = MemoryLayout<data_in_code_entry>.size
        let linkeditDummyOffset = linkeditFileOffset + 0x40
        let totalSize = 0x4000

        var textSeg = segment_command_64(
            cmd: UInt32(LC_SEGMENT_64),
            cmdsize: UInt32(MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size),
            segname: appendFixed16String("__TEXT"),
            vmaddr: textSegmentVMAddr,
            vmsize: 0x2000,
            fileoff: 0,
            filesize: 0x2000,
            maxprot: VM_PROT_READ | VM_PROT_EXECUTE,
            initprot: VM_PROT_READ | VM_PROT_EXECUTE,
            nsects: 1,
            flags: 0
        )
        var textSect = section_64(
            sectname: appendFixed16String("__text"),
            segname: appendFixed16String("__TEXT"),
            addr: textSectionVMAddr,
            size: UInt64(codeSize),
            offset: UInt32(textFileStart),
            align: 2,
            reloff: 0,
            nreloc: 0,
            flags: UInt32(S_ATTR_PURE_INSTRUCTIONS) | UInt32(S_ATTR_SOME_INSTRUCTIONS),
            reserved1: 0,
            reserved2: 0,
            reserved3: 0
        )

        var dataSeg = segment_command_64(
            cmd: UInt32(LC_SEGMENT_64),
            cmdsize: UInt32(MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size),
            segname: appendFixed16String("__DATA"),
            vmaddr: textSegmentVMAddr + 0x2000,
            vmsize: 0x1000,
            fileoff: UInt64(dataConstFileOffset),
            filesize: 0x1000,
            maxprot: VM_PROT_READ | VM_PROT_WRITE,
            initprot: VM_PROT_READ | VM_PROT_WRITE,
            nsects: 1,
            flags: 0
        )
        var dataSect = section_64(
            sectname: appendFixed16String("__const"),
            segname: appendFixed16String("__DATA"),
            addr: textSegmentVMAddr + 0x2000,
            size: 4,
            offset: UInt32(dataConstFileOffset),
            align: 2,
            reloff: 0,
            nreloc: 0,
            flags: 0,
            reserved1: 0,
            reserved2: 0,
            reserved3: 0
        )

        var dicCmd = linkedit_data_command(
            cmd: UInt32(LC_DATA_IN_CODE),
            cmdsize: UInt32(MemoryLayout<linkedit_data_command>.size),
            dataoff: UInt32(dicTableOffset),
            datasize: UInt32(dicTableSize)
        )
        var dicEntry = data_in_code_entry(
            offset: UInt32(dicRelOffset),
            length: 4,
            kind: UInt16(DICE_KIND_DATA)
        )

        let sizeofcmds = Int(textSeg.cmdsize + dataSeg.cmdsize + dicCmd.cmdsize)
        var mh = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: filetype,
            ncmds: 3,
            sizeofcmds: UInt32(sizeofcmds),
            flags: 0,
            reserved: 0
        )

        var data = Data(count: totalSize)
        var cursor = 0
        withUnsafeBytes(of: &mh) {
            data.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &textSeg) {
            data.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &textSect) {
            data.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &dataSeg) {
            data.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &dataSect) {
            data.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &dicCmd) {
            data.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }

        for (idx, word) in codeWords.enumerated() {
            var le = word.littleEndian
            let off = textFileStart + idx * 4
            withUnsafeBytes(of: &le) {
                data.replaceSubrange(off..<(off + 4), with: $0)
            }
        }

        var dataConstWord = svcWord.littleEndian
        withUnsafeBytes(of: &dataConstWord) {
            data.replaceSubrange(dataConstFileOffset..<(dataConstFileOffset + 4), with: $0)
        }
        withUnsafeBytes(of: &dicEntry) {
            data.replaceSubrange(dicTableOffset..<(dicTableOffset + $0.count), with: $0)
        }

        return SyntheticSVCBinary(
            data: data,
            codeSvcFileOffsets: codeSvcRelOffsets,
            codeSvcVMOffsets: codeSvcRelOffsets.map { UInt64($0) },
            dataInCodeSvcFileOffset: dicRelOffset,
            dataConstSvcFileOffset: dataConstFileOffset,
            linkeditDummyOffset: linkeditDummyOffset
        )
    }

    private func buildFatBinaryWithDummyX86AndArm64(_ arm64Slice: Data) -> (data: Data, arm64SliceOffset: Int) {
        let x86Offset = 0x1000
        let x86Size = 0x1000
        let armOffset = 0x4000
        var fat = Data(count: armOffset + arm64Slice.count)
        var header = fat_header(magic: FAT_MAGIC.bigEndian, nfat_arch: UInt32(2).bigEndian)
        var x86Arch = fat_arch(
            cputype: Int32(bitPattern: UInt32(bitPattern: CPU_TYPE_X86_64).bigEndian),
            cpusubtype: Int32(bitPattern: UInt32(3).bigEndian),
            offset: UInt32(x86Offset).bigEndian,
            size: UInt32(x86Size).bigEndian,
            align: UInt32(12).bigEndian
        )
        var armArch = fat_arch(
            cputype: Int32(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: Int32(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_ARM64_ALL).bigEndian),
            offset: UInt32(armOffset).bigEndian,
            size: UInt32(arm64Slice.count).bigEndian,
            align: UInt32(14).bigEndian
        )

        var cursor = 0
        withUnsafeBytes(of: &header) {
            fat.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &x86Arch) {
            fat.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &armArch) {
            fat.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        fat.replaceSubrange(armOffset..<(armOffset + arm64Slice.count), with: arm64Slice)
        return (fat, armOffset)
    }

    private func readUInt32LE(from url: URL, at offset: Int) throws -> UInt32 {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, offset + 4 <= data.count else { return 0 }
            return UInt32(littleEndian: base.advanced(by: offset).loadUnaligned(as: UInt32.self))
        }
    }

    func testInlineSyscallPatcherThinAndFatRoundTripAndExclusions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("svc-patcher-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("TestApp.app", isDirectory: true)
        let helperDir = appURL.appendingPathComponent("Frameworks/Helper.framework", isDirectory: true)
        let excludedPTDir = appURL.appendingPathComponent("Frameworks/PlayTools.framework", isDirectory: true)
        let manifestURL = root.appendingPathComponent("SVCPatches/com.example.svc.json")

        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: excludedPTDir, withIntermediateDirectories: true)

        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "TestApp"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: appURL.appendingPathComponent("Info.plist"))

        let mainSynth = buildSyntheticArm64BinaryWithSVC(
            filetype: UInt32(MH_EXECUTE),
            textSegmentVMAddr: 0x1_0000_0000,
            codeSvcCount: 2
        )
        let mainExecURL = appURL.appendingPathComponent("TestApp")
        try mainSynth.data.write(to: mainExecURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecURL.path)

        let dylibSynth = buildSyntheticArm64BinaryWithSVC(
            filetype: UInt32(MH_DYLIB),
            textSegmentVMAddr: 0,
            codeSvcCount: 1
        )
        let fatDylib = buildFatBinaryWithDummyX86AndArm64(dylibSynth.data)
        let helperURL = helperDir.appendingPathComponent("Helper")
        try fatDylib.data.write(to: helperURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let excludedURL = excludedPTDir.appendingPathComponent("PlayTools")
        try dylibSynth.data.write(to: excludedURL)

        let res1 = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: true
        )
        XCTAssertTrue(res1.modified)
        XCTAssertEqual(res1.patchedSiteCount, 3)
        XCTAssertEqual(Set(res1.modifiedBinaryURLs.map { $0.lastPathComponent }), ["TestApp", "Helper"])

        // Verify permissions & patched words + exclusions
        let mainPerms = (try fm.attributesOfItem(atPath: mainExecURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mainPerms, 0o755)
        for off in mainSynth.codeSvcFileOffsets {
            XCTAssertEqual(try readUInt32LE(from: mainExecURL, at: off), InlineSyscallPatcher.brkInstruction)
        }
        XCTAssertEqual(
            try readUInt32LE(from: mainExecURL, at: mainSynth.dataInCodeSvcFileOffset),
            InlineSyscallPatcher.svcInstruction
        )
        XCTAssertEqual(
            try readUInt32LE(from: mainExecURL, at: mainSynth.dataConstSvcFileOffset),
            InlineSyscallPatcher.svcInstruction
        )

        let fatSvcOff = fatDylib.arm64SliceOffset + dylibSynth.codeSvcFileOffsets[0]
        let fatDICOOff = fatDylib.arm64SliceOffset + dylibSynth.dataInCodeSvcFileOffset
        let fatConstOff = fatDylib.arm64SliceOffset + dylibSynth.dataConstSvcFileOffset
        XCTAssertEqual(try readUInt32LE(from: helperURL, at: fatSvcOff), InlineSyscallPatcher.brkInstruction)
        XCTAssertEqual(try readUInt32LE(from: helperURL, at: fatDICOOff), InlineSyscallPatcher.svcInstruction)
        XCTAssertEqual(try readUInt32LE(from: helperURL, at: fatConstOff), InlineSyscallPatcher.svcInstruction)

        XCTAssertEqual(
            try readUInt32LE(from: excludedURL, at: dylibSynth.codeSvcFileOffsets[0]),
            InlineSyscallPatcher.svcInstruction
        )

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SVCPatchManifest.self, from: manifestData)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.bundleIdentifier, "com.example.svc")
        XCTAssertEqual(manifest.originalInstruction, InlineSyscallPatcher.svcInstruction)
        XCTAssertEqual(manifest.patchInstruction, InlineSyscallPatcher.brkInstruction)
        XCTAssertEqual(manifest.files.count, 2)
        let mainManifestEntry = try XCTUnwrap(manifest.files.first { $0.relativePath == "TestApp" })
        XCTAssertEqual(mainManifestEntry.sites.map { $0.vmOffset }, mainSynth.codeSvcVMOffsets)

        // Second apply must be a clean no-op
        let res2 = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: true
        )
        XCTAssertFalse(res2.modified)
        XCTAssertTrue(res2.modifiedBinaryURLs.isEmpty)
        XCTAssertEqual(res2.patchedSiteCount, 3)

        // Exact byte-for-byte revert when disabled
        let revert1 = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: false
        )
        XCTAssertTrue(revert1.modified)
        XCTAssertEqual(revert1.patchedSiteCount, 0)
        XCTAssertFalse(fm.fileExists(atPath: manifestURL.path))
        XCTAssertEqual(try Data(contentsOf: mainExecURL), mainSynth.data)
        XCTAssertEqual(try Data(contentsOf: helperURL), fatDylib.data)

        // Re-patch, simulate codesign __LINKEDIT mutation, verify idempotency + clean revert
        _ = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: true
        )
        var resignedMain = try Data(contentsOf: mainExecURL)
        resignedMain.replaceSubrange(
            mainSynth.linkeditDummyOffset..<(mainSynth.linkeditDummyOffset + 4),
            with: [0xCA, 0xFE, 0xBA, 0xBE]
        )
        try resignedMain.write(to: mainExecURL)

        let resAfterResign = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: true
        )
        XCTAssertFalse(resAfterResign.modified)

        let revertAfterResign = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: false
        )
        XCTAssertTrue(revertAfterResign.modified)
        XCTAssertFalse(fm.fileExists(atPath: manifestURL.path))
        for off in mainSynth.codeSvcFileOffsets {
            XCTAssertEqual(try readUInt32LE(from: mainExecURL, at: off), InlineSyscallPatcher.svcInstruction)
        }
    }
}
