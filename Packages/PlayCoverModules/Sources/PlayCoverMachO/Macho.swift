//
//  Macho.swift
//  PlayCover
//

// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
import Darwin
import Foundation
import MachO
import PlayCoverCore

@_silgen_name("_dyld_shared_cache_contains_path")
private func dyldSharedCacheContainsPath(_ path: UnsafePointer<CChar>) -> Bool


public enum MachoCodeSigner {
    public static var verifySignature: (URL) throws -> Void = { url in
        try runCodesign(["--verify", "--deep", "--strict", url.path])
    }

    public static var signBinary: (URL) throws -> Void = { url in
        try runCodesign(["-fs-", url.path])
    }

    private static func runCodesign(_ arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw PlayCoverError.shellExecutionFailed(
                binary: "/usr/bin/codesign",
                status: process.terminationStatus,
                output: output
            )
        }
    }
}

public enum MachoCapacityError: LocalizedError {
    case insufficientLoadCommandSpace(needed: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case let .insufficientLoadCommandSpace(needed, available):
            return "Insufficient Mach-O load command padding (needed \(needed) bytes, available \(available) bytes)."
        }
    }
}

public class Macho {
    private struct VerifiedBinaryStamp: Equatable {
        let mtimeSec: Int
        let mtimeNSec: Int
        let fileSize: UInt64
    }

    public struct SliceContext {
        public var headerWindow: Data
        public let originalWindowCount: Int
        public let sliceOffset: UInt64
        public let sliceSize: UInt64
        public let isFat: Bool

        public init(
            headerWindow: Data,
            originalWindowCount: Int,
            sliceOffset: UInt64,
            sliceSize: UInt64,
            isFat: Bool
        ) {
            self.headerWindow = headerWindow
            self.originalWindowCount = originalWindowCount
            self.sliceOffset = sliceOffset
            self.sliceSize = sliceSize
            self.isFat = isFat
        }
    }

    private static let verifiedLock = NSLock()
    private static var verifiedStamps: [String: VerifiedBinaryStamp] = [:]

