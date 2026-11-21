import Foundation
import MachO
import XCTest
@testable import PlayCover

final class MachoTests: XCTestCase {
    private var tempDir: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMachOTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeTempFile(named name: String, data: Data) throws -> URL {
        let dir = try XCTUnwrap(tempDir)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Synthetic Mach-O Fixture Builders

    private func makeLoadDylibCommand(cmd: UInt32 = UInt32(LC_LOAD_DYLIB), path: String) -> Data {
        let fixedSize = MemoryLayout<dylib_command>.size
        let strBytes = Array(path.utf8)
        let padding = 8 - (strBytes.count % 8)
        let cmdSize = fixedSize + strBytes.count + padding
        var command = dylib_command(
            cmd: cmd,
            cmdsize: UInt32(cmdSize),
            dylib: dylib(
                name: lc_str(offset: UInt32(fixedSize)),
                timestamp: 2,
                current_version: 0x0001_0000,
                compatibility_version: 0x0001_0000
            )
        )
        var data = Data(bytes: &command, count: fixedSize)
        data.append(contentsOf: strBytes)
        data.append(Data(count: padding))
        return data
    }

    private func makeBuildVersionCommand(platform: UInt32) -> Data {
        var cmd = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: UInt32(MemoryLayout<build_version_command>.size),
            platform: platform,
            minos: 0x000F_0000,
            sdk: 0x000F_0000,
            ntools: 0
        )
        return Data(bytes: &cmd, count: MemoryLayout<build_version_command>.size)
    }

    private func makeVersionMinIphoneOSCommand() -> Data {
        var cmd = version_min_command(
            cmd: UInt32(LC_VERSION_MIN_IPHONEOS),
            cmdsize: UInt32(MemoryLayout<version_min_command>.size),
            version: 0x000F_0000,
            sdk: 0x000F_0000
        )
        return Data(bytes: &cmd, count: MemoryLayout<version_min_command>.size)
    }

    private func makeEncryptionInfoCommand(cryptid: UInt32) -> Data {
        var cmd = encryption_info_command_64(
            cmd: UInt32(LC_ENCRYPTION_INFO_64),
            cmdsize: UInt32(MemoryLayout<encryption_info_command_64>.size),
            cryptoff: 0x1000,
            cryptsize: 0x1000,
            cryptid: cryptid,
            pad: 0
        )
        return Data(bytes: &cmd, count: MemoryLayout<encryption_info_command_64>.size)
    }

