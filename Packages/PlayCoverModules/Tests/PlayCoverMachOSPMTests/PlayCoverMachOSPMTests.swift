import CryptoKit
import Foundation
import MachO
import Synchronization
import Testing
@testable import PlayCoverCore
@testable import PlayCoverMachO

@Suite(.serialized)
struct PlayCoverMachOSPMTests {
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

        var buildCmd = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: UInt32(MemoryLayout<build_version_command>.size),
            platform: platform,
            minos: 0x000F0000,
            sdk: 0x000F0000,
            ntools: 0
        )

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
        let paddingNeeded = max(0, 4096 - binary.count)
        binary.append(Data(repeating: 0, count: paddingNeeded))
        return binary
    }

    @Test
    func inspectAndValidationOnSyntheticArm64Binary() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMachOSPMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let binURL = tmpDir.appendingPathComponent("SyntheticBin")
        try makeSyntheticArm64MachO().write(to: binURL)

        #expect(try Macho.isMachoValidArch(binURL))
        #expect(try !Macho.isMachoEncrypted(atURL: binURL))

        let mockPath =
            "/Users/test/Library/Containers/app.makedie.MacOver/" +
            "Frameworks/PlayTools.framework/PlayTools"
        let inspected = try Macho.inspectBinary(
            atURL: binURL,
            playToolsPath: mockPath
        )
        #expect(!inspected.hasPlayTools)
        #expect(inspected.isCatalyst)

        let iosBinURL = tmpDir.appendingPathComponent("SyntheticIOSBin")
        try makeSyntheticArm64MachO(platform: UInt32(PLATFORM_IOS)).write(to: iosBinURL)
        #expect(try !Macho.isMachoValidArch(iosBinURL))

        let invalidURL = tmpDir.appendingPathComponent("Invalid")
        try Data("not-macho".utf8).write(to: invalidURL)
        #expect(throws: (any Error).self) {
            try Macho.isMachoValidArch(invalidURL)
        }
    }

    @Test
    func syncUserPluginsWithStubbedSigner() throws {
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

        let signed = Mutex<[String]>([])
        try PlayTools.syncUserPlugins(from: storeDir, into: targetDir) { url in
            signed.withLock { $0.append(url.lastPathComponent) }
        }
        #expect(signed.withLock { $0 } == ["Plugin.dylib"])
        #expect(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("Plugin.dylib").path))
        let manifestTarget = targetDir.appendingPathComponent("Plugin.manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestTarget.path))
    }

    @Test
    func playToolsPathIsIsolatedInsideMacOverContainer() {
        let path = PlayTools.playToolsPath.path
        let expectedSuffix =
            "/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework/PlayTools"
        #expect(path.hasSuffix(expectedSuffix))
        #expect(!path.hasSuffix("/Library/Frameworks/PlayTools.framework/PlayTools"))
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
        codeWords.append(svcWord)

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

    @Test
    func inlineSyscallPatcherThinAndFatRoundTripAndExclusions() throws {
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
        #expect(res1.modified)
        #expect(res1.patchedSiteCount == 3)
        #expect(Set(res1.modifiedBinaryURLs.map { $0.lastPathComponent }) == ["TestApp", "Helper"])

        let mainPerms = (try fm.attributesOfItem(atPath: mainExecURL.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mainPerms == 0o755)
        for off in mainSynth.codeSvcFileOffsets {
            #expect(try readUInt32LE(from: mainExecURL, at: off) == InlineSyscallPatcher.brkInstruction)
        }
        #expect(
            try readUInt32LE(from: mainExecURL, at: mainSynth.dataInCodeSvcFileOffset)
                == InlineSyscallPatcher.svcInstruction
        )
        #expect(
            try readUInt32LE(from: mainExecURL, at: mainSynth.dataConstSvcFileOffset)
                == InlineSyscallPatcher.svcInstruction
        )

        let fatSvcOff = fatDylib.arm64SliceOffset + dylibSynth.codeSvcFileOffsets[0]
        let fatDICOOff = fatDylib.arm64SliceOffset + dylibSynth.dataInCodeSvcFileOffset
        let fatConstOff = fatDylib.arm64SliceOffset + dylibSynth.dataConstSvcFileOffset
        #expect(try readUInt32LE(from: helperURL, at: fatSvcOff) == InlineSyscallPatcher.brkInstruction)
        #expect(try readUInt32LE(from: helperURL, at: fatDICOOff) == InlineSyscallPatcher.svcInstruction)
        #expect(try readUInt32LE(from: helperURL, at: fatConstOff) == InlineSyscallPatcher.svcInstruction)

        #expect(
            try readUInt32LE(from: excludedURL, at: dylibSynth.codeSvcFileOffsets[0])
                == InlineSyscallPatcher.svcInstruction
        )

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SVCPatchManifest.self, from: manifestData)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.bundleIdentifier == "com.example.svc")
        #expect(manifest.originalInstruction == InlineSyscallPatcher.svcInstruction)
        #expect(manifest.patchInstruction == InlineSyscallPatcher.brkInstruction)
        #expect(manifest.files.count == 2)
        let mainManifestEntry = try #require(manifest.files.first { $0.relativePath == "TestApp" })
        #expect(mainManifestEntry.sites.map { $0.vmOffset } == mainSynth.codeSvcVMOffsets)

        let res2 = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(!res2.modified)
        #expect(res2.modifiedBinaryURLs.isEmpty)
        #expect(res2.patchedSiteCount == 3)

        let revert1 = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: false
        )
        #expect(revert1.modified)
        #expect(revert1.patchedSiteCount == 0)
        #expect(!fm.fileExists(atPath: manifestURL.path))
        #expect(try Data(contentsOf: mainExecURL) == mainSynth.data)
        #expect(try Data(contentsOf: helperURL) == fatDylib.data)

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
        #expect(!resAfterResign.modified)

        let revertAfterResign = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.svc",
            manifestURL: manifestURL,
            enabled: false
        )
        #expect(revertAfterResign.modified)
        #expect(!fm.fileExists(atPath: manifestURL.path))
        for off in mainSynth.codeSvcFileOffsets {
            #expect(try readUInt32LE(from: mainExecURL, at: off) == InlineSyscallPatcher.svcInstruction)
        }
    }

    private func buildFatBinaryWithArm64EAndArm64(
        arm64eSlice: Data,
        arm64Slice: Data
    ) -> (data: Data, arm64eOffset: Int, arm64Offset: Int) {
        let arm64eOffset = 0x4000
        let arm64Offset = 0x8000
        var fat = Data(count: arm64Offset + arm64Slice.count)
        var header = fat_header(magic: FAT_MAGIC.bigEndian, nfat_arch: UInt32(2).bigEndian)
        let arm64eSubtype = UInt32(bitPattern: CPU_SUBTYPE_ARM64E) | 0x8000_0000
        var arm64eArch = fat_arch(
            cputype: Int32(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: Int32(bitPattern: arm64eSubtype.bigEndian),
            offset: UInt32(arm64eOffset).bigEndian,
            size: UInt32(arm64eSlice.count).bigEndian,
            align: UInt32(14).bigEndian
        )
        var arm64Arch = fat_arch(
            cputype: Int32(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: Int32(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_ARM64_ALL).bigEndian),
            offset: UInt32(arm64Offset).bigEndian,
            size: UInt32(arm64Slice.count).bigEndian,
            align: UInt32(14).bigEndian
        )

        var cursor = 0
        withUnsafeBytes(of: &header) {
            fat.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &arm64eArch) {
            fat.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &arm64Arch) {
            fat.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        fat.replaceSubrange(arm64eOffset..<(arm64eOffset + arm64eSlice.count), with: arm64eSlice)
        fat.replaceSubrange(arm64Offset..<(arm64Offset + arm64Slice.count), with: arm64Slice)
        return (fat, arm64eOffset, arm64Offset)
    }

    @Test
    func inlineSyscallPatcherCorruptManifestRecoveryAndArm64SliceDeduplication() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("svc-recovery-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("FatApp.app", isDirectory: true)
        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.fat",
                "CFBundleExecutable": "FatApp"
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: appURL.appendingPathComponent("Info.plist"))

        let arm64eSynth = buildSyntheticArm64BinaryWithSVC(
            filetype: UInt32(MH_EXECUTE),
            textSegmentVMAddr: 0x1_0000_0000,
            codeSvcCount: 1
        )
        let arm64Synth = buildSyntheticArm64BinaryWithSVC(
            filetype: UInt32(MH_EXECUTE),
            textSegmentVMAddr: 0x1_0000_0000,
            codeSvcCount: 2
        )
        let fat = buildFatBinaryWithArm64EAndArm64(arm64eSlice: arm64eSynth.data, arm64Slice: arm64Synth.data)
        let execURL = appURL.appendingPathComponent("FatApp")
        try fat.data.write(to: execURL)

        let manifestURL = root.appendingPathComponent("SVCPatches/com.example.fat.json")
        try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{corrupt-json".utf8).write(to: manifestURL)

        let recoveryResult = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.fat",
            manifestURL: manifestURL,
            enabled: false
        )
        #expect(!recoveryResult.modified)
        #expect(recoveryResult.patchedSiteCount == 0)
        #expect(!fm.fileExists(atPath: manifestURL.path))

        let patchResult = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.fat",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(patchResult.modified)
        #expect(patchResult.patchedSiteCount == 2)

        let manifest = try JSONDecoder().decode(SVCPatchManifest.self, from: Data(contentsOf: manifestURL))
        let entry = try #require(manifest.files.first)
        #expect(entry.sites.count == 2)
        #expect(entry.sites.allSatisfy { $0.sliceOffset == UInt64(fat.arm64Offset) })

        for off in arm64Synth.codeSvcFileOffsets {
            #expect(
                try readUInt32LE(from: execURL, at: fat.arm64Offset + off)
                    == InlineSyscallPatcher.brkInstruction
            )
        }
        #expect(
            try readUInt32LE(from: execURL, at: fat.arm64eOffset + arm64eSynth.codeSvcFileOffsets[0])
                == InlineSyscallPatcher.svcInstruction
        )

        let secondApply = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.fat",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(!secondApply.modified)

        let revertResult = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.fat",
            manifestURL: manifestURL,
            enabled: false
        )
        #expect(revertResult.modified)
        #expect(try Data(contentsOf: execURL) == fat.data)
    }

    @Test
    func playToolsRemoveFromAppRevertsSVCPatches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("playtools-remove-svc-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("Sample.app", isDirectory: true)
        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.removept",
                "CFBundleExecutable": "Sample"
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: appURL.appendingPathComponent("Info.plist"))

        let synth = buildSyntheticArm64BinaryWithSVC(
            filetype: UInt32(MH_EXECUTE),
            textSegmentVMAddr: 0x1_0000_0000,
            codeSvcCount: 2
        )
        let execURL = appURL.appendingPathComponent("Sample")
        try synth.data.write(to: execURL)

        let manifestURL = root.appendingPathComponent("SVCPatches/com.example.removept.json")
        let applyResult = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.removept",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(applyResult.modified)
        #expect(fm.fileExists(atPath: manifestURL.path))
        for off in synth.codeSvcFileOffsets {
            #expect(try readUInt32LE(from: execURL, at: off) == InlineSyscallPatcher.brkInstruction)
        }

        let signedApp = Mutex(false)
        await PlayTools.removeFromApp(
            execURL,
            appBundleURL: appURL,
            bundleIdentifier: "com.example.removept",
            svcManifestURL: manifestURL,
            signMacho: { _ in },
            signApp: { _ in signedApp.withLock { $0 = true } }
        )

        #expect(signedApp.withLock { $0 })
        #expect(!fm.fileExists(atPath: manifestURL.path))
        for off in synth.codeSvcFileOffsets {
            #expect(try readUInt32LE(from: execURL, at: off) == InlineSyscallPatcher.svcInstruction)
        }
    }

    @Test
    func machOByteSwapHelpersAreExactInvolutions() {
        var fatHdr = fat_header(magic: 0x1234_5678, nfat_arch: 0x0102_0304)
        let origFatHdr = fatHdr
        MachOByteSwap.swapFatHeader(&fatHdr)
        #expect(fatHdr.magic == origFatHdr.magic.byteSwapped)
        #expect(fatHdr.nfat_arch == origFatHdr.nfat_arch.byteSwapped)
        MachOByteSwap.swapFatHeader(&fatHdr)
        #expect(fatHdr.magic == origFatHdr.magic && fatHdr.nfat_arch == origFatHdr.nfat_arch)

        var fatArch = fat_arch(cputype: 1, cpusubtype: 2, offset: 3, size: 4, align: 5)
        let origFatArch = fatArch
        MachOByteSwap.swapFatArch(&fatArch)
        #expect(fatArch.offset == UInt32(3).byteSwapped && fatArch.size == UInt32(4).byteSwapped)
        MachOByteSwap.swapFatArch(&fatArch)
        #expect(fatArch.cputype == origFatArch.cputype && fatArch.align == origFatArch.align)

        var fatArch64 = fat_arch_64(cputype: 1, cpusubtype: 2, offset: 3, size: 4, align: 5, reserved: 6)
        MachOByteSwap.swapFatArch64(&fatArch64)
        #expect(fatArch64.reserved == UInt32(6).byteSwapped && fatArch64.size == UInt64(4).byteSwapped)
        MachOByteSwap.swapFatArch64(&fatArch64)
        #expect(fatArch64.reserved == 6 && fatArch64.size == 4)

        var mh64 = mach_header_64(magic: MH_MAGIC_64, cputype: CPU_TYPE_ARM64, cpusubtype: 0,
                                  filetype: UInt32(MH_EXECUTE), ncmds: 7, sizeofcmds: 256, flags: 9, reserved: 11)
        MachOByteSwap.swapMachHeader64(&mh64)
        #expect(mh64.magic == MH_CIGAM_64 && mh64.ncmds == UInt32(7).byteSwapped)
        MachOByteSwap.swapMachHeader64(&mh64)
        #expect(mh64.magic == MH_MAGIC_64 && mh64.ncmds == 7 && mh64.reserved == 11)

        var lc = load_command(cmd: UInt32(LC_LOAD_DYLIB), cmdsize: 32)
        MachOByteSwap.swapLoadCommand(&lc)
        #expect(lc.cmd == UInt32(LC_LOAD_DYLIB).byteSwapped && lc.cmdsize == UInt32(32).byteSwapped)
        MachOByteSwap.swapLoadCommand(&lc)
        #expect(lc.cmd == UInt32(LC_LOAD_DYLIB) && lc.cmdsize == 32)

        var seg64 = segment_command_64(
            cmd: UInt32(LC_SEGMENT_64), cmdsize: 72, segname: appendFixed16String("__TEXT"),
            vmaddr: 0x1000, vmsize: 0x2000, fileoff: 0x100, filesize: 0x200,
            maxprot: 5, initprot: 3, nsects: 1, flags: 2
        )
        MachOByteSwap.swapSegmentCommand64(&seg64)
        #expect(seg64.vmaddr == UInt64(0x1000).byteSwapped && seg64.nsects == UInt32(1).byteSwapped)
        MachOByteSwap.swapSegmentCommand64(&seg64)
        #expect(seg64.vmaddr == 0x1000 && seg64.nsects == 1 && seg64.flags == 2)

        var sect64 = section_64(
            sectname: appendFixed16String("__text"), segname: appendFixed16String("__TEXT"),
            addr: 0x10, size: 0x20, offset: 0x30, align: 4, reloff: 5, nreloc: 6, flags: 7,
            reserved1: 8, reserved2: 9, reserved3: 10
        )
        MachOByteSwap.swapSection64(&sect64)
        #expect(sect64.addr == UInt64(0x10).byteSwapped && sect64.reserved3 == UInt32(10).byteSwapped)
        MachOByteSwap.swapSection64(&sect64)
        #expect(sect64.addr == 0x10 && sect64.reserved3 == 10)

        var link = linkedit_data_command(cmd: UInt32(LC_CODE_SIGNATURE), cmdsize: 16, dataoff: 0x400, datasize: 0x80)
        MachOByteSwap.swapLinkeditDataCommand(&link)
        #expect(link.dataoff == UInt32(0x400).byteSwapped)
        MachOByteSwap.swapLinkeditDataCommand(&link)
        #expect(link.dataoff == 0x400 && link.datasize == 0x80)

        var sym = symtab_command(cmd: UInt32(LC_SYMTAB), cmdsize: 24, symoff: 1, nsyms: 2, stroff: 3, strsize: 4)
        MachOByteSwap.swapSymtabCommand(&sym)
        #expect(sym.nsyms == UInt32(2).byteSwapped)
        MachOByteSwap.swapSymtabCommand(&sym)
        #expect(sym.nsyms == 2 && sym.strsize == 4)

        var dyld = dyld_info_command(
            cmd: UInt32(LC_DYLD_INFO_ONLY), cmdsize: 48, rebase_off: 1, rebase_size: 2,
            bind_off: 3, bind_size: 4, weak_bind_off: 5, weak_bind_size: 6,
            lazy_bind_off: 7, lazy_bind_size: 8, export_off: 9, export_size: 10
        )
        MachOByteSwap.swapDyldInfoCommand(&dyld)
        #expect(dyld.export_size == UInt32(10).byteSwapped)
        MachOByteSwap.swapDyldInfoCommand(&dyld)
        #expect(dyld.export_size == 10 && dyld.rebase_off == 1)

        var dylib = dylib_command(
            cmd: UInt32(LC_LOAD_DYLIB), cmdsize: 32,
            dylib: dylib(name: lc_str(offset: 24), timestamp: 1, current_version: 2, compatibility_version: 3)
        )
        MachOByteSwap.swapDylibCommand(&dylib)
        #expect(dylib.dylib.name.offset == UInt32(24).byteSwapped)
        MachOByteSwap.swapDylibCommand(&dylib)
        #expect(dylib.dylib.name.offset == 24 && dylib.dylib.compatibility_version == 3)

        var build = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION), cmdsize: 24, platform: UInt32(PLATFORM_MACCATALYST),
            minos: 0x000F_0000, sdk: 0x000F_0000, ntools: 0
        )
        MachOByteSwap.swapBuildVersionCommand(&build)
        #expect(build.platform == UInt32(PLATFORM_MACCATALYST).byteSwapped)
        MachOByteSwap.swapBuildVersionCommand(&build)
        #expect(build.platform == UInt32(PLATFORM_MACCATALYST))

        var enc = encryption_info_command_64(
            cmd: UInt32(LC_ENCRYPTION_INFO_64), cmdsize: 24, cryptoff: 1, cryptsize: 2, cryptid: 3, pad: 4
        )
        MachOByteSwap.swapEncryptionCommand64(&enc)
        #expect(enc.cryptid == UInt32(3).byteSwapped && enc.pad == UInt32(4).byteSwapped)
        MachOByteSwap.swapEncryptionCommand64(&enc)
        #expect(enc.cryptid == 3 && enc.pad == 4)
    }

    @Test
    func inlineSyscallPatcherIgnoresNonTextExecSegmentAndRejectsCorruptManifest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("svc-seg-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("SegApp.app", isDirectory: true)
        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "SegApp"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: appURL.appendingPathComponent("Info.plist"))

        // Build arm64 binary with __TEXT (1 svc) + executable __CUSTOM segment (1 svc)
        let textFileStart = 0x1000
        let customFileStart = 0x2000
        let totalSize = 0x3000
        let svcWord = InlineSyscallPatcher.svcInstruction
        let retWord: UInt32 = 0xD65F_03C0

        var textSeg = segment_command_64(
            cmd: UInt32(LC_SEGMENT_64),
            cmdsize: UInt32(MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size),
            segname: appendFixed16String("__TEXT"),
            vmaddr: 0x1_0000_0000,
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
            addr: 0x1_0000_0000 + UInt64(textFileStart),
            size: 8,
            offset: UInt32(textFileStart),
            align: 2,
            reloff: 0,
            nreloc: 0,
            flags: UInt32(S_ATTR_PURE_INSTRUCTIONS) | UInt32(S_ATTR_SOME_INSTRUCTIONS),
            reserved1: 0,
            reserved2: 0,
            reserved3: 0
        )
        var customSeg = segment_command_64(
            cmd: UInt32(LC_SEGMENT_64),
            cmdsize: UInt32(MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size),
            segname: appendFixed16String("__CUSTOM"),
            vmaddr: 0x1_0000_2000,
            vmsize: 0x1000,
            fileoff: UInt64(customFileStart),
            filesize: 0x1000,
            maxprot: VM_PROT_READ | VM_PROT_EXECUTE,
            initprot: VM_PROT_READ | VM_PROT_EXECUTE,
            nsects: 1,
            flags: 0
        )
        var customSect = section_64(
            sectname: appendFixed16String("__cust_exec"),
            segname: appendFixed16String("__CUSTOM"),
            addr: 0x1_0000_2000,
            size: 8,
            offset: UInt32(customFileStart),
            align: 2,
            reloff: 0,
            nreloc: 0,
            flags: UInt32(S_ATTR_PURE_INSTRUCTIONS) | UInt32(S_ATTR_SOME_INSTRUCTIONS),
            reserved1: 0,
            reserved2: 0,
            reserved3: 0
        )
        var mh = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 2,
            sizeofcmds: textSeg.cmdsize + customSeg.cmdsize,
            flags: 0,
            reserved: 0
        )
        var bin = Data(count: totalSize)
        var cursor = 0
        withUnsafeBytes(of: &mh) {
            bin.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &textSeg) {
            bin.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &textSect) {
            bin.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &customSeg) {
            bin.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }
        withUnsafeBytes(of: &customSect) {
            bin.replaceSubrange(cursor..<(cursor + $0.count), with: $0)
            cursor += $0.count
        }

        var w0 = svcWord.littleEndian
        var w1 = retWord.littleEndian
        withUnsafeBytes(of: &w0) { bin.replaceSubrange(textFileStart..<(textFileStart + 4), with: $0) }
        withUnsafeBytes(of: &w1) { bin.replaceSubrange((textFileStart + 4)..<(textFileStart + 8), with: $0) }
        withUnsafeBytes(of: &w0) { bin.replaceSubrange(customFileStart..<(customFileStart + 4), with: $0) }
        withUnsafeBytes(of: &w1) { bin.replaceSubrange((customFileStart + 4)..<(customFileStart + 8), with: $0) }

        let execURL = appURL.appendingPathComponent("SegApp")
        try bin.write(to: execURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let corruptManifestURL = root.appendingPathComponent("SVCPatches/corrupt.json")
        try fm.createDirectory(at: corruptManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-valid-json".utf8).write(to: corruptManifestURL)

        let res = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.seg",
            manifestURL: corruptManifestURL,
            enabled: true
        )
        #expect(res.modified)
        #expect(res.patchedSiteCount == 1)
        #expect(try readUInt32LE(from: execURL, at: textFileStart) == InlineSyscallPatcher.brkInstruction)
        #expect(try readUInt32LE(from: execURL, at: customFileStart) == svcWord)
    }

    @Test
    func svcScanCacheFastPathsZeroSiteAndPatchedBundlesWithoutPollutingSVCPatches() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("svc-cache-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("NoSvc.app", isDirectory: true)
        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.nosvc",
                "CFBundleExecutable": "NoSvc"
            ],
            format: .xml,
            options: 0
        ).write(to: appURL.appendingPathComponent("Info.plist"))

        let cleanSynth = buildSyntheticArm64BinaryWithSVC(filetype: UInt32(MH_EXECUTE), codeSvcCount: 1)
        var cleanData = cleanSynth.data
        var nopLE = UInt32(0xD503_201F).littleEndian
        let nopBytes = withUnsafeBytes(of: &nopLE) { Array($0) }
        for offset in cleanSynth.codeSvcFileOffsets {
            cleanData.replaceSubrange(offset..<(offset + 4), with: nopBytes)
        }
        let execURL = appURL.appendingPathComponent("NoSvc")
        try cleanData.write(to: execURL)

        let svcDir = root.appendingPathComponent("SVCPatches", isDirectory: true)
        let manifestURL = svcDir.appendingPathComponent("com.example.nosvc.json")
        let cacheURL = InlineSyscallPatcher.scanCacheURL(for: manifestURL, bundleIdentifier: "com.example.nosvc")

        let first = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.nosvc",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(!first.modified && first.patchedSiteCount == 0)
        #expect(!fm.fileExists(atPath: manifestURL.path))
        #expect(fm.fileExists(atPath: cacheURL.path))

        let svcDirItems = (try? fm.contentsOfDirectory(atPath: svcDir.path)) ?? []
        #expect(svcDirItems.isEmpty)

        // Cached 0-site fast path skips instruction scan completely on repeat launch.
        let second = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.nosvc",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(!second.modified && second.patchedSiteCount == 0)

        // Modifying binary size/mtime invalidates scan cache cleanly.
        let dirtySynth = buildSyntheticArm64BinaryWithSVC(filetype: UInt32(MH_EXECUTE), codeSvcCount: 1)
        try dirtySynth.data.write(to: execURL)
        let third = try InlineSyscallPatcher.reconcile(
            appBundleURL: appURL,
            bundleIdentifier: "com.example.nosvc",
            manifestURL: manifestURL,
            enabled: true
        )
        #expect(third.modified && third.patchedSiteCount == 1)
        #expect(fm.fileExists(atPath: manifestURL.path))
    }

    @Test
    func playToolsEnsureSystemInstallSkipsUnchangedAndReinstallsOnChange() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pt-stamp-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bundledFW = root.appendingPathComponent("Bundled/PlayTools.framework", isDirectory: true)
        let installedFW = root.appendingPathComponent("Installed/PlayTools.framework", isDirectory: true)
        let akMacOS = bundledFW.appendingPathComponent("PlugIns/AKInterface.bundle/Contents/MacOS", isDirectory: true)
        let resources = bundledFW.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: akMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        try Data("pt-v1".utf8).write(to: bundledFW.appendingPathComponent("PlayTools"))
        try Data("ak-v1".utf8).write(to: akMacOS.appendingPathComponent("AKInterface"))
        try Data("plist-v1".utf8).write(to: resources.appendingPathComponent("Info.plist"))

        var validations = 0
        let firstInstalled = try PlayTools.ensureSystemInstall(
            bundledFrameworkURL: bundledFW,
            installedFrameworkURL: installedFW,
            validator: { _ in validations += 1 }
        )
        #expect(firstInstalled && validations == 1)

        let secondInstalled = try PlayTools.ensureSystemInstall(
            bundledFrameworkURL: bundledFW,
            installedFrameworkURL: installedFW,
            validator: { _ in validations += 1 }
        )
        #expect(!secondInstalled && validations == 1)

        try Data("pt-v2".utf8).write(to: bundledFW.appendingPathComponent("PlayTools"))
        let thirdInstalled = try PlayTools.ensureSystemInstall(
            bundledFrameworkURL: bundledFW,
            installedFrameworkURL: installedFW,
            validator: { _ in validations += 1 }
        )
        #expect(thirdInstalled && validations == 2)
    }
}