    private static func currentStamp(for url: URL) -> VerifiedBinaryStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return VerifiedBinaryStamp(
            mtimeSec: Int(st.st_mtimespec.tv_sec),
            mtimeNSec: Int(st.st_mtimespec.tv_nsec),
            fileSize: UInt64(st.st_size)
        )
    }

    private static func invalidateStamp(for url: URL) {
        verifiedLock.lock()
        verifiedStamps.removeValue(forKey: url.path)
        verifiedLock.unlock()
    }

    public static func inspectArm64Slice(at url: URL) throws -> SliceContext {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_size >= Int64(MemoryLayout<mach_header_64>.size) else {
            throw PlayCoverError.appCorrupted
        }
        let totalFileSize = UInt64(st.st_size)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let initial = try handle.read(upToCount: 4096),
              initial.count >= MemoryLayout<mach_header_64>.size else {
            throw PlayCoverError.appCorrupted
        }

        var sliceOffset: UInt64 = 0
        var sliceSize: UInt64 = totalFileSize
        var isFat = false

        var fatHeader = try initial.extract(fat_header.self)
        let fatMagic = fatHeader.magic
        if fatMagic == FAT_MAGIC || fatMagic == FAT_CIGAM ||
            fatMagic == FAT_MAGIC_64 || fatMagic == FAT_CIGAM_64 {
            isFat = true
            let fatSwap = (fatMagic == FAT_CIGAM || fatMagic == FAT_CIGAM_64)
            let isFat64 = (fatMagic == FAT_MAGIC_64 || fatMagic == FAT_CIGAM_64)
            if fatSwap {
                swap_fat_header(&fatHeader, NXHostByteOrder())
            }
            let archOffset = MemoryLayout.size(ofValue: fatHeader)
            let archSize = isFat64 ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
            let (tableBytes, tableOverflow) = UInt64(fatHeader.nfat_arch)
                .multipliedReportingOverflow(by: UInt64(archSize))
            guard !tableOverflow,
                  UInt64(archOffset) <= totalFileSize,
                  tableBytes <= totalFileSize - UInt64(archOffset) else {
                throw PlayCoverError.failedToStripBinary
            }
            let neededFatBytes = archOffset + Int(tableBytes)
            var cursorOffset = archOffset
            let fatData: Data
            if neededFatBytes <= initial.count {
                fatData = initial
            } else {
                try handle.seek(toOffset: 0)
                guard let fullFat = try handle.read(upToCount: neededFatBytes),
                      fullFat.count >= neededFatBytes else {
                    throw PlayCoverError.failedToStripBinary
                }
                fatData = fullFat
            }

            var foundArm64 = false
            for _ in 0..<fatHeader.nfat_arch {
                if isFat64 {
                    var arch64 = try fatData.extract(fat_arch_64.self, offset: cursorOffset)
                    if fatSwap {
                        swap_fat_arch_64(&arch64, 1, NXHostByteOrder())
                    }
                    if arch64.cputype == CPU_TYPE_ARM64 {
                        sliceOffset = arch64.offset
                        sliceSize = arch64.size
                        foundArm64 = true
                        break
                    }
                } else {
                    var arch = try fatData.extract(fat_arch.self, offset: cursorOffset)
                    if fatSwap {
                        swap_fat_arch(&arch, 1, NXHostByteOrder())
                    }
                    if arch.cputype == CPU_TYPE_ARM64 {
                        sliceOffset = UInt64(arch.offset)
                        sliceSize = UInt64(arch.size)
                        foundArm64 = true
                        break
                    }
                }
                cursorOffset += archSize
            }
            if !foundArm64 {
                throw PlayCoverError.failedToStripBinary
            }
        }

        let headerSize = MemoryLayout<mach_header_64>.size
        guard sliceSize >= UInt64(headerSize),
              sliceOffset <= totalFileSize,
              sliceSize <= totalFileSize - sliceOffset else {
            throw PlayCoverError.appCorrupted
        }

        let machHeaderData: Data
        if sliceOffset == 0 {
            machHeaderData = initial
        } else {
            try handle.seek(toOffset: sliceOffset)
            guard let hdr = try handle.read(upToCount: headerSize), hdr.count >= headerSize else {
                throw PlayCoverError.appCorrupted
            }
            machHeaderData = hdr
        }

        var mh = try machHeaderData.extract(mach_header_64.self)
        if mh.magic == MH_CIGAM_64 {
            swap_mach_header_64(&mh, NXHostByteOrder())
        } else if mh.magic != MH_MAGIC_64 {
            throw PlayCoverError.appCorrupted
        }

        let minNeeded = UInt64(headerSize) + UInt64(mh.sizeofcmds)
        guard minNeeded <= sliceSize else {
            throw PlayCoverError.appCorrupted
        }

        let initialReadCount = Int(min(sliceSize, max(minNeeded + 64, UInt64(4096))))
        var headerWindow: Data
        if sliceOffset == 0 && initialReadCount <= initial.count {
            headerWindow = Data(initial.prefix(initialReadCount))
        } else {
            try handle.seek(toOffset: sliceOffset)
            guard let buf = try handle.read(upToCount: initialReadCount),
                  UInt64(buf.count) >= minNeeded else {
                throw PlayCoverError.appCorrupted
            }
            headerWindow = buf
        }

        let earliest = try earliestContentOffset(in: headerWindow, totalSize: Int(sliceSize))
        let targetWindowCount = min(earliest, Int(min(sliceSize, minNeeded + 65536)))
        if targetWindowCount > headerWindow.count {
            try handle.seek(toOffset: sliceOffset)
            if let expanded = try handle.read(upToCount: targetWindowCount),
               expanded.count == targetWindowCount {
                headerWindow = expanded
            }
        }

        return SliceContext(
            headerWindow: headerWindow,
            originalWindowCount: headerWindow.count,
            sliceOffset: sliceOffset,
            sliceSize: sliceSize,
            isFat: isFat
        )
    }

    public static func readHeaderSlice(at url: URL) throws -> Data {
        try inspectArm64Slice(at: url).headerWindow
    }

    public static func earliestContentOffset(in binary: Data, totalSize: Int? = nil) throws -> Int {
        let binary = binary.startIndex == 0 ? binary : Data(binary)
        let headerSize = MemoryLayout<mach_header_64>.size
        var earliest = totalSize ?? binary.count

        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let lc = try binary.extract(load_command.self,
                                    offset: offset,
                                    swap: shouldSwap ? swap_load_command : nil)
            if lc.cmd == UInt32(LC_SEGMENT_64) {
                let segSize = MemoryLayout<segment_command_64>.size
                guard offset + segSize <= offset + Int(lc.cmdsize),
                      offset + Int(lc.cmdsize) <= binary.count else {
                    return false
                }
                let seg = try binary.extract(segment_command_64.self,
                                         offset: offset,
                                         swap: shouldSwap ? swap_segment_command_64 : nil)
                let sectSize = MemoryLayout<section_64>.size
                var sectOffset = offset + segSize
                for _ in 0..<seg.nsects {
                    guard sectOffset + sectSize <= offset + Int(lc.cmdsize) else { break }
                    var sect = try binary.extract(section_64.self, offset: sectOffset)
                    if shouldSwap {
                        swap_section_64(&sect, 1, NXHostByteOrder())
                    }
                    let sectType = Int32(bitPattern: sect.flags) & SECTION_TYPE
                    if sect.size > 0 &&
                        Int(sect.offset) > headerSize &&
                        sectType != S_ZEROFILL &&
                        sectType != S_GB_ZEROFILL &&
                        sectType != S_THREAD_LOCAL_ZEROFILL {
                        earliest = min(earliest, Int(sect.offset))
                    }
                    sectOffset += sectSize
                }
            } else if [
                UInt32(LC_CODE_SIGNATURE),
                UInt32(LC_SEGMENT_SPLIT_INFO),
                UInt32(LC_FUNCTION_STARTS),
                UInt32(LC_DATA_IN_CODE),
                UInt32(LC_DYLIB_CODE_SIGN_DRS),
                UInt32(LC_LINKER_OPTIMIZATION_HINT),
                UInt32(LC_DYLD_EXPORTS_TRIE),
                UInt32(LC_DYLD_CHAINED_FIXUPS)
            ].contains(lc.cmd) {
                if Int(lc.cmdsize) >= MemoryLayout<linkedit_data_command>.size {
                    let le = try binary.extract(linkedit_data_command.self,
                                            offset: offset,
                                            swap: shouldSwap ? swap_linkedit_data_command : nil)
                    if le.datasize > 0 && Int(le.dataoff) > headerSize {
                        earliest = min(earliest, Int(le.dataoff))
                    }
                }
            } else if lc.cmd == UInt32(LC_SYMTAB) {
                if Int(lc.cmdsize) >= MemoryLayout<symtab_command>.size {
                    let sym = try binary.extract(symtab_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_symtab_command : nil)
                    if sym.nsyms > 0 && Int(sym.symoff) > headerSize {
                        earliest = min(earliest, Int(sym.symoff))
                    }
                    if sym.strsize > 0 && Int(sym.stroff) > headerSize {
                        earliest = min(earliest, Int(sym.stroff))
                    }
                }
            } else if lc.cmd == UInt32(LC_DYLD_INFO) || lc.cmd == UInt32(LC_DYLD_INFO_ONLY) {
                if Int(lc.cmdsize) >= MemoryLayout<dyld_info_command>.size {
                    let info = try binary.extract(dyld_info_command.self,
                                              offset: offset,
                                              swap: shouldSwap ? swap_dyld_info_command : nil)
                    for (off, size) in [
                        (info.rebase_off, info.rebase_size),
                        (info.bind_off, info.bind_size),
                        (info.weak_bind_off, info.weak_bind_size),
                        (info.lazy_bind_off, info.lazy_bind_size),
                        (info.export_off, info.export_size)
                    ] where size > 0 && Int(off) > headerSize {
                        earliest = min(earliest, Int(off))
                    }
                }
            }
            return false
        }
        return earliest
    }

    private static func targetPermissions(for macho: URL) -> Int {
        let fm = FileManager.default
        let existingPerms = (try? fm.attributesOfItem(atPath: macho.path)[.posixPermissions] as? NSNumber)?.intValue
        if let perms = existingPerms, (perms & 0o111) != 0 {
            return perms & 0o7777
        }
        return 0o755
    }

    private static func swapTempFile(_ tempURL: URL, into targetURL: URL, permissions: Int) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: tempURL.path)
        if fm.fileExists(atPath: targetURL.path) {
            _ = try fm.replaceItemAt(targetURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: targetURL)
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: targetURL.path)
        invalidateStamp(for: targetURL)
    }

    public static func writeMachoAtomically(_ binary: Data, to macho: URL) throws {
        let binary = binary.startIndex == 0 ? binary : Data(binary)
        _ = try iterateLoadCommands(binary: binary) { _, _ in false }

        let fm = FileManager.default
        let targetPerms = targetPermissions(for: macho)
        let parentDir = macho.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".\(macho.lastPathComponent).tmp-\(UUID().uuidString)")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        try binary.write(to: tempURL)
        try swapTempFile(tempURL, into: macho, permissions: targetPerms)
    }

    public static func writePatchedHeaderAtomically(
        patchedHeader: Data,
        sliceContext: SliceContext,
        to macho: URL
    ) throws {
        let patchedHeader = patchedHeader.startIndex == 0 ? patchedHeader : Data(patchedHeader)
        guard patchedHeader.count == sliceContext.originalWindowCount else {
            throw PlayCoverError.appCorrupted
        }
        _ = try iterateLoadCommands(binary: patchedHeader) { _, _ in false }

        let fm = FileManager.default
        let targetPerms = targetPermissions(for: macho)
        let parentDir = macho.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".\(macho.lastPathComponent).tmp-\(UUID().uuidString)")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        if !sliceContext.isFat {
            if Darwin.clonefile(macho.path, tempURL.path, 0) != 0 {
                try fm.copyItem(at: macho, to: tempURL)
            }
            let outHandle = try FileHandle(forUpdating: tempURL)
            do {
                try outHandle.seek(toOffset: 0)
                try outHandle.write(contentsOf: patchedHeader)
                try outHandle.close()
            } catch {
                try? outHandle.close()
                throw error
            }
        } else {
            let srcHandle = try FileHandle(forReadingFrom: macho)
            defer { try? srcHandle.close() }

            guard fm.createFile(
                atPath: tempURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: targetPerms)]
            ) else {
                throw PlayCoverError.failedToStripBinary
            }
            let outHandle = try FileHandle(forWritingTo: tempURL)
            do {
                try outHandle.write(contentsOf: patchedHeader)
                let bodyStart = sliceContext.sliceOffset + UInt64(sliceContext.originalWindowCount)
                var remaining = sliceContext.sliceSize - UInt64(sliceContext.originalWindowCount)
                try srcHandle.seek(toOffset: bodyStart)

                let chunkSize = 4 * 1024 * 1024
                while remaining > 0 {
                    let step = Int(min(remaining, UInt64(chunkSize)))
                    let written: Int = try autoreleasepool {
                        guard let chunk = try srcHandle.read(upToCount: step), !chunk.isEmpty else {
                            throw PlayCoverError.appCorrupted
                        }
                        try outHandle.write(contentsOf: chunk)
                        return chunk.count
                    }
                    remaining -= UInt64(written)
                }
                try outHandle.close()
            } catch {
                try? outHandle.close()
                throw error
            }
        }

        try swapTempFile(tempURL, into: macho, permissions: targetPerms)
    }

    private static func enclosingAppBundle(for macho: URL) -> URL? {
        var cursor = macho.deletingLastPathComponent()
        while cursor.path != "/" && !cursor.path.isEmpty {
            if cursor.pathExtension == "app" {
                return cursor
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path { break }
            cursor = next
        }
        return nil
    }

    private static func makeCatalystReexportDylib(installName: String, reexportPath: String) -> Data {
        func dylibCmd(_ cmd: UInt32, _ path: String, timestamp: UInt32) -> Data {
            let strBytes = Array(path.utf8) + [0]
            let cmdSize = (24 + strBytes.count + 7) & ~7
            var buf = Data(count: cmdSize)
            func w32(_ off: Int, _ val: UInt32) {
                var le = val.littleEndian
                withUnsafeBytes(of: &le) { buf.replaceSubrange(off..<(off + 4), with: $0) }
            }
            w32(0, cmd)
            w32(4, UInt32(cmdSize))
            w32(8, 24)
            w32(12, timestamp)
            w32(16, 0x00010000)
            w32(20, 0x00010000)
            buf.replaceSubrange(24..<(24 + strBytes.count), with: strBytes)
            return buf
        }

        let idCmd = dylibCmd(UInt32(LC_ID_DYLIB), installName, timestamp: 1)
        let reexportCmd = dylibCmd(UInt32(LC_REEXPORT_DYLIB), reexportPath, timestamp: 2)
        let libSysCmd = dylibCmd(UInt32(LC_LOAD_DYLIB), "/usr/lib/libSystem.B.dylib", timestamp: 2)

        let fixedCmdBytes = 152 + 72 + 16 + 16 + 24 + 80 + 24 + 24 + 16 + 16 + 16
        let sizeofcmds = fixedCmdBytes + idCmd.count + reexportCmd.count + libSysCmd.count
        let pageSize = 16384
        let linkeditSize = 72
        var data = Data(count: pageSize + linkeditSize)

        func put32(_ off: Int, _ val: UInt32) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { data.replaceSubrange(off..<(off + 4), with: $0) }
        }
        func put64(_ off: Int, _ val: UInt64) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { data.replaceSubrange(off..<(off + 8), with: $0) }
        }
        func putStr16(_ off: Int, _ str: String) {
            let b = Array(str.utf8.prefix(16))
            data.replaceSubrange(off..<(off + b.count), with: b)
        }

        // mach_header_64
        put32(0, MH_MAGIC_64)
        put32(4, UInt32(bitPattern: CPU_TYPE_ARM64))
        put32(8, 0)
        put32(12, UInt32(MH_DYLIB))
        put32(16, 14)
        put32(20, UInt32(sizeofcmds))
        put32(24, UInt32(MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL))
        put32(28, 0)

        var cur = 32
        let textOff = 32 + sizeofcmds

        // 1. LC_SEGMENT_64 (__TEXT + __text)
        put32(cur + 0, UInt32(LC_SEGMENT_64))
        put32(cur + 4, 152)
        putStr16(cur + 8, "__TEXT")
        put64(cur + 24, 0)
        put64(cur + 32, UInt64(pageSize))
        put64(cur + 40, 0)
        put64(cur + 48, UInt64(pageSize))
        put32(cur + 56, 5)
        put32(cur + 60, 5)
        put32(cur + 64, 1)
        put32(cur + 68, 0)
        putStr16(cur + 72, "__text")
        putStr16(cur + 88, "__TEXT")
        put64(cur + 104, UInt64(textOff))
        put64(cur + 112, 0)
        put32(cur + 120, UInt32(textOff))
        put32(cur + 124, 0)
        put32(cur + 128, 0)
        put32(cur + 132, 0)
        put32(cur + 136, 0x80000400)
        cur += 152

        // 2. LC_SEGMENT_64 (__LINKEDIT)
        put32(cur + 0, UInt32(LC_SEGMENT_64))
        put32(cur + 4, 72)
        putStr16(cur + 8, "__LINKEDIT")
        put64(cur + 24, UInt64(pageSize))
        put64(cur + 32, UInt64(pageSize))
        put64(cur + 40, UInt64(pageSize))
        put64(cur + 48, UInt64(linkeditSize))
        put32(cur + 56, 1)
        put32(cur + 60, 1)
        put32(cur + 64, 0)
        put32(cur + 68, 0)
        cur += 72

        // 3. LC_ID_DYLIB
        data.replaceSubrange(cur..<(cur + idCmd.count), with: idCmd)
        cur += idCmd.count

        // 4. LC_DYLD_CHAINED_FIXUPS
        put32(cur + 0, UInt32(LC_DYLD_CHAINED_FIXUPS))
        put32(cur + 4, 16)
        put32(cur + 8, UInt32(pageSize))
        put32(cur + 12, 48)
        cur += 16

        // 5. LC_DYLD_EXPORTS_TRIE
        put32(cur + 0, UInt32(LC_DYLD_EXPORTS_TRIE))
        put32(cur + 4, 16)
        put32(cur + 8, UInt32(pageSize + 48))
        put32(cur + 12, 8)
        cur += 16

        // 6. LC_SYMTAB
        put32(cur + 0, UInt32(LC_SYMTAB))
        put32(cur + 4, 24)
        put32(cur + 8, UInt32(pageSize + 64))
        put32(cur + 12, 0)
        put32(cur + 16, UInt32(pageSize + 64))
        put32(cur + 20, 8)
        cur += 24

        // 7. LC_DYSYMTAB
        put32(cur + 0, UInt32(LC_DYSYMTAB))
        put32(cur + 4, 80)
        cur += 80

        // 8. LC_UUID
        put32(cur + 0, UInt32(LC_UUID))
        put32(cur + 4, 24)
        var uuid = UUID().uuid
        withUnsafeBytes(of: &uuid) { data.replaceSubrange((cur + 8)..<(cur + 24), with: $0) }
        cur += 24

        // 9. LC_BUILD_VERSION (Mac Catalyst 15.0)
        put32(cur + 0, UInt32(LC_BUILD_VERSION))
        put32(cur + 4, 24)
        put32(cur + 8, UInt32(PLATFORM_MACCATALYST))
        put32(cur + 12, 0x000F0000)
        put32(cur + 16, 0x000F0000)
        put32(cur + 20, 0)
        cur += 24

        // 10. LC_SOURCE_VERSION
        put32(cur + 0, UInt32(LC_SOURCE_VERSION))
        put32(cur + 4, 16)
        put64(cur + 8, 0)
        cur += 16

        // 11. LC_REEXPORT_DYLIB
        data.replaceSubrange(cur..<(cur + reexportCmd.count), with: reexportCmd)
        cur += reexportCmd.count

        // 12. LC_LOAD_DYLIB (/usr/lib/libSystem.B.dylib)
        data.replaceSubrange(cur..<(cur + libSysCmd.count), with: libSysCmd)
        cur += libSysCmd.count

        // 13. LC_FUNCTION_STARTS
        put32(cur + 0, UInt32(LC_FUNCTION_STARTS))
        put32(cur + 4, 16)
        put32(cur + 8, UInt32(pageSize + 56))
        put32(cur + 12, 8)
        cur += 16

        // 14. LC_DATA_IN_CODE
        put32(cur + 0, UInt32(LC_DATA_IN_CODE))
        put32(cur + 4, 16)
        put32(cur + 8, UInt32(pageSize + 64))
        put32(cur + 12, 0)

        // Minimal __LINKEDIT payload (48B chained_fixups + 8B exports + 8B func_starts + 8B strtab)
        put32(pageSize + 0, 0)
        put32(pageSize + 4, 32)
        put32(pageSize + 8, 44)
        put32(pageSize + 12, 44)
        put32(pageSize + 16, 0)
        put32(pageSize + 20, 1)
        put32(pageSize + 24, 0)
        put32(pageSize + 32, 2)
        data[pageSize + 64] = 0x20

        return data
    }

    private static func installSystemSwiftSymlinkFallback(
        dylib: String,
        targetPath: String,
        for macho: URL
    ) throws -> Bool {
        let fm = FileManager.default
        let targetAvailable = fm.fileExists(atPath: targetPath) ||
            targetPath.withCString { dyldSharedCacheContainsPath($0) }
        guard let appBundle = enclosingAppBundle(for: macho), targetAvailable else {
            return false
        }
        let frameworksDir = appBundle.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        let proxyURL = frameworksDir.appendingPathComponent("\(dylib).dylib")
        if fm.fileExists(atPath: proxyURL.path) {
            if (try? isMachoValidArch(proxyURL)) == true,
               (try? MachoCodeSigner.verifySignature(proxyURL)) != nil {
                return true
            }
            try? fm.removeItem(at: proxyURL)
        }
        let proxyData = makeCatalystReexportDylib(installName: "@rpath/\(dylib).dylib",
                                                  reexportPath: targetPath)
        try writeMachoAtomically(proxyData, to: proxyURL)
        try MachoCodeSigner.signBinary(proxyURL)
        return true
    }

    public static func stripBinary(_ binary: inout Data) throws {
        if binary.startIndex != 0 {
            binary = Data(binary)
        }
        guard binary.count >= MemoryLayout<fat_header>.size else {
            throw PlayCoverError.failedToStripBinary
        }
        var header = try binary.extract(fat_header.self)
        var offset = MemoryLayout.size(ofValue: header)
        let fatMagic = header.magic
        let shouldSwap = (fatMagic == FAT_CIGAM || fatMagic == FAT_CIGAM_64)
        let totalCount = UInt64(binary.count)

        if fatMagic == FAT_MAGIC || fatMagic == FAT_CIGAM {
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }
            let archSize = MemoryLayout<fat_arch>.size
            let (tableBytes, tableOverflow) = UInt64(header.nfat_arch)
                .multipliedReportingOverflow(by: UInt64(archSize))
            guard !tableOverflow,
                  UInt64(offset) <= totalCount,
                  tableBytes <= totalCount - UInt64(offset) else {
                throw PlayCoverError.failedToStripBinary
            }
            for _ in 0..<header.nfat_arch {
                var arch = try binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch(&arch, 1, NXHostByteOrder())
                }
                if arch.cputype == CPU_TYPE_ARM64 {
                    let sliceOffset = UInt64(arch.offset)
                    let sliceSize = UInt64(arch.size)
                    guard sliceOffset <= totalCount,
                          sliceSize <= totalCount - sliceOffset else {
                        throw PlayCoverError.failedToStripBinary
                    }
                    binary = binary.subdata(in: Int(sliceOffset)..<Int(sliceOffset + sliceSize))
                    return
                }
                offset += archSize
            }
            throw PlayCoverError.failedToStripBinary
        } else if fatMagic == FAT_MAGIC_64 || fatMagic == FAT_CIGAM_64 {
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }
            let archSize = MemoryLayout<fat_arch_64>.size
            let (tableBytes, tableOverflow) = UInt64(header.nfat_arch)
                .multipliedReportingOverflow(by: UInt64(archSize))
            guard !tableOverflow,
                  UInt64(offset) <= totalCount,
                  tableBytes <= totalCount - UInt64(offset) else {
                throw PlayCoverError.failedToStripBinary
            }
            for _ in 0..<header.nfat_arch {
                var arch = try binary.extract(fat_arch_64.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch_64(&arch, 1, NXHostByteOrder())
                }
                if arch.cputype == CPU_TYPE_ARM64 {
                    let sliceOffset = arch.offset
                    let sliceSize = arch.size
                    guard sliceOffset <= totalCount,
                          sliceSize <= totalCount - sliceOffset else {
                        throw PlayCoverError.failedToStripBinary
                    }
                    binary = binary.subdata(in: Int(sliceOffset)..<Int(sliceOffset + sliceSize))
                    return
                }
                offset += archSize
            }
            throw PlayCoverError.failedToStripBinary
        }
    }

    public static func convertMacho(_ macho: URL) throws {
        print("Converting MachO at \(macho.path)")
        var ctx = try inspectArm64Slice(at: macho)
        try replaceVersionCommand(&ctx.headerWindow, totalSize: Int(ctx.sliceSize))
        _ = try replaceLibraries(&ctx.headerWindow, machoURL: macho, totalSize: Int(ctx.sliceSize))
        try writePatchedHeaderAtomically(patchedHeader: ctx.headerWindow, sliceContext: ctx, to: macho)
    }

    public static let dylibsToReplace = [
        "libswiftUIKit",
        "libswiftCoreNFC",
        "libswiftAssetsLibrary",
        "libswiftCarPlay",
        "libswiftHomeKit",
        "libswiftMediaPlayer",
        "libswiftQuickLook"
    ]

    @discardableResult
    public static func replaceLibraries(
        _ binary: inout Data,
        machoURL: URL? = nil,
        totalSize: Int? = nil
    ) throws -> (rewroteBinary: Bool, createdSymlink: Bool) {
        if binary.startIndex != 0 {
            binary = Data(binary)
        }
        var rewroteBinary = false
        var createdSymlink = false

        for dylib in dylibsToReplace {
            let rpathDylib = "@rpath/\(dylib).dylib"
            let libDylib = "/System/iOSSupport/usr/lib/swift/\(dylib).dylib"

            do {
                while try replaceLibrary(&binary, rpathDylib, libDylib, totalSize: totalSize) {
                    rewroteBinary = true
                }
            } catch let error as MachoCapacityError {
                if let machoURL = machoURL,
                   try installSystemSwiftSymlinkFallback(dylib: dylib, targetPath: libDylib, for: machoURL) {
                    createdSymlink = true
                } else {
                    throw error
                }
            }
        }
        return (rewroteBinary, createdSymlink)
    }

    @discardableResult
    public static func fixLibrariesIfNeeded(atURL macho: URL) throws -> Bool {
        let fm = FileManager.default
        var permissionsRepaired = false
        if let perms = (try? fm.attributesOfItem(atPath: macho.path)[.posixPermissions] as? NSNumber)?.intValue,
           (perms & 0o111) == 0 {
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: macho.path)
            permissionsRepaired = true
        }

        if let stamp = currentStamp(for: macho) {
            verifiedLock.lock()
            let alreadyVerified = (verifiedStamps[macho.path] == stamp)
            verifiedLock.unlock()
            if alreadyVerified && !permissionsRepaired {
                return false
            }
        }

        var ctx = try inspectArm64Slice(at: macho)
        var needsFix = false
        let appBundle = enclosingAppBundle(for: macho)
        let rpathMap: [String: String] = Dictionary(
            uniqueKeysWithValues: dylibsToReplace.map { ("@rpath/\($0).dylib", $0) }
        )

        _ = try iterateLoadCommands(binary: ctx.headerWindow) { offset, shouldSwap in
            let loadCommand = try ctx.headerWindow.extract(load_command.self,
                                                       offset: offset,
                                                       swap: shouldSwap ? swap_load_command : nil)
            if [LC_LOAD_WEAK_DYLIB, UInt32(LC_LOAD_DYLIB)].contains(loadCommand.cmd) {
                guard Int(loadCommand.cmdsize) >= MemoryLayout<dylib_command>.size else {
                    throw PlayCoverError.appCorrupted
                }
                let dylibCommand = try ctx.headerWindow.extract(dylib_command.self,
                                                          offset: offset,
                                                          swap: shouldSwap ? swap_dylib_command : nil)
                let name = String(data: ctx.headerWindow,
                                  offset: offset,
                                  commandSize: Int(dylibCommand.cmdsize),
                                  loadCommandString: dylibCommand.dylib.name)
                if let dylibBase = rpathMap[name] {
                    if let bundle = appBundle {
                        let fallbackLink = bundle
                            .appendingPathComponent("Frameworks", isDirectory: true)
                            .appendingPathComponent("\(dylibBase).dylib")
                        if fm.fileExists(atPath: fallbackLink.path),
                           (try? isMachoValidArch(fallbackLink)) == true {
                            return false
                        }
                    }
                    needsFix = true
                    return true
                }
            }
            return false
        }

        if !needsFix && !ctx.isFat {
            if let stamp = currentStamp(for: macho) {
                verifiedLock.lock()
                verifiedStamps[macho.path] = stamp
                verifiedLock.unlock()
            }
            return permissionsRepaired
        }

        let outcome = try replaceLibraries(&ctx.headerWindow, machoURL: macho, totalSize: Int(ctx.sliceSize))
        if outcome.rewroteBinary || ctx.isFat {
            try writePatchedHeaderAtomically(patchedHeader: ctx.headerWindow, sliceContext: ctx, to: macho)
        }

        if let stamp = currentStamp(for: macho) {
            verifiedLock.lock()
            verifiedStamps[macho.path] = stamp
            verifiedLock.unlock()
        }
        return outcome.rewroteBinary || outcome.createdSymlink || ctx.isFat || permissionsRepaired
    }

    @discardableResult
    public static func injectLoadCommand(at macho: URL, cmdType: UInt32, dylibPath: String) throws -> Bool {
        var ctx = try inspectArm64Slice(at: macho)
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = try ctx.headerWindow.extract(mach_header_64.self)
        let shouldSwap = (header.magic == MH_CIGAM_64)
        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
        }

        var alreadyExists = false
        let commandsEnd = try iterateLoadCommands(binary: ctx.headerWindow) { offset, swapCmd in
            let lc = try ctx.headerWindow.extract(load_command.self,
                                              offset: offset,
                                              swap: swapCmd ? swap_load_command : nil)
            if [
                UInt32(LC_REEXPORT_DYLIB),
                UInt32(LC_LOAD_UPWARD_DYLIB),
                UInt32(LC_LOAD_WEAK_DYLIB),
                UInt32(LC_LOAD_DYLIB)
            ].contains(lc.cmd) {
                guard Int(lc.cmdsize) >= MemoryLayout<dylib_command>.size else {
                    throw PlayCoverError.appCorrupted
                }
                let dylibCmd = try ctx.headerWindow.extract(dylib_command.self,
                                                        offset: offset,
                                                        swap: swapCmd ? swap_dylib_command : nil)
                let curPath = String(data: ctx.headerWindow,
                                     offset: offset,
                                     commandSize: Int(dylibCmd.cmdsize),
                                     loadCommandString: dylibCmd.dylib.name)
                if curPath == dylibPath {
                    alreadyExists = true
                    return true
                }
            }
            return false
        }

        if alreadyExists {
            if ctx.isFat {
                try writePatchedHeaderAtomically(patchedHeader: ctx.headerWindow, sliceContext: ctx, to: macho)
            }
            return false
        }

        let fixedSize = MemoryLayout<dylib_command>.size
        guard let strData = dylibPath.data(using: .utf8) else {
            throw PlayCoverError.appCorrupted
        }
        let rawLen = fixedSize + strData.count
        let padding = 8 - (rawLen % 8)
        let cmdSize = rawLen + padding
        let injectionEnd = commandsEnd + cmdSize

        let maxAllowedEnd = try earliestContentOffset(in: ctx.headerWindow, totalSize: Int(ctx.sliceSize))
        guard injectionEnd <= maxAllowedEnd,
              injectionEnd <= ctx.headerWindow.count else {
            throw MachoCapacityError.insufficientLoadCommandSpace(
                needed: cmdSize,
                available: max(0, maxAllowedEnd - commandsEnd)
            )
        }
        guard ctx.headerWindow[commandsEnd..<injectionEnd].allSatisfy({ $0 == 0 }) else {
            throw MachoCapacityError.insufficientLoadCommandSpace(needed: cmdSize, available: 0)
        }

        let dylibInfo = dylib(
            name: lc_str(offset: UInt32(fixedSize)),
            timestamp: 2,
            current_version: 0,
            compatibility_version: 0
        )
        var command = dylib_command(cmd: cmdType, cmdsize: UInt32(cmdSize), dylib: dylibInfo)
        if shouldSwap {
            swap_dylib_command(&command, NX_BigEndian)
        }
        var cmdData = Data(bytes: &command, count: fixedSize)
        cmdData.append(strData)
        cmdData.append(Data(count: padding))

        ctx.headerWindow.replaceSubrange(commandsEnd..<injectionEnd, with: cmdData)

        header.ncmds += 1
        header.sizeofcmds += UInt32(cmdSize)
        if shouldSwap {
            swap_mach_header_64(&header, NX_BigEndian)
        }
        let headerData = Data(bytes: &header, count: headerSize)
        ctx.headerWindow.replaceSubrange(0..<headerSize, with: headerData)

        try writePatchedHeaderAtomically(patchedHeader: ctx.headerWindow, sliceContext: ctx, to: macho)
        return true
    }

    @discardableResult
    public static func removeLoadCommand(at macho: URL, dylibPaths: [String]) throws -> Bool {
        var ctx = try inspectArm64Slice(at: macho)
        let headerSize = MemoryLayout<mach_header_64>.size
        let targetSet = Set(dylibPaths)
        var removedAny = false

        while true {
            var header = try ctx.headerWindow.extract(mach_header_64.self)
            let shouldSwap = (header.magic == MH_CIGAM_64)
            if shouldSwap {
                swap_mach_header_64(&header, NXHostByteOrder())
            }

            var matchStart: Int?
            var matchSize: Int = 0
            _ = try iterateLoadCommands(binary: ctx.headerWindow) { offset, swapCmd in
                let lc = try ctx.headerWindow.extract(load_command.self,
                                                  offset: offset,
                                                  swap: swapCmd ? swap_load_command : nil)
                if [
                    UInt32(LC_REEXPORT_DYLIB),
                    UInt32(LC_LOAD_UPWARD_DYLIB),
                    UInt32(LC_LOAD_WEAK_DYLIB),
                    UInt32(LC_LOAD_DYLIB)
                ].contains(lc.cmd) {
                    guard Int(lc.cmdsize) >= MemoryLayout<dylib_command>.size else {
                        throw PlayCoverError.appCorrupted
                    }
                    let dylibCmd = try ctx.headerWindow.extract(dylib_command.self,
                                                            offset: offset,
                                                            swap: swapCmd ? swap_dylib_command : nil)
                    let curPath = String(data: ctx.headerWindow,
                                         offset: offset,
                                         commandSize: Int(dylibCmd.cmdsize),
                                         loadCommandString: dylibCmd.dylib.name)
                    if targetSet.contains(curPath) {
                        matchStart = offset
                        matchSize = Int(dylibCmd.cmdsize)
                        return true
                    }
                }
                return false
            }

            guard let start = matchStart, matchSize > 0 else {
                break
            }

            let commandsEnd = headerSize + Int(header.sizeofcmds)
            let tailStart = start + matchSize
            guard commandsEnd <= ctx.headerWindow.count, tailStart <= commandsEnd else {
                throw PlayCoverError.appCorrupted
            }
            var shifted = ctx.headerWindow.subdata(in: tailStart..<commandsEnd)
            shifted.append(Data(count: matchSize))
            ctx.headerWindow.replaceSubrange(start..<commandsEnd, with: shifted)

            header.ncmds -= 1
            header.sizeofcmds -= UInt32(matchSize)
            if shouldSwap {
                swap_mach_header_64(&header, NX_BigEndian)
            }
            ctx.headerWindow.replaceSubrange(0..<headerSize, with: Data(bytes: &header, count: headerSize))
            removedAny = true
        }

        if removedAny || ctx.isFat {
            try writePatchedHeaderAtomically(patchedHeader: ctx.headerWindow, sliceContext: ctx, to: macho)
        }
        return removedAny
    }

    @discardableResult
    public static func replaceLibrary(
        _ binary: inout Data,
        _ rpath: String,
        _ lib: String,
        totalSize: Int? = nil
    ) throws -> Bool {
        if binary.startIndex != 0 {
            binary = Data(binary)
        }
        var dylibCommandType: UInt32 = 0
        var oldDylib: dylib?
        var didReplace = false

        try replaceLastCommand(&binary, satisfy: { commandData, shouldSwap in
            let loadCommand = try commandData.extract(load_command.self,
                                                  offset: commandData.startIndex,
                                                  swap: shouldSwap ? swap_load_command : nil)
            if ![LC_LOAD_WEAK_DYLIB, UInt32(LC_LOAD_DYLIB)].contains(loadCommand.cmd) ||
                Int(loadCommand.cmdsize) < MemoryLayout<dylib_command>.size {
                return false
            }
            let dylibCommand = try commandData.extract(dylib_command.self,
                                                   offset: commandData.startIndex,
                                                   swap: shouldSwap ? swap_dylib_command : nil)
            if String(data: commandData,
                      offset: commandData.startIndex,
                      commandSize: Int(dylibCommand.cmdsize),
                      loadCommandString: dylibCommand.dylib.name) != rpath {
                return false
            }
            dylibCommandType = dylibCommand.cmd
            oldDylib = dylibCommand.dylib
            return true

        }, with: { shouldSwap in
            guard var newDylib = oldDylib else {
                return nil
            }

            let dylibCommandFixedSize = MemoryLayout<dylib_command>.size
            let stringLength = lib.lengthOfBytes(using: String.Encoding.utf8)
            let padding = 8 - (stringLength % 8)
            let newDylibCommandSize = dylibCommandFixedSize + stringLength + padding

            newDylib.name = lc_str(offset: UInt32(dylibCommandFixedSize))
            var command = dylib_command(cmd: dylibCommandType,
                                        cmdsize: UInt32(newDylibCommandSize),
                                        dylib: newDylib)
            guard let stringData = lib.data(using: String.Encoding.utf8) else {
                print("Failed to replace dylib command: unrecognized character in target path")
                return nil
            }
            if shouldSwap {
                swap_dylib_command(&command, NX_BigEndian)
            }
            var commandData = Data(bytes: &command, count: dylibCommandFixedSize)
            commandData.append(stringData)
            commandData.append(Data(count: padding))
            didReplace = true
            return commandData
        }, atEnd: false, totalSize: totalSize)
        return didReplace
    }

    public static func replaceVersionCommand(_ binary: inout Data, totalSize: Int? = nil) throws {
        if binary.startIndex != 0 {
            binary = Data(binary)
        }
        var macCatalystCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_MACCATALYST),
                                                       minos: 0x000b0000,
                                                       sdk: 0x000e0000,
                                                       ntools: 0)

        try replaceLastCommand(&binary, satisfy: { data, shouldSwap in
            let loadCommand = try data.extract(load_command.self,
                                           offset: data.startIndex,
                                           swap: shouldSwap ? swap_load_command : nil)
            return [UInt32(LC_VERSION_MIN_IPHONEOS),
                    UInt32(LC_VERSION_MIN_MACOSX),
                    UInt32(LC_BUILD_VERSION)]
                .contains(loadCommand.cmd)

        }, with: { shouldSwap in
            if shouldSwap {
                swap_build_version_command(&macCatalystCommand, NX_BigEndian)
            }
            return Data(bytes: &macCatalystCommand, count: MemoryLayout<build_version_command>.size)
        }, atEnd: true, totalSize: totalSize)
    }

    public static func replaceLastCommand(_ binary: inout Data,
                                   satisfy isTargetCommand: (Data, Bool) throws -> Bool,
                                   with getNewCommandData: (Bool) -> Data?,
                                   atEnd shouldAppend: Bool,
                                   totalSize: Int? = nil) throws {
        if binary.startIndex != 0 {
            binary = Data(binary)
        }
        let headerSize = MemoryLayout<mach_header_64>.size
        guard binary.count >= headerSize else {
            throw PlayCoverError.appCorrupted
        }
        var header = try binary.extract(mach_header_64.self)
        let headerSwapped = (header.magic == MH_CIGAM_64)
        if headerSwapped {
            swap_mach_header_64(&header, NXHostByteOrder())
        }
        var shouldSwap = headerSwapped

        var oldCommandStart = headerSize
        var oldCommandSize: UInt32 = 0
        var foundTarget = false

        let movedCommandsEnd = try iterateLoadCommands(binary: binary) { offset, needSwap in
            let loadCommand = try binary.extract(load_command.self,
                                             offset: offset,
                                             swap: needSwap ? swap_load_command : nil)
            if try isTargetCommand(binary[offset ..< offset + Int(loadCommand.cmdsize)], needSwap) {
                oldCommandStart = offset
                oldCommandSize = loadCommand.cmdsize
                shouldSwap = needSwap
                foundTarget = true
            }
            return false
        }
        guard foundTarget else {
            return
        }
        if movedCommandsEnd != headerSize + Int(header.sizeofcmds) {
            print("Error while replacing load command: end of commands mismatch")
        }

        let oldCommandEnd = oldCommandStart + Int(oldCommandSize)
        guard let newCommandData = getNewCommandData(shouldSwap) else {
            return
        }
        let newCommandSize = UInt32(newCommandData.count)

        let injectionEnd = movedCommandsEnd - Int(oldCommandSize) + Int(newCommandSize)
        if injectionEnd > movedCommandsEnd {
            let maxAllowedEnd = try earliestContentOffset(in: binary, totalSize: totalSize)
            let neededGrowth = injectionEnd - movedCommandsEnd
            let availableSpace = max(0, maxAllowedEnd - movedCommandsEnd)
            if injectionEnd > maxAllowedEnd || injectionEnd > binary.count {
                throw MachoCapacityError.insufficientLoadCommandSpace(
                    needed: neededGrowth,
                    available: availableSpace
                )
            }
            if binary[movedCommandsEnd ..< injectionEnd].contains(where: { $0 != 0 }) {
                throw MachoCapacityError.insufficientLoadCommandSpace(
                    needed: neededGrowth,
                    available: 0
                )
            }
        }

        var resultingCommandsData = binary[oldCommandEnd..<movedCommandsEnd]
        if shouldAppend {
            resultingCommandsData.append(newCommandData)
        } else {
            resultingCommandsData.insert(contentsOf: newCommandData,
                                         at: resultingCommandsData.startIndex)
        }

        if injectionEnd <= movedCommandsEnd {
            binary.replaceSubrange(injectionEnd ..< movedCommandsEnd,
                                   with: Data(count: movedCommandsEnd - injectionEnd))
        }
        binary.replaceSubrange(oldCommandStart..<injectionEnd, with: resultingCommandsData)

        header.sizeofcmds -= oldCommandSize
        header.sizeofcmds += newCommandSize
        if headerSwapped {
            swap_mach_header_64(&header, NX_BigEndian)
        }
        let newHeaderData = Data(bytes: &header, count: headerSize)
        binary.replaceSubrange(0..<headerSize, with: newHeaderData)
    }

    private static func minimumCommandStructSize(for cmd: UInt32) -> Int {
        switch cmd {
        case UInt32(LC_LOAD_DYLIB),
             LC_LOAD_WEAK_DYLIB,
             UInt32(LC_REEXPORT_DYLIB),
             UInt32(LC_LOAD_UPWARD_DYLIB),
             UInt32(LC_ID_DYLIB):
            return MemoryLayout<dylib_command>.size
        case UInt32(LC_BUILD_VERSION):
            return MemoryLayout<build_version_command>.size
        case UInt32(LC_ENCRYPTION_INFO_64):
            return MemoryLayout<encryption_info_command_64>.size
        case UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_MACOSX):
            return MemoryLayout<version_min_command>.size
        case UInt32(LC_RPATH):
            return MemoryLayout<rpath_command>.size
        case UInt32(LC_SEGMENT_64):
            return MemoryLayout<segment_command_64>.size
        default:
            return MemoryLayout<load_command>.size
        }
    }

    public static func iterateLoadCommands(binary: Data, _ evaluate: (Int, Bool) throws -> Bool) throws -> Int {
        let binary = binary.startIndex == 0 ? binary : Data(binary)
        let headerSize = MemoryLayout<mach_header_64>.size
        guard binary.count >= headerSize else {
            throw PlayCoverError.appCorrupted
        }
        var header = try binary.extract(mach_header_64.self)
        guard header.magic == MH_MAGIC_64 || header.magic == MH_CIGAM_64 else {
            throw PlayCoverError.appCorrupted
        }
        var offset = headerSize
        let shouldSwap = header.magic == MH_CIGAM_64
        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
        }

        let allCommandsEnd = headerSize + Int(header.sizeofcmds)
        if allCommandsEnd > binary.count || allCommandsEnd <= headerSize {
            print("Cannot iterate load commands: Mach-O file is corrupted(-1)")
            throw PlayCoverError.appCorrupted
        }
        var terminatedEarly = false
        for index in 0..<header.ncmds {
            guard offset + MemoryLayout<load_command>.size <= allCommandsEnd else {
                throw PlayCoverError.appCorrupted
            }
            let loadCommand = try binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            let cmdSize = Int(loadCommand.cmdsize)
            let commandEnd = offset + cmdSize
            if cmdSize < MemoryLayout<load_command>.size ||
                cmdSize < minimumCommandStructSize(for: loadCommand.cmd) ||
                commandEnd > allCommandsEnd ||
                commandEnd <= offset {
                print("Cannot iterate load commands: Mach-O file is corrupted(\(index))")
                throw PlayCoverError.appCorrupted
            }
            let terminated = try evaluate(offset, shouldSwap)
            offset = commandEnd
            if terminated {
                terminatedEarly = true
                break
            }
        }
        if !terminatedEarly && offset != allCommandsEnd {
            throw PlayCoverError.appCorrupted
        }
        return offset
    }

    public static func isMachoEncrypted(atURL url: URL) throws -> Bool {
        let binary = try readHeaderSlice(at: url)
        var result = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = try binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            if loadCommand.cmd == UInt32(LC_ENCRYPTION_INFO_64) {
                guard Int(loadCommand.cmdsize) >= MemoryLayout<encryption_info_command_64>.size else {
                    throw PlayCoverError.appCorrupted
                }
                let infoCommand = try binary.extract(encryption_info_command_64.self,
                                                 offset: offset,
                                                 swap: shouldSwap ? swap_encryption_command_64 : nil)
                result = infoCommand.cryptid != 0
                return true
            }
            return false
        }
        return result
    }

    public static func isMachoValidArch(_ url: URL) throws -> Bool {
        let binary = try readHeaderSlice(at: url)
        var result = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = try binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            if loadCommand.cmd == UInt32(LC_BUILD_VERSION) {
                guard Int(loadCommand.cmdsize) >= MemoryLayout<build_version_command>.size else {
                    throw PlayCoverError.appCorrupted
                }
                let versionCommand = try binary.extract(build_version_command.self,
                                                    offset: offset,
                                                    swap: shouldSwap ? swap_build_version_command : nil)
                result = versionCommand.platform == PLATFORM_MACCATALYST
                return true
            }
            return false
        }
        return result
    }

    public static func inspectBinary(
        atURL macho: URL,
        playToolsPath: String
    ) throws -> (hasPlayTools: Bool, isCatalyst: Bool) {
        let binary = try readHeaderSlice(at: macho)
        var hasPlayTools = false
        var isCatalyst = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = try binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            if loadCommand.cmd == UInt32(LC_LOAD_DYLIB) {
                guard Int(loadCommand.cmdsize) >= MemoryLayout<dylib_command>.size else {
                    throw PlayCoverError.appCorrupted
                }
                let dylibCommand = try binary.extract(dylib_command.self,
                                                  offset: offset,
                                                  swap: shouldSwap ? swap_dylib_command : nil)
                let dylibName = String(data: binary,
                                       offset: offset,
                                       commandSize: Int(dylibCommand.cmdsize),
                                       loadCommandString: dylibCommand.dylib.name)
                if dylibName == playToolsPath {
                    hasPlayTools = true
                }
            } else if loadCommand.cmd == UInt32(LC_BUILD_VERSION) {
                guard Int(loadCommand.cmdsize) >= MemoryLayout<build_version_command>.size else {
                    throw PlayCoverError.appCorrupted
                }
                let versionCommand = try binary.extract(build_version_command.self,
                                                    offset: offset,
                                                    swap: shouldSwap ? swap_build_version_command : nil)
                isCatalyst = versionCommand.platform == PLATFORM_MACCATALYST
            }
            return false
        }
        return (hasPlayTools, isCatalyst)
    }
}