    private func makeSegmentTextCommand(textOffset: UInt32, fileSize: UInt64) -> Data {
        let segSize = MemoryLayout<segment_command_64>.size
        let sectSize = MemoryLayout<section_64>.size
        let totalCmdSize = UInt32(segSize + sectSize)
        var data = Data(count: Int(totalCmdSize))

        func write32(_ offset: Int, _ val: UInt32) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        func write64(_ offset: Int, _ val: UInt64) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + 8), with: $0) }
        }
        func writeStr16(_ offset: Int, _ str: String) {
            let bytes = Array(str.utf8.prefix(16))
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }

        // segment_command_64
        write32(0, UInt32(LC_SEGMENT_64))
        write32(4, totalCmdSize)
        writeStr16(8, "__TEXT")
        write64(24, 0x1_0000_0000) // vmaddr
        write64(32, fileSize)      // vmsize
        write64(40, 0)             // fileoff
        write64(48, fileSize)      // filesize
        write32(56, 5)             // maxprot
        write32(60, 5)             // initprot
        write32(64, 1)             // nsects
        write32(68, 0)             // flags

        // section_64 (__text)
        let sOff = segSize
        writeStr16(sOff + 0, "__text")
        writeStr16(sOff + 16, "__TEXT")
        write64(sOff + 32, 0x1_0000_0000 + UInt64(textOffset)) // addr
        write64(sOff + 40, 16)                                  // size (> 0 so earliestContentOffset tracks it)
        write32(sOff + 48, textOffset)                          // offset
        write32(sOff + 52, 2)                                   // align
        write32(sOff + 56, 0)                                   // reloff
        write32(sOff + 60, 0)                                   // nreloc
        write32(sOff + 64, 0x8000_0400)                         // flags

        return data
    }

    private func makeThinArm64MachO(
        extraCommands: [Data] = [],
        tightPadding: Bool = false,
        totalFileSize: Int = 0x2000
    ) -> Data {
        let headerSize = MemoryLayout<mach_header_64>.size
        let segFixedSize = MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size
        let extraBytes = extraCommands.reduce(0) { $0 + $1.count }
        let sizeofcmds = segFixedSize + extraBytes
        let textOffset = UInt32(tightPadding ? (headerSize + sizeofcmds) : 0x1000)
        let effectiveTotal = max(totalFileSize, Int(textOffset) + 64)

        var header = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: UInt32(1 + extraCommands.count),
            sizeofcmds: UInt32(sizeofcmds),
            flags: UInt32(MH_NOUNDEFS | MH_DYLDLINK),
            reserved: 0
        )

        var data = Data(count: effectiveTotal)
        withUnsafeBytes(of: &header) { data.replaceSubrange(0..<headerSize, with: $0) }

        var cursor = headerSize
        let segCmd = makeSegmentTextCommand(textOffset: textOffset, fileSize: UInt64(effectiveTotal))
        data.replaceSubrange(cursor..<(cursor + segCmd.count), with: segCmd)
        cursor += segCmd.count

        for cmd in extraCommands {
            data.replaceSubrange(cursor..<(cursor + cmd.count), with: cmd)
            cursor += cmd.count
        }
        return data
    }

    private func makeFatMachO(slices: [(cputype: cpu_type_t, cpusubtype: cpu_subtype_t, data: Data)]) -> Data {
        let fatHeaderSize = MemoryLayout<fat_header>.size
        let fatArchSize = MemoryLayout<fat_arch>.size
        let alignment = 0x1000

        var offsets: [Int] = []
        var cursor = alignment
        for slice in slices {
            offsets.append(cursor)
            let alignedSize = ((slice.data.count + alignment - 1) / alignment) * alignment
            cursor += max(alignedSize, alignment)
        }

        var output = Data(count: cursor)
        var header = fat_header(
            magic: FAT_CIGAM,
            nfat_arch: UInt32(slices.count).bigEndian
        )
        withUnsafeBytes(of: &header) { output.replaceSubrange(0..<fatHeaderSize, with: $0) }

        for (index, slice) in slices.enumerated() {
            let offset = offsets[index]
            var arch = fat_arch(
                cputype: cpu_type_t(bitPattern: UInt32(bitPattern: slice.cputype).bigEndian),
                cpusubtype: cpu_subtype_t(bitPattern: UInt32(bitPattern: slice.cpusubtype).bigEndian),
                offset: UInt32(offset).bigEndian,
                size: UInt32(slice.data.count).bigEndian,
                align: UInt32(12).bigEndian
            )
            let archOffset = fatHeaderSize + index * fatArchSize
            withUnsafeBytes(of: &arch) { output.replaceSubrange(archOffset..<(archOffset + fatArchSize), with: $0) }
            output.replaceSubrange(offset..<(offset + slice.data.count), with: slice.data)
        }

        return output
    }

    private func makeThinX86Dummy() -> Data {
        var header = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_X86_64,
            cpusubtype: CPU_SUBTYPE_X86_64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 0,
            sizeofcmds: 0,
            flags: 0,
            reserved: 0
        )
        var data = Data(count: 0x1000)
        withUnsafeBytes(of: &header) { data.replaceSubrange(0..<MemoryLayout<mach_header_64>.size, with: $0) }
        return data
    }

    // MARK: - Tests

    func testInspectArm64SliceThinAndFatAndCorrupted() throws {
        let thinData = makeThinArm64MachO(extraCommands: [
            makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))
        ])
        let thinURL = try makeTempFile(named: "thin_arm64", data: thinData)

        let thinCtx = try Macho.inspectArm64Slice(at: thinURL)
        XCTAssertFalse(thinCtx.isFat)
        XCTAssertEqual(thinCtx.sliceOffset, 0)
        XCTAssertEqual(thinCtx.sliceSize, UInt64(thinData.count))

        let fatData = makeFatMachO(slices: [
            (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, makeThinX86Dummy()),
            (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, thinData)
        ])
        let fatURL = try makeTempFile(named: "fat_universal", data: fatData)

        let fatCtx = try Macho.inspectArm64Slice(at: fatURL)
        XCTAssertTrue(fatCtx.isFat)
        XCTAssertEqual(fatCtx.sliceOffset, 0x2000)
        XCTAssertEqual(fatCtx.sliceSize, UInt64(thinData.count))

        let truncatedURL = try makeTempFile(named: "truncated", data: Data([0xCF, 0xFA, 0xED, 0xFE]))
        XCTAssertThrowsError(try Macho.inspectArm64Slice(at: truncatedURL)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        let nonMachOURL = try makeTempFile(named: "not_macho", data: Data(repeating: 0x41, count: 256))
        XCTAssertThrowsError(try Macho.inspectArm64Slice(at: nonMachOURL)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        let x86OnlyFatData = makeFatMachO(slices: [
            (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, makeThinX86Dummy())
        ])
        let x86OnlyURL = try makeTempFile(named: "fat_x86_only", data: x86OnlyFatData)
        XCTAssertThrowsError(try Macho.inspectArm64Slice(at: x86OnlyURL)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }
    }

    func testIterateLoadCommandsTraversalEarlyExitAndCorruptionGuards() throws {
        let data = makeThinArm64MachO(extraCommands: [
            makeBuildVersionCommand(platform: UInt32(PLATFORM_IOS)),
            makeLoadDylibCommand(path: "/usr/lib/libSystem.B.dylib")
        ])

        var visitedCmds: [UInt32] = []
        let endOffset = try Macho.iterateLoadCommands(binary: data) { offset, _ in
            let lc = try data.extract(load_command.self, offset: offset)
            visitedCmds.append(lc.cmd)
            return false
        }
        XCTAssertEqual(visitedCmds, [
            UInt32(LC_SEGMENT_64),
            UInt32(LC_BUILD_VERSION),
            UInt32(LC_LOAD_DYLIB)
        ])
        XCTAssertGreaterThan(endOffset, MemoryLayout<mach_header_64>.size)

        var earlyVisited: [UInt32] = []
        let earlyEnd = try Macho.iterateLoadCommands(binary: data) { offset, _ in
            let lc = try data.extract(load_command.self, offset: offset)
            earlyVisited.append(lc.cmd)
            return lc.cmd == UInt32(LC_BUILD_VERSION)
        }
        XCTAssertEqual(earlyVisited, [UInt32(LC_SEGMENT_64), UInt32(LC_BUILD_VERSION)])
        XCTAssertLessThan(earlyEnd, endOffset)

        // sizeofcmds == 0
        var zeroCmds = data
        var hdr = try zeroCmds.extract(mach_header_64.self)
        hdr.sizeofcmds = 0
        withUnsafeBytes(of: &hdr) { zeroCmds.replaceSubrange(0..<MemoryLayout<mach_header_64>.size, with: $0) }
        XCTAssertThrowsError(try Macho.iterateLoadCommands(binary: zeroCmds) { _, _ in false }) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        // sizeofcmds > binary.count
        var oversizedCmds = data
        hdr.sizeofcmds = UInt32(data.count + 1024)
        withUnsafeBytes(of: &hdr) { oversizedCmds.replaceSubrange(0..<MemoryLayout<mach_header_64>.size, with: $0) }
        XCTAssertThrowsError(try Macho.iterateLoadCommands(binary: oversizedCmds) { _, _ in false }) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        // cmdsize == 0 on first load command (must throw without Data.extract SIGTRAP)
        var zeroCmdSize = data
        let firstCmdOffset = MemoryLayout<mach_header_64>.size
        var badCmd = load_command(cmd: UInt32(LC_SEGMENT_64), cmdsize: 0)
        withUnsafeBytes(of: &badCmd) {
            zeroCmdSize.replaceSubrange(firstCmdOffset..<(firstCmdOffset + MemoryLayout<load_command>.size), with: $0)
        }
        XCTAssertThrowsError(try Macho.iterateLoadCommands(binary: zeroCmdSize) { _, _ in false }) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
    }

    func testIsMachoValidArchPlatformDetection() throws {
        let iosURL = try makeTempFile(
            named: "ios_bin",
            data: makeThinArm64MachO(extraCommands: [makeBuildVersionCommand(platform: UInt32(PLATFORM_IOS))])
        )
        XCTAssertFalse(try Macho.isMachoValidArch(iosURL))

        let catalystURL = try makeTempFile(
            named: "catalyst_bin",
            data: makeThinArm64MachO(extraCommands: [makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))])
        )
        XCTAssertTrue(try Macho.isMachoValidArch(catalystURL))

        let noVersionURL = try makeTempFile(named: "no_ver_bin", data: makeThinArm64MachO())
        XCTAssertFalse(try Macho.isMachoValidArch(noVersionURL))
    }

    func testIsMachoEncryptedDetection() throws {
        let plainURL = try makeTempFile(named: "plain_bin", data: makeThinArm64MachO())
        XCTAssertFalse(try Macho.isMachoEncrypted(atURL: plainURL))

        let decryptedURL = try makeTempFile(
            named: "decrypted_bin",
            data: makeThinArm64MachO(extraCommands: [makeEncryptionInfoCommand(cryptid: 0)])
        )
        XCTAssertFalse(try Macho.isMachoEncrypted(atURL: decryptedURL))

        let encryptedURL = try makeTempFile(
            named: "encrypted_bin",
            data: makeThinArm64MachO(extraCommands: [makeEncryptionInfoCommand(cryptid: 1)])
        )
        XCTAssertTrue(try Macho.isMachoEncrypted(atURL: encryptedURL))
    }

    func testInspectBinaryDetectsPlayToolsAndCatalyst() throws {
        let playToolsPath = "@rpath/PlayTools.framework/PlayTools"
        let untouchedURL = try makeTempFile(
            named: "untouched",
            data: makeThinArm64MachO(extraCommands: [makeBuildVersionCommand(platform: UInt32(PLATFORM_IOS))])
        )
        let untouched = try Macho.inspectBinary(atURL: untouchedURL, playToolsPath: playToolsPath)
        XCTAssertFalse(untouched.hasPlayTools)
        XCTAssertFalse(untouched.isCatalyst)

        let patchedURL = try makeTempFile(
            named: "patched",
            data: makeThinArm64MachO(extraCommands: [
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST)),
                makeLoadDylibCommand(path: playToolsPath)
            ])
        )
        let patched = try Macho.inspectBinary(atURL: patchedURL, playToolsPath: playToolsPath)
        XCTAssertTrue(patched.hasPlayTools)
        XCTAssertTrue(patched.isCatalyst)
    }

    func testInjectAndRemoveLoadCommandAndTightSpaceError() throws {
        let dylibPath = "@rpath/PlayTools.framework/PlayTools"
        let binURL = try makeTempFile(
            named: "injectable",
            data: makeThinArm64MachO(extraCommands: [
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))
            ])
        )

        let insertedFirst = try Macho.injectLoadCommand(
            at: binURL,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: dylibPath
        )
        XCTAssertTrue(insertedFirst)
        XCTAssertTrue(try Macho.inspectBinary(atURL: binURL, playToolsPath: dylibPath).hasPlayTools)

        let insertedSecond = try Macho.injectLoadCommand(
            at: binURL,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: dylibPath
        )
        XCTAssertFalse(insertedSecond)

        let removed = try Macho.removeLoadCommand(at: binURL, dylibPaths: [dylibPath])
        XCTAssertTrue(removed)
        XCTAssertFalse(try Macho.inspectBinary(atURL: binURL, playToolsPath: dylibPath).hasPlayTools)

        let removedAgain = try Macho.removeLoadCommand(at: binURL, dylibPaths: [dylibPath])
        XCTAssertFalse(removedAgain)

        let tightURL = try makeTempFile(
            named: "tight",
            data: makeThinArm64MachO(tightPadding: true)
        )
        XCTAssertThrowsError(
            try Macho.injectLoadCommand(at: tightURL, cmdType: UInt32(LC_LOAD_DYLIB), dylibPath: dylibPath)
        ) { error in
            guard case MachoCapacityError.insufficientLoadCommandSpace = error else {
                XCTFail("Expected MachoCapacityError.insufficientLoadCommandSpace, got \(error)")
                return
            }
        }
    }

    func testReplaceLibraryAndReplaceVersionCommand() throws {
        var binary = makeThinArm64MachO(extraCommands: [
            makeVersionMinIphoneOSCommand(),
            makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib")
        ])

        try Macho.replaceVersionCommand(&binary, totalSize: binary.count)
        let replacedLib = try Macho.replaceLibrary(
            &binary,
            "@rpath/libswiftUIKit.dylib",
            "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib",
            totalSize: binary.count
        )
        XCTAssertTrue(replacedLib)

        let patchedURL = try makeTempFile(named: "replaced", data: binary)
        XCTAssertTrue(try Macho.isMachoValidArch(patchedURL))

        var loadedPaths: [String] = []
        _ = try Macho.iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let lc = try binary.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
            if lc.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCmd = try binary.extract(
                    dylib_command.self,
                    offset: offset,
                    swap: shouldSwap ? swap_dylib_command : nil
                )
                loadedPaths.append(String(
                    data: binary,
                    offset: offset,
                    commandSize: Int(dylibCmd.cmdsize),
                    loadCommandString: dylibCmd.dylib.name
                ))
            }
            return false
        }
        XCTAssertEqual(loadedPaths, ["/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib"])
        XCTAssertFalse(try Macho.replaceLibrary(&binary, "@rpath/Missing.dylib", "/usr/lib/Missing.dylib"))
    }

    func testStripBinaryExtractsArm64AndThrowsWhenMissing() throws {
        let arm64Slice = makeThinArm64MachO(extraCommands: [
            makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))
        ])
        var fat = makeFatMachO(slices: [
            (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, makeThinX86Dummy()),
            (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, arm64Slice)
        ])

        try Macho.stripBinary(&fat)
        XCTAssertEqual(fat, arm64Slice)

        var x86OnlyFat = makeFatMachO(slices: [
            (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, makeThinX86Dummy())
        ])
        XCTAssertThrowsError(try Macho.stripBinary(&x86OnlyFat)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }
    }

    // MARK: - Adversarial Hardening Tests (M-01..M-05)

    private func makeFat64MachO(
        slices: [(cputype: cpu_type_t, cpusubtype: cpu_subtype_t, data: Data)]
    ) -> Data {
        let fatHeaderSize = MemoryLayout<fat_header>.size
        let fatArchSize = MemoryLayout<fat_arch_64>.size
        let alignment = 0x1000

        var offsets: [Int] = []
        var cursor = alignment
        for slice in slices {
            offsets.append(cursor)
            let alignedSize = ((slice.data.count + alignment - 1) / alignment) * alignment
            cursor += max(alignedSize, alignment)
        }

        var output = Data(count: cursor)
        var header = fat_header(
            magic: FAT_CIGAM_64,
            nfat_arch: UInt32(slices.count).bigEndian
        )
        withUnsafeBytes(of: &header) { output.replaceSubrange(0..<fatHeaderSize, with: $0) }

        for (index, slice) in slices.enumerated() {
            let offset = offsets[index]
            var arch = fat_arch_64(
                cputype: cpu_type_t(bitPattern: UInt32(bitPattern: slice.cputype).bigEndian),
                cpusubtype: cpu_subtype_t(bitPattern: UInt32(bitPattern: slice.cpusubtype).bigEndian),
                offset: UInt64(offset).bigEndian,
                size: UInt64(slice.data.count).bigEndian,
                align: UInt32(12).bigEndian,
                reserved: 0
            )
            let archOffset = fatHeaderSize + index * fatArchSize
            withUnsafeBytes(of: &arch) { output.replaceSubrange(archOffset..<(archOffset + fatArchSize), with: $0) }
            output.replaceSubrange(offset..<(offset + slice.data.count), with: slice.data)
        }

        return output
    }

    private func makeSwappedCigam64Arm64MachO(extraCommands: [Data] = []) throws -> Data {
        var data = makeThinArm64MachO(extraCommands: extraCommands)
        var header = try data.extract(mach_header_64.self)
        let ncmds = header.ncmds
        let headerSize = MemoryLayout<mach_header_64>.size

        var cursor = headerSize
        for _ in 0..<ncmds {
            let lc = try data.extract(load_command.self, offset: cursor)
            let cmdSize = Int(lc.cmdsize)
            switch lc.cmd {
            case UInt32(LC_SEGMENT_64):
                var seg = try data.extract(segment_command_64.self, offset: cursor)
                let nsects = seg.nsects
                swap_segment_command_64(&seg, NX_BigEndian)
                withUnsafeBytes(of: &seg) {
                    data.replaceSubrange(cursor..<(cursor + MemoryLayout<segment_command_64>.size), with: $0)
                }
                var sectCursor = cursor + MemoryLayout<segment_command_64>.size
                for _ in 0..<nsects {
                    var sect = try data.extract(section_64.self, offset: sectCursor)
                    swap_section_64(&sect, 1, NX_BigEndian)
                    withUnsafeBytes(of: &sect) {
                        data.replaceSubrange(sectCursor..<(sectCursor + MemoryLayout<section_64>.size), with: $0)
                    }
                    sectCursor += MemoryLayout<section_64>.size
                }
            case UInt32(LC_BUILD_VERSION):
                var bv = try data.extract(build_version_command.self, offset: cursor)
                swap_build_version_command(&bv, NX_BigEndian)
                withUnsafeBytes(of: &bv) {
                    data.replaceSubrange(cursor..<(cursor + MemoryLayout<build_version_command>.size), with: $0)
                }
            case UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, UInt32(LC_REEXPORT_DYLIB), UInt32(LC_LOAD_UPWARD_DYLIB):
                var dylibCmd = try data.extract(dylib_command.self, offset: cursor)
                swap_dylib_command(&dylibCmd, NX_BigEndian)
                withUnsafeBytes(of: &dylibCmd) {
                    data.replaceSubrange(cursor..<(cursor + MemoryLayout<dylib_command>.size), with: $0)
                }
            default:
                var rawLC = lc
                swap_load_command(&rawLC, NX_BigEndian)
                withUnsafeBytes(of: &rawLC) {
                    data.replaceSubrange(cursor..<(cursor + MemoryLayout<load_command>.size), with: $0)
                }
            }
            cursor += cmdSize
        }

        swap_mach_header_64(&header, NX_BigEndian)
        withUnsafeBytes(of: &header) { data.replaceSubrange(0..<headerSize, with: $0) }
        return data
    }

    func testStripBinaryMalformedFatAndTruncatedSlicesThrow() {
        var tiny = Data([0xCA, 0xFE])
        XCTAssertThrowsError(try Macho.stripBinary(&tiny)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }

        var badNfatHeader = fat_header(magic: FAT_CIGAM, nfat_arch: UInt32(100).bigEndian)
        var badNfatData = Data(count: MemoryLayout<fat_header>.size)
        withUnsafeBytes(of: &badNfatHeader) { badNfatData.replaceSubrange(0..<8, with: $0) }
        XCTAssertThrowsError(try Macho.stripBinary(&badNfatData)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }

        var oobHeader = fat_header(magic: FAT_CIGAM, nfat_arch: UInt32(1).bigEndian)
        var oobArch = fat_arch(
            cputype: cpu_type_t(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: cpu_subtype_t(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_ARM64_ALL).bigEndian),
            offset: UInt32(0x1000).bigEndian,
            size: UInt32(0x1000).bigEndian,
            align: UInt32(12).bigEndian
        )
        var oobData = Data(count: MemoryLayout<fat_header>.size + MemoryLayout<fat_arch>.size)
        withUnsafeBytes(of: &oobHeader) { oobData.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: &oobArch) { oobData.replaceSubrange(8..<28, with: $0) }
        XCTAssertThrowsError(try Macho.stripBinary(&oobData)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }

        var overflowArch = fat_arch(
            cputype: cpu_type_t(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: cpu_subtype_t(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_ARM64_ALL).bigEndian),
            offset: UInt32(0xFFFF_F000).bigEndian,
            size: UInt32(0x2000).bigEndian,
            align: UInt32(12).bigEndian
        )
        var overflowData = Data(count: MemoryLayout<fat_header>.size + MemoryLayout<fat_arch>.size)
        withUnsafeBytes(of: &oobHeader) { overflowData.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: &overflowArch) { overflowData.replaceSubrange(8..<28, with: $0) }
        XCTAssertThrowsError(try Macho.stripBinary(&overflowData)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }

        var fat64Header = fat_header(magic: FAT_CIGAM_64, nfat_arch: UInt32(1).bigEndian)
        var fat64OverflowArch = fat_arch_64(
            cputype: cpu_type_t(bitPattern: UInt32(bitPattern: CPU_TYPE_ARM64).bigEndian),
            cpusubtype: cpu_subtype_t(bitPattern: UInt32(bitPattern: CPU_SUBTYPE_ARM64_ALL).bigEndian),
            offset: UInt64(0xFFFF_FFFF_FFFF_F000).bigEndian,
            size: UInt64(0x2000).bigEndian,
            align: UInt32(12).bigEndian,
            reserved: 0
        )
        var fat64OverflowData = Data(count: MemoryLayout<fat_header>.size + MemoryLayout<fat_arch_64>.size)
        withUnsafeBytes(of: &fat64Header) { fat64OverflowData.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: &fat64OverflowArch) { fat64OverflowData.replaceSubrange(8..<40, with: $0) }
        XCTAssertThrowsError(try Macho.stripBinary(&fat64OverflowData)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }
    }

    func testTruncatedLoadCommandStructSizesThrowCorrupted() throws {
        func makeSingleTruncatedCmdBinary(cmd: UInt32, cmdsize: UInt32) -> Data {
            let headerSize = MemoryLayout<mach_header_64>.size
            var header = mach_header_64(
                magic: MH_MAGIC_64,
                cputype: CPU_TYPE_ARM64,
                cpusubtype: CPU_SUBTYPE_ARM64_ALL,
                filetype: UInt32(MH_EXECUTE),
                ncmds: 1,
                sizeofcmds: cmdsize,
                flags: 0,
                reserved: 0
            )
            var lc = load_command(cmd: cmd, cmdsize: cmdsize)
            var data = Data(count: headerSize + Int(cmdsize))
            withUnsafeBytes(of: &header) { data.replaceSubrange(0..<headerSize, with: $0) }
            withUnsafeBytes(of: &lc) {
                data.replaceSubrange(headerSize..<(headerSize + MemoryLayout<load_command>.size), with: $0)
            }
            return data
        }

        var truncDylib = makeSingleTruncatedCmdBinary(cmd: UInt32(LC_LOAD_DYLIB), cmdsize: 8)
        XCTAssertThrowsError(try Macho.replaceLibrary(&truncDylib, "@rpath/foo.dylib", "/usr/lib/foo.dylib")) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        let truncEncURL = try makeTempFile(
            named: "trunc_enc",
            data: makeSingleTruncatedCmdBinary(cmd: UInt32(LC_ENCRYPTION_INFO_64), cmdsize: 8)
        )
        XCTAssertThrowsError(try Macho.isMachoEncrypted(atURL: truncEncURL)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        let truncVerURL = try makeTempFile(
            named: "trunc_buildver",
            data: makeSingleTruncatedCmdBinary(cmd: UInt32(LC_BUILD_VERSION), cmdsize: 8)
        )
        XCTAssertThrowsError(try Macho.isMachoValidArch(truncVerURL)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
    }

    func testIterateLoadCommandsRejects32BitMagicAndSizeofcmdsMismatch() throws {
        var header32 = mach_header(
            magic: MH_MAGIC,
            cputype: CPU_TYPE_ARM,
            cpusubtype: 0,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 1,
            sizeofcmds: 8,
            flags: 0
        )
        var data32 = Data(count: 64)
        withUnsafeBytes(of: &header32) { data32.replaceSubrange(0..<MemoryLayout<mach_header>.size, with: $0) }
        var dummyLC = load_command(cmd: UInt32(LC_SEGMENT), cmdsize: 8)
        withUnsafeBytes(of: &dummyLC) { data32.replaceSubrange(32..<40, with: $0) }
        XCTAssertThrowsError(try Macho.iterateLoadCommands(binary: data32) { _, _ in false }) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        // ncmds = 0, sizeofcmds = 32
        var mismatchZero = makeThinArm64MachO()
        var hdr = try mismatchZero.extract(mach_header_64.self)
        hdr.ncmds = 0
        hdr.sizeofcmds = 32
        withUnsafeBytes(of: &hdr) { mismatchZero.replaceSubrange(0..<MemoryLayout<mach_header_64>.size, with: $0) }
        XCTAssertThrowsError(try Macho.iterateLoadCommands(binary: mismatchZero) { _, _ in false }) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        // ncmds = 1, actual cmdsize = 24, header sizeofcmds = 64
        let headerSize = MemoryLayout<mach_header_64>.size
        var mismatchPartial = Data(count: headerSize + 64)
        var partialHdr = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 1,
            sizeofcmds: 64,
            flags: 0,
            reserved: 0
        )
        withUnsafeBytes(of: &partialHdr) { mismatchPartial.replaceSubrange(0..<headerSize, with: $0) }
        let verCmd = makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))
        mismatchPartial.replaceSubrange(headerSize..<(headerSize + verCmd.count), with: verCmd)
        XCTAssertThrowsError(try Macho.iterateLoadCommands(binary: mismatchPartial) { _, _ in false }) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
    }

    func testReplaceLibrariesHandlesDuplicatesAndAccurateCapacityError() throws {
        let dupURL = try makeTempFile(
            named: "dup_uikit",
            data: makeThinArm64MachO(extraCommands: [
                makeVersionMinIphoneOSCommand(),
                makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib"),
                makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib")
            ])
        )
        try Macho.convertMacho(dupURL)

        let patchedData = try Data(contentsOf: dupURL)
        var paths: [String] = []
        _ = try Macho.iterateLoadCommands(binary: patchedData) { offset, shouldSwap in
            let lc = try patchedData.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
            if lc.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCmd = try patchedData.extract(
                    dylib_command.self,
                    offset: offset,
                    swap: shouldSwap ? swap_dylib_command : nil
                )
                paths.append(String(
                    data: patchedData,
                    offset: offset,
                    commandSize: Int(dylibCmd.cmdsize),
                    loadCommandString: dylibCmd.dylib.name
                ))
            }
            return false
        }
        XCTAssertFalse(paths.contains("@rpath/libswiftUIKit.dylib"))
        XCTAssertEqual(
            paths.filter { $0 == "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib" }.count,
            2
        )
        XCTAssertFalse(try Macho.fixLibrariesIfNeeded(atURL: dupURL))

        // Tight binary with machoURL == nil must preserve actual growth delta (24 bytes), not libDylib.utf8.count
        var tightData = makeThinArm64MachO(
            extraCommands: [makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib")],
            tightPadding: true
        )
        XCTAssertThrowsError(
            try Macho.replaceLibraries(&tightData, machoURL: nil, totalSize: tightData.count)
        ) { error in
            guard case let MachoCapacityError.insufficientLoadCommandSpace(needed, available) = error else {
                XCTFail("Expected MachoCapacityError.insufficientLoadCommandSpace, got \(error)")
                return
            }
            XCTAssertEqual(needed, 24)
            XCTAssertEqual(available, 0)
        }
    }

    func testFat64AndZeroArchAndSwappedCigam64RoundTrip() throws {
        var arm64Big = makeThinArm64MachO(
            extraCommands: [makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))],
            totalFileSize: 12_288
        )
        let tailMarker = Data([0xCA, 0xFE, 0xBA, 0xBE, 0xDE, 0xAD, 0xBE, 0xEF])
        arm64Big.replaceSubrange((arm64Big.count - tailMarker.count)..<arm64Big.count, with: tailMarker)

        var fat64 = makeFat64MachO(slices: [
            (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, makeThinX86Dummy()),
            (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, arm64Big)
        ])
        try Macho.stripBinary(&fat64)
        XCTAssertEqual(fat64, arm64Big)

        var zeroArchHeader = fat_header(magic: FAT_CIGAM, nfat_arch: 0)
        var zeroArchData = Data(count: MemoryLayout<fat_header>.size)
        withUnsafeBytes(of: &zeroArchHeader) { zeroArchData.replaceSubrange(0..<8, with: $0) }
        XCTAssertThrowsError(try Macho.stripBinary(&zeroArchData)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.failedToStripBinary)
        }

        // LC_BUILD_VERSION with ntools = 1 (cmdsize = 32)
        var bv = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: 32,
            platform: UInt32(PLATFORM_MACCATALYST),
            minos: 0x000F_0000,
            sdk: 0x000F_0000,
            ntools: 1
        )
        var bvWithTool = Data(count: 32)
        withUnsafeBytes(of: &bv) { bvWithTool.replaceSubrange(0..<24, with: $0) }
        let bvToolURL = try makeTempFile(named: "bv_ntools", data: makeThinArm64MachO(extraCommands: [bvWithTool]))
        XCTAssertTrue(try Macho.isMachoValidArch(bvToolURL))

        // MH_CIGAM_64 round-trip: convert, inject, remove
        let swappedURL = try makeTempFile(
            named: "cigam64",
            data: try makeSwappedCigam64Arm64MachO(extraCommands: [
                makeVersionMinIphoneOSCommand(),
                makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib")
            ])
        )
        try Macho.convertMacho(swappedURL)
        XCTAssertTrue(try Macho.isMachoValidArch(swappedURL))
        let playToolsPath = "@rpath/PlayTools.framework/PlayTools"
        XCTAssertTrue(try Macho.injectLoadCommand(at: swappedURL, cmdType: UInt32(LC_LOAD_DYLIB), dylibPath: playToolsPath))
        XCTAssertTrue(try Macho.inspectBinary(atURL: swappedURL, playToolsPath: playToolsPath).hasPlayTools)
        XCTAssertTrue(try Macho.removeLoadCommand(at: swappedURL, dylibPaths: [playToolsPath]))
        XCTAssertFalse(try Macho.inspectBinary(atURL: swappedURL, playToolsPath: playToolsPath).hasPlayTools)
    }

    func testCapacityBoundaryExactFitOneByteShortAndDirtyPadding() throws {
        let playToolsPath = "@rpath/PlayTools.framework/PlayTools"
        // Fixed 24 + 35 utf8 + 5 padding = 64? Let's compute exact cmdSize:
        // 35 % 8 == 3 -> padding = 5 -> 24 + 35 + 5 = 64? Wait: "@rpath/PlayTools.framework/PlayTools".utf8.count == 36?
        let fixed = MemoryLayout<dylib_command>.size
        let strLen = playToolsPath.utf8.count
        let cmdSize = fixed + strLen + (8 - (strLen % 8))

        func makeMachoWithAvailablePadding(_ availableBytes: Int, fillByte: UInt8 = 0) -> Data {
            let headerSize = MemoryLayout<mach_header_64>.size
            let bv = makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))
            let segFixedSize = MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size
            let sizeofcmds = segFixedSize + bv.count
            let commandsEnd = headerSize + sizeofcmds
            let textOffset = UInt32(commandsEnd + availableBytes)
            let total = max(0x2000, Int(textOffset) + 64)

            var header = mach_header_64(
                magic: MH_MAGIC_64,
                cputype: CPU_TYPE_ARM64,
                cpusubtype: CPU_SUBTYPE_ARM64_ALL,
                filetype: UInt32(MH_EXECUTE),
                ncmds: 2,
                sizeofcmds: UInt32(sizeofcmds),
                flags: UInt32(MH_NOUNDEFS | MH_DYLDLINK),
                reserved: 0
            )
            var data = Data(count: total)
            withUnsafeBytes(of: &header) { data.replaceSubrange(0..<headerSize, with: $0) }
            let seg = makeSegmentTextCommand(textOffset: textOffset, fileSize: UInt64(total))
            data.replaceSubrange(headerSize..<(headerSize + seg.count), with: seg)
            data.replaceSubrange((headerSize + seg.count)..<commandsEnd, with: bv)
            if fillByte != 0 && availableBytes > 0 {
                data.replaceSubrange(commandsEnd..<(commandsEnd + availableBytes),
                                     with: Data(repeating: fillByte, count: availableBytes))
            }
            return data
        }

        let exactURL = try makeTempFile(named: "exact_fit", data: makeMachoWithAvailablePadding(cmdSize))
        XCTAssertTrue(try Macho.injectLoadCommand(at: exactURL, cmdType: UInt32(LC_LOAD_DYLIB), dylibPath: playToolsPath))

        let oneShortURL = try makeTempFile(named: "one_short", data: makeMachoWithAvailablePadding(cmdSize - 1))
        XCTAssertThrowsError(
            try Macho.injectLoadCommand(at: oneShortURL, cmdType: UInt32(LC_LOAD_DYLIB), dylibPath: playToolsPath)
        ) { error in
            guard case let MachoCapacityError.insufficientLoadCommandSpace(needed, available) = error else {
                XCTFail("Expected MachoCapacityError, got \(error)")
                return
            }
            XCTAssertEqual(needed, cmdSize)
            XCTAssertEqual(available, cmdSize - 1)
        }

        let dirtyURL = try makeTempFile(
            named: "dirty_pad",
            data: makeMachoWithAvailablePadding(cmdSize, fillByte: 0xDE)
        )
        XCTAssertThrowsError(
            try Macho.injectLoadCommand(at: dirtyURL, cmdType: UInt32(LC_LOAD_DYLIB), dylibPath: playToolsPath)
        ) { error in
            guard case let MachoCapacityError.insufficientLoadCommandSpace(needed, available) = error else {
                XCTFail("Expected MachoCapacityError, got \(error)")
                return
            }
            XCTAssertEqual(needed, cmdSize)
            XCTAssertEqual(available, 0)
        }
    }

    func testFixLibrariesIfNeededPermissionsRepairAndCache() throws {
        let fm = FileManager.default
        let cleanURL = try makeTempFile(
            named: "perms_clean",
            data: makeThinArm64MachO(extraCommands: [
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST))
            ])
        )
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: cleanURL.path)

        // First call repairs non-executable permissions to 0755 and stamps cache
        XCTAssertTrue(try Macho.fixLibrariesIfNeeded(atURL: cleanURL))
        let repairedPerms = (try fm.attributesOfItem(atPath: cleanURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((repairedPerms ?? 0) & 0o777, 0o755)

        // Second call hits verifiedStamps cache and returns false
        XCTAssertFalse(try Macho.fixLibrariesIfNeeded(atURL: cleanURL))

        // Binary needing dylib fix rewrites once then hits cache on second call
        let unpatchedURL = try makeTempFile(
            named: "needs_fix",
            data: makeThinArm64MachO(extraCommands: [
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST)),
                makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib")
            ])
        )
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: unpatchedURL.path)
        XCTAssertTrue(try Macho.fixLibrariesIfNeeded(atURL: unpatchedURL))
        XCTAssertFalse(try Macho.fixLibrariesIfNeeded(atURL: unpatchedURL))
    }

    func testRemoveLoadCommandMiddleAndMultipleEntries() throws {
        let aDylib = "@rpath/A.dylib"
        let bDylib = "@rpath/B.dylib"
        let libSystem = "/usr/lib/libSystem.B.dylib"

        let middleURL = try makeTempFile(
            named: "remove_middle_multi",
            data: makeThinArm64MachO(extraCommands: [
                makeLoadDylibCommand(path: aDylib),
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST)),
                makeLoadDylibCommand(path: bDylib),
                makeLoadDylibCommand(path: libSystem)
            ])
        )

        XCTAssertTrue(try Macho.removeLoadCommand(at: middleURL, dylibPaths: [aDylib, bDylib]))
        XCTAssertTrue(try Macho.isMachoValidArch(middleURL))

        let patched = try Data(contentsOf: middleURL)
        var remainingCmds: [UInt32] = []
        var remainingDylibs: [String] = []
        _ = try Macho.iterateLoadCommands(binary: patched) { offset, shouldSwap in
            let lc = try patched.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
            remainingCmds.append(lc.cmd)
            if lc.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCmd = try patched.extract(
                    dylib_command.self,
                    offset: offset,
                    swap: shouldSwap ? swap_dylib_command : nil
                )
                remainingDylibs.append(String(
                    data: patched,
                    offset: offset,
                    commandSize: Int(dylibCmd.cmdsize),
                    loadCommandString: dylibCmd.dylib.name
                ))
            }
            return false
        }
        XCTAssertEqual(remainingCmds, [
            UInt32(LC_SEGMENT_64),
            UInt32(LC_BUILD_VERSION),
            UInt32(LC_LOAD_DYLIB)
        ])
        XCTAssertEqual(remainingDylibs, [libSystem])

        // Also verify middle removal on byte-swapped MH_CIGAM_64
        let swappedMiddleURL = try makeTempFile(
            named: "remove_middle_cigam64",
            data: try makeSwappedCigam64Arm64MachO(extraCommands: [
                makeLoadDylibCommand(path: aDylib),
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST)),
                makeLoadDylibCommand(path: libSystem)
            ])
        )
        XCTAssertTrue(try Macho.removeLoadCommand(at: swappedMiddleURL, dylibPaths: [aDylib]))
        XCTAssertTrue(try Macho.isMachoValidArch(swappedMiddleURL))
    }

    func testReplaceHelpersRejectTruncatedDataAndHandleSlices() throws {
        var tiny = Data([0xCF, 0xFA, 0xED, 0xFE])
        XCTAssertThrowsError(try Macho.replaceVersionCommand(&tiny)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
        XCTAssertThrowsError(try Macho.replaceLibrary(&tiny, "@rpath/a.dylib", "/usr/lib/a.dylib")) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
        XCTAssertThrowsError(try Macho.replaceLibraries(&tiny)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        var empty = Data()
        XCTAssertThrowsError(try Macho.replaceLastCommand(
            &empty,
            satisfy: { _, _ in false },
            with: { _ in nil },
            atEnd: true
        )) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        // Non-zero startIndex Data slices must not trigger Data.extract SIGTRAP
        let thin = makeThinArm64MachO(extraCommands: [
            makeVersionMinIphoneOSCommand(),
            makeLoadDylibCommand(path: "@rpath/libswiftUIKit.dylib")
        ])
        let prefixed = Data(repeating: 0xAA, count: 16) + thin
        var slice = prefixed[16..<prefixed.count]
        XCTAssertEqual(slice.startIndex, 16)

        let endOff = try Macho.iterateLoadCommands(binary: slice) { _, _ in false }
        XCTAssertGreaterThan(endOff, MemoryLayout<mach_header_64>.size)
        XCTAssertGreaterThan(try Macho.earliestContentOffset(in: slice), MemoryLayout<mach_header_64>.size)

        try Macho.replaceVersionCommand(&slice, totalSize: slice.count)
        XCTAssertTrue(try Macho.replaceLibrary(
            &slice,
            "@rpath/libswiftUIKit.dylib",
            "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib",
            totalSize: slice.count
        ))

        let fatPrefixed = Data(repeating: 0xBB, count: 16) + makeFatMachO(slices: [
            (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, thin)
        ])
        var fatSlice = fatPrefixed[16..<fatPrefixed.count]
        XCTAssertEqual(fatSlice.startIndex, 16)
        try Macho.stripBinary(&fatSlice)
        XCTAssertEqual(fatSlice, thin)
    }

    func testDataExtractThrowsAppCorruptedInsteadOfCrashing() throws {
        let empty = Data()
        XCTAssertThrowsError(try empty.extract(UInt32.self)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        let fourBytes = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertThrowsError(try fourBytes.extract(UInt32.self, offset: -1)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
        XCTAssertThrowsError(try fourBytes.extract(UInt32.self, offset: 2)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
        XCTAssertThrowsError(try fourBytes.extract(UInt32.self, offset: Int.max)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }

        let sliced = (Data([0xAA, 0xBB, 0xCC, 0xDD]) + fourBytes)[4..<8]
        XCTAssertEqual(sliced.startIndex, 4)
        XCTAssertThrowsError(try sliced.extract(UInt32.self, offset: 0)) { error in
            XCTAssertEqual(error as? PlayCoverError, PlayCoverError.appCorrupted)
        }
        let extracted = try sliced.extract(UInt32.self, offset: 4)
        XCTAssertEqual(extracted.littleEndian, 0x04030201)
    }

    func testInjectLoadCommandBeforeThirdPartyDylibsOrdersAndRelocates() throws {
        let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        let antiCheat = "@rpath/AntiCheatSDK.framework/AntiCheatSDK"
        let unity = "@rpath/UnityFramework.framework/UnityFramework"
        let libSystem = "/usr/lib/libSystem.B.dylib"
        let playTools = "/Users/tester/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework/PlayTools"

        func extractDylibOrder(from url: URL) throws -> [String] {
            let data = try Data(contentsOf: url)
            var result: [String] = []
            _ = try Macho.iterateLoadCommands(binary: data) { offset, shouldSwap in
                let lc = try data.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
                if lc.cmd == UInt32(LC_LOAD_DYLIB) {
                    let dc = try data.extract(
                        dylib_command.self,
                        offset: offset,
                        swap: shouldSwap ? swap_dylib_command : nil
                    )
                    result.append(String(
                        data: data,
                        offset: offset,
                        commandSize: Int(dc.cmdsize),
                        loadCommandString: dc.dylib.name
                    ))
                }
                return false
            }
            return result
        }

        // 1. Fresh injection places PlayTools after system dylib before @rpath third-party frameworks
        let freshURL = try makeTempFile(
            named: "inject_before_rpath",
            data: makeThinArm64MachO(extraCommands: [
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST)),
                makeLoadDylibCommand(path: foundation),
                makeLoadDylibCommand(path: antiCheat),
                makeLoadDylibCommand(path: unity),
                makeLoadDylibCommand(path: libSystem)
            ])
        )
        XCTAssertTrue(try Macho.injectLoadCommand(
            at: freshURL,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: playTools,
            beforeThirdPartyDylibs: true
        ))
        XCTAssertEqual(
            try extractDylibOrder(from: freshURL),
            [foundation, playTools, antiCheat, unity, libSystem]
        )
        // Idempotent second call when already before @rpath returns false
        XCTAssertFalse(try Macho.injectLoadCommand(
            at: freshURL,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: playTools,
            beforeThirdPartyDylibs: true
        ))

        // 2. Legacy binary with PlayTools appended at tail gets relocated ahead of @rpath frameworks
        let legacyURL = try makeTempFile(
            named: "relocate_legacy_tail",
            data: makeThinArm64MachO(extraCommands: [
                makeBuildVersionCommand(platform: UInt32(PLATFORM_MACCATALYST)),
                makeLoadDylibCommand(path: foundation),
                makeLoadDylibCommand(path: antiCheat),
                makeLoadDylibCommand(path: playTools)
            ])
        )
        XCTAssertTrue(try Macho.injectLoadCommand(
            at: legacyURL,
            cmdType: UInt32(LC_LOAD_DYLIB),
            dylibPath: playTools,
            beforeThirdPartyDylibs: true
        ))
        XCTAssertEqual(
            try extractDylibOrder(from: legacyURL),
            [foundation, playTools, antiCheat]
        )
    }
}
