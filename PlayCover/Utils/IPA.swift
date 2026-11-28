//
//  IPA.swift
//  PlayCover
//

import AppKit
import Compression
import Darwin
import Foundation

nonisolated enum SafeIPAExtractor {
    static let maxEntryCount = 200_000
    static let maxCentralDirectoryBytes: UInt64 = 256 * 1024 * 1024
    static let maxSingleFileBytes: UInt64 = 16 * 1024 * 1024 * 1024
    static let maxTotalUncompressedBytes: UInt64 = 32 * 1024 * 1024 * 1024
    static let maxEntryPathLength = 4096
    private static let streamChunkSize = 65_536

    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let generalPurposeFlag: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let versionMadeBy: UInt16
        let externalAttributes: UInt32
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { idx in
            var c = UInt32(idx)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func updateCRC32(_ crc: UInt32, bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var acc = crc
        for byte in bytes {
            let idx = Int((acc ^ UInt32(byte)) & 0xFF)
            acc = crc32Table[idx] ^ (acc >> 8)
        }
        return acc
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw PlayCoverError.appCorrupted
        }
        return sum
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw PlayCoverError.appCorrupted
        }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw PlayCoverError.appCorrupted
        }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) throws -> UInt64 {
        let lo = UInt64(try readUInt32LE(data, at: offset))
        let hi = UInt64(try readUInt32LE(data, at: offset + 4))
        return lo | (hi << 32)
    }

    private static func readExact(
        from handle: FileHandle,
        atOffset offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count >= 0 else {
            throw PlayCoverError.appCorrupted
        }
        if count == 0 {
            return Data()
        }
        try handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(min(count, 1_048_576))
        while result.count < count {
            let remaining = count - result.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw PlayCoverError.appCorrupted
            }
            result.append(chunk)
        }
        return result
    }

    private static func sanitizedRelativeComponents(for rawName: String) throws -> (components: [String], isDir: Bool) {
        guard !rawName.isEmpty,
              rawName.utf8.count <= maxEntryPathLength,
              !rawName.contains("\0"),
              !rawName.contains("\\"),
              !rawName.hasPrefix("/") else {
            throw PlayCoverError.appCorrupted
        }
        let isDir = rawName.hasSuffix("/")
        let trimmed = isDir ? String(rawName.dropLast()) : rawName
        if trimmed.isEmpty {
            return ([], true)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                throw PlayCoverError.appCorrupted
            }
        }
        return (parts, isDir)
    }

    private static func validateNoSymlinksAndEnsureDirectory(
        rootURL: URL,
        relativeComponents: [String]
    ) throws -> URL {
        let fm = FileManager.default
        var current = rootURL
        var rootStat = Darwin.stat()
        guard Darwin.lstat(rootURL.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw PlayCoverError.appCorrupted
        }
        for component in relativeComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            var st = Darwin.stat()
            if Darwin.lstat(current.path, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFDIR else {
                    throw PlayCoverError.appCorrupted
                }
            } else if errno == ENOENT {
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            } else {
                throw PlayCoverError.appCorrupted
            }
        }
        return current
    }

    private static func parseCentralDirectory(
        handle: FileHandle,
        fileSize: UInt64
    ) throws -> [Entry] {
        guard fileSize >= 22 else {
            throw PlayCoverError.appCorrupted
        }
        let tailWindow = Int(min(fileSize, UInt64(65_557)))
        let tailStart = fileSize - UInt64(tailWindow)
        let tail = try readExact(from: handle, atOffset: tailStart, count: tailWindow)

        var eocdLocalOffset: Int?
        var cursor = tail.count - 22
        while cursor >= 0 {
            if try readUInt32LE(tail, at: cursor) == 0x06054b50 {
                let commentLen = Int(try readUInt16LE(tail, at: cursor + 20))
                if cursor + 22 + commentLen == tail.count {
                    eocdLocalOffset = cursor
                    break
                }
            }
            cursor -= 1
        }
        guard let eocdIdx = eocdLocalOffset else {
            throw PlayCoverError.appCorrupted
        }
        let eocdAbsOffset = try checkedAdd(tailStart, UInt64(eocdIdx))
        var entryCount = UInt64(try readUInt16LE(tail, at: eocdIdx + 10))
        var cdSize = UInt64(try readUInt32LE(tail, at: eocdIdx + 12))
        var cdOffset = UInt64(try readUInt32LE(tail, at: eocdIdx + 16))

        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocdAbsOffset >= 20 else {
                throw PlayCoverError.appCorrupted
            }
            let locator = try readExact(from: handle, atOffset: eocdAbsOffset - 20, count: 20)
            guard try readUInt32LE(locator, at: 0) == 0x07064b50 else {
                throw PlayCoverError.appCorrupted
            }
            let z64Offset = try readUInt64LE(locator, at: 8)
            let z64End = try checkedAdd(z64Offset, 56)
            guard z64End <= fileSize else {
                throw PlayCoverError.appCorrupted
            }
            let z64 = try readExact(from: handle, atOffset: z64Offset, count: 56)
            guard try readUInt32LE(z64, at: 0) == 0x06064b50 else {
                throw PlayCoverError.appCorrupted
            }
            entryCount = try readUInt64LE(z64, at: 32)
            cdSize = try readUInt64LE(z64, at: 40)
            cdOffset = try readUInt64LE(z64, at: 48)
        }

        guard entryCount <= UInt64(maxEntryCount),
              cdSize <= maxCentralDirectoryBytes else {
            throw PlayCoverError.appCorrupted
        }
        let cdEnd = try checkedAdd(cdOffset, cdSize)
        guard cdEnd <= fileSize else {
            throw PlayCoverError.appCorrupted
        }
        let cdData = try readExact(from: handle, atOffset: cdOffset, count: Int(cdSize))

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(entryCount, 4096)))
        var offset = 0
        while offset < cdData.count {
            guard entries.count < maxEntryCount else {
                throw PlayCoverError.appCorrupted
            }
            guard offset + 46 <= cdData.count,
                  try readUInt32LE(cdData, at: offset) == 0x02014b50 else {
                throw PlayCoverError.appCorrupted
            }
            let versionMadeBy = try readUInt16LE(cdData, at: offset + 4)
            let gpFlag = try readUInt16LE(cdData, at: offset + 8)
            let method = try readUInt16LE(cdData, at: offset + 10)
            let crc32 = try readUInt32LE(cdData, at: offset + 16)
            var compSize = UInt64(try readUInt32LE(cdData, at: offset + 20))
            var uncompSize = UInt64(try readUInt32LE(cdData, at: offset + 24))
            let nameLen = Int(try readUInt16LE(cdData, at: offset + 28))
            let extraLen = Int(try readUInt16LE(cdData, at: offset + 30))
            let commentLen = Int(try readUInt16LE(cdData, at: offset + 32))
            let extAttrs = try readUInt32LE(cdData, at: offset + 38)
            var localOffset = UInt64(try readUInt32LE(cdData, at: offset + 42))

            let nameStart = offset + 46
            let extraStart = nameStart + nameLen
            let nextOffset = extraStart + extraLen + commentLen
            guard nextOffset <= cdData.count else {
                throw PlayCoverError.appCorrupted
            }
            let nameSlice = cdData.subdata(in: nameStart..<extraStart)
            guard let name = String(data: nameSlice, encoding: .utf8)
                    ?? String(data: nameSlice, encoding: .isoLatin1) else {
                throw PlayCoverError.appCorrupted
            }

            if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var extraCursor = extraStart
                let extraEnd = extraStart + extraLen
                while extraCursor + 4 <= extraEnd {
                    let headerID = try readUInt16LE(cdData, at: extraCursor)
                    let fieldLen = Int(try readUInt16LE(cdData, at: extraCursor + 2))
                    let fieldStart = extraCursor + 4
                    let fieldEnd = fieldStart + fieldLen
                    guard fieldEnd <= extraEnd else {
                        throw PlayCoverError.appCorrupted
                    }
                    if headerID == 0x0001 {
                        var zCursor = fieldStart
                        if uncompSize == 0xFFFF_FFFF {
                            guard zCursor + 8 <= fieldEnd else { throw PlayCoverError.appCorrupted }
                            uncompSize = try readUInt64LE(cdData, at: zCursor)
                            zCursor += 8
                        }
                        if compSize == 0xFFFF_FFFF {
                            guard zCursor + 8 <= fieldEnd else { throw PlayCoverError.appCorrupted }
                            compSize = try readUInt64LE(cdData, at: zCursor)
                            zCursor += 8
                        }
                        if localOffset == 0xFFFF_FFFF {
                            guard zCursor + 8 <= fieldEnd else { throw PlayCoverError.appCorrupted }
                            localOffset = try readUInt64LE(cdData, at: zCursor)
                        }
                        break
                    }
                    extraCursor = fieldEnd
                }
            }

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                generalPurposeFlag: gpFlag,
                crc32: crc32,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset,
                versionMadeBy: versionMadeBy,
                externalAttributes: extAttrs
            ))
            offset = nextOffset
        }

        return entries
    }

    private static func writeAll(_ bytes: UnsafePointer<UInt8>, count: Int, to fd: Int32) throws {
        var written = 0
        while written < count {
            let rc = Darwin.write(fd, bytes.advanced(by: written), count - written)
            if rc < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if rc == 0 {
                throw PlayCoverError.appCorrupted
            }
            written += rc
        }
    }

    private static func streamStored(
        handle: FileHandle,
        entry: Entry,
        outFD: Int32,
        totalExtracted: inout UInt64
    ) throws -> UInt32 {
        guard entry.compressedSize == entry.uncompressedSize else {
            throw PlayCoverError.appCorrupted
        }
        var remaining = entry.compressedSize
        var crc: UInt32 = 0xFFFF_FFFF
        while remaining > 0 {
            let toRead = Int(min(remaining, UInt64(streamChunkSize)))
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                throw PlayCoverError.appCorrupted
            }
            let chunkCount = UInt64(chunk.count)
            totalExtracted = try checkedAdd(totalExtracted, chunkCount)
            guard totalExtracted <= maxTotalUncompressedBytes else {
                throw PlayCoverError.appCorrupted
            }
            try chunk.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
                let typed = UnsafeBufferPointer(start: base, count: rawBuf.count)
                crc = updateCRC32(crc, bytes: typed)
                try writeAll(base, count: rawBuf.count, to: outFD)
            }
            remaining -= chunkCount
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func streamDeflate(
        handle: FileHandle,
        entry: Entry,
        outFD: Int32,
        totalExtracted: inout UInt64
    ) throws -> UInt32 {
        let sentinel = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { sentinel.deallocate() }
        var stream = compression_stream(
            dst_ptr: sentinel,
            dst_size: 0,
            src_ptr: UnsafePointer(sentinel),
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw PlayCoverError.appCorrupted
        }
        defer { compression_stream_destroy(&stream) }

        var dstBuffer = [UInt8](repeating: 0, count: streamChunkSize)
        var remainingInput = entry.compressedSize
        var entryWritten: UInt64 = 0
        var crc: UInt32 = 0xFFFF_FFFF
        var currentChunk = Data()
        var chunkOffset = 0
        var finished = false

        while !finished {
            if chunkOffset >= currentChunk.count && remainingInput > 0 {
                let toRead = Int(min(remainingInput, UInt64(streamChunkSize)))
                guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                    throw PlayCoverError.appCorrupted
                }
                currentChunk = chunk
                chunkOffset = 0
                remainingInput -= UInt64(chunk.count)
            }

            let isFinalInput = (remainingInput == 0 && chunkOffset >= currentChunk.count)
            let flags = isFinalInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let availSrc = max(0, currentChunk.count - chunkOffset)

            let produced: Int = try currentChunk.withUnsafeBytes { srcRaw in
                try dstBuffer.withUnsafeMutableBytes { dstRaw in
                    let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress
                    guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                        throw PlayCoverError.appCorrupted
                    }
                    if let srcBase, availSrc > 0 {
                        stream.src_ptr = srcBase.advanced(by: chunkOffset)
                        stream.src_size = availSrc
                    } else {
                        stream.src_ptr = UnsafePointer(sentinel)
                        stream.src_size = 0
                    }
                    stream.dst_ptr = dstBase
                    stream.dst_size = streamChunkSize

                    let status = compression_stream_process(&stream, flags)
                    let consumed = availSrc - stream.src_size
                    chunkOffset += consumed
                    let outCount = streamChunkSize - stream.dst_size

                    switch status {
                    case COMPRESSION_STATUS_OK:
                        if outCount == 0 && consumed == 0 && isFinalInput {
                            throw PlayCoverError.appCorrupted
                        }
                    case COMPRESSION_STATUS_END:
                        finished = true
                    default:
                        throw PlayCoverError.appCorrupted
                    }
                    return outCount
                }
            }

            if produced > 0 {
                let producedU64 = UInt64(produced)
                entryWritten = try checkedAdd(entryWritten, producedU64)
                guard entryWritten <= entry.uncompressedSize,
                      entryWritten <= maxSingleFileBytes else {
                    throw PlayCoverError.appCorrupted
                }
                totalExtracted = try checkedAdd(totalExtracted, producedU64)
                guard totalExtracted <= maxTotalUncompressedBytes else {
                    throw PlayCoverError.appCorrupted
                }
                try dstBuffer.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    let slice = UnsafeBufferPointer(start: base, count: produced)
                    crc = updateCRC32(crc, bytes: slice)
                    try writeAll(base, count: produced, to: outFD)
                }
            }
        }

        guard entryWritten == entry.uncompressedSize else {
            throw PlayCoverError.appCorrupted
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func extract(archiveURL: URL, to destinationDir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDir.path) {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }
        let attrs = try fm.attributesOfItem(atPath: archiveURL.path)
        guard let fileSizeNumber = attrs[.size] as? NSNumber else {
            throw PlayCoverError.appCorrupted
        }
        let fileSize = fileSizeNumber.uint64Value
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let entries = try parseCentralDirectory(handle: handle, fileSize: fileSize)
        let canonicalRoot = destinationDir.resolvingSymlinksInPath().standardizedFileURL
        var totalExtracted: UInt64 = 0

        for entry in entries {
            // Reject encrypted entries
            guard (entry.generalPurposeFlag & 0x0001) == 0 else {
                throw PlayCoverError.appCorrupted
            }
            guard entry.uncompressedSize <= maxSingleFileBytes else {
                throw PlayCoverError.appCorrupted
            }
            let (components, isDirByName) = try sanitizedRelativeComponents(for: entry.name)
            if components.isEmpty {
                continue
            }

            // Reject symlinks and special Unix file types (FIFO, char/block devices, sockets)
            // Treat both UNIX (3) and OSX/Darwin (19) host creators as carrying POSIX mode bits.
            let hostOS = entry.versionMadeBy >> 8
            let isUnixHost = (hostOS == 3 || hostOS == 19)
            let unixMode = isUnixHost ? UInt16((entry.externalAttributes >> 16) & 0xFFFF) : 0
            let fileType = unixMode & 0o170000
            if fileType == 0o120000
                || fileType == 0o010000
                || fileType == 0o020000
                || fileType == 0o060000
                || fileType == 0o140000 {
                throw PlayCoverError.appCorrupted
            }

            let isDirectory = isDirByName || (fileType == 0o040000)
            if isDirectory {
                _ = try validateNoSymlinksAndEnsureDirectory(
                    rootURL: canonicalRoot,
                    relativeComponents: components
                )
                continue
            }

            let parentComponents = Array(components.dropLast())
            let fileName = components[components.count - 1]
            let parentDir = try validateNoSymlinksAndEnsureDirectory(
                rootURL: canonicalRoot,
                relativeComponents: parentComponents
            )
            let targetURL = parentDir.appendingPathComponent(fileName, isDirectory: false)
            guard targetURL.standardizedFileURL.path.hasPrefix(canonicalRoot.path + "/") else {
                throw PlayCoverError.appCorrupted
            }

            let localHeaderEnd = try checkedAdd(entry.localHeaderOffset, 30)
            guard localHeaderEnd <= fileSize else {
                throw PlayCoverError.appCorrupted
            }
            let localHeader = try readExact(from: handle, atOffset: entry.localHeaderOffset, count: 30)
            guard try readUInt32LE(localHeader, at: 0) == 0x04034b50 else {
                throw PlayCoverError.appCorrupted
            }
            let localNameLen = UInt64(try readUInt16LE(localHeader, at: 26))
            let localExtraLen = UInt64(try readUInt16LE(localHeader, at: 28))
            let dataStart = try checkedAdd(try checkedAdd(localHeaderEnd, localNameLen), localExtraLen)
            let dataEnd = try checkedAdd(dataStart, entry.compressedSize)
            guard dataEnd <= fileSize else {
                throw PlayCoverError.appCorrupted
            }

            var existingStat = Darwin.stat()
            if Darwin.lstat(targetURL.path, &existingStat) == 0,
               (existingStat.st_mode & S_IFMT) != S_IFREG {
                throw PlayCoverError.appCorrupted
            }

            var mode: mode_t = 0o644
            if isUnixHost && (unixMode & 0o111) != 0 {
                mode = 0o755
            }

            let outFD = Darwin.open(
                targetURL.path,
                O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
            guard outFD >= 0 else {
                throw PlayCoverError.appCorrupted
            }
            var extractionSucceeded = false
            defer {
                _ = Darwin.close(outFD)
                if !extractionSucceeded {
                    try? fm.removeItem(at: targetURL)
                }
            }

            var outStat = Darwin.stat()
            guard Darwin.fstat(outFD, &outStat) == 0,
                  (outStat.st_mode & S_IFMT) == S_IFREG else {
                throw PlayCoverError.appCorrupted
            }

            try handle.seek(toOffset: dataStart)
            let computedCRC: UInt32
            switch entry.compressionMethod {
            case 0:
                computedCRC = try streamStored(
                    handle: handle,
                    entry: entry,
                    outFD: outFD,
                    totalExtracted: &totalExtracted
                )
            case 8:
                computedCRC = try streamDeflate(
                    handle: handle,
                    entry: entry,
                    outFD: outFD,
                    totalExtracted: &totalExtracted
                )
            default:
                throw PlayCoverError.appCorrupted
            }

            guard computedCRC == entry.crc32 else {
                throw PlayCoverError.appCorrupted
            }
            _ = Darwin.fchmod(outFD, mode)
            extractionSucceeded = true
        }
    }
}

nonisolated public class IPA {
    public let url: URL
    public private(set) var tmpDir: URL?

    public init(url: URL) {
        self.url = url
    }

    public func allocateTempDir(appropriateFor targetURL: URL? = nil) throws {
        releaseTempDir()
        let preferred = targetURL ?? AppsVM.appDirectory
        let baseURL: URL
        if FileManager.default.fileExists(atPath: preferred.path) {
            baseURL = preferred
        } else {
            baseURL = FileManager.default.temporaryDirectory
        }
        tmpDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: baseURL,
                                             create: true)
    }

    public func releaseTempDir() {
        guard let workDir = tmpDir else {
            return
        }

        FileManager.default.delete(at: workDir)

        tmpDir = nil
    }

    public func removeQuarantine(_ execUrl: URL) throws {
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", execUrl.path)
    }

    public func unzip() throws -> BaseApp {
        guard let workDir = tmpDir else {
            throw PlayCoverError.appCorrupted
        }
        try SafeIPAExtractor.extract(archiveURL: url, to: workDir)
        return try Installer.fromIPA(detectingAppNameInFolder: workDir.appendingPathComponent("Payload"))
    }

    func packIPABack(app: URL) throws -> URL {
        let payload = app.deletingLastPathComponent()
        let workDir = payload.deletingLastPathComponent()
        let name = app.deletingPathExtension().lastPathComponent

        let newIpa = getDocumentsDirectory()
            .appendingEscapedPathComponent(name)
            .appendingPathExtension("ipa")

        if FileManager.default.fileExists(atPath: newIpa.path) {
            try FileManager.default.removeItem(at: newIpa)
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-r", "-y", newIpa.path, payload.lastPathComponent]
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: newIpa)
            throw PlayCoverError.shellExecutionFailed(
                binary: "/usr/bin/zip",
                status: process.terminationStatus,
                output: String(data: output, encoding: .utf8) ?? "Failed to pack IPA"
            )
        }

        return newIpa
    }

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

    enum Application {
        case base(BaseApp)
        case store(SourceAppsData)
    }

    static func htmlIndicatesMacOSCompatibility(_ htmlString: String) -> Bool {
        let className = "information-list__item__definition__item__definition"
        let tagPattern = #"<([A-Za-z][A-Za-z0-9]*)\b[^>]*\bclass\s*=\s*"# +
            #"(?:"[^"]*\b\#(className)\b[^"]*"|'[^']*\b\#(className)\b[^']*')[^>]*>"#
        guard let definitionTagPattern = try? Regex(tagPattern).ignoresCase() else {
            return false
        }
        for match in htmlString.matches(of: definitionTagPattern) {
            guard let tagSub = match.output[1].substring else { continue }
            let tagName = String(tagSub)
            let contentStart = match.range.upperBound
            var depth = 1
            var cursor = contentStart
            let tail = htmlString[contentStart...]
            while cursor < htmlString.endIndex, depth > 0 {
                guard let lt = tail[cursor...].firstIndex(of: "<") else {
                    break
                }
                let afterLT = htmlString[lt...]
                if afterLT.starts(with: "</") {
                    if let closeMatch = afterLT.prefixMatch(of: /<\/([A-Za-z][A-Za-z0-9]*)\s*>/),
                       closeMatch.output.1.caseInsensitiveCompare(tagName) == .orderedSame {
                        depth -= 1
                        if depth == 0 {
                            let inner = String(htmlString[contentStart..<lt])
                            let plainText = inner
                                .replacing(/<[^>]+>/, with: " ")
                                .replacingOccurrences(of: "&amp;", with: "&")
                                .replacingOccurrences(of: "&nbsp;", with: " ")
                            if plainText.contains("macOS") {
                                return true
                            }
                            break
                        }
                        cursor = closeMatch.range.upperBound
                        continue
                    }
                } else if !afterLT.starts(with: "<!"),
                          let openMatch = afterLT.prefixMatch(of: /<([A-Za-z][A-Za-z0-9]*)\b[^>]*>/),
                          !afterLT[..<openMatch.range.upperBound].hasSuffix("/>"),
                          openMatch.output.1.caseInsensitiveCompare(tagName) == .orderedSame {
                    depth += 1
                    cursor = openMatch.range.upperBound
                    continue
                }
                cursor = htmlString.index(after: lt)
            }
        }
        return false
    }

    private static func checkMacOSCompatibility(appID: Int) async -> Bool {
        let urlString = "https://apps.apple.com/us/app/id\(appID)"
        guard let url = URL(string: urlString) else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }

            guard let htmlString = String(data: data, encoding: .utf8) else {
                return false
            }
            return htmlIndicatesMacOSCompatibility(htmlString)
        } catch {
            return false
        }
    }

    @MainActor
    func checkOfficialMacOS(
        app: Application,
        alertPresenter: AlertPresenter? = nil,
        installPreferences: InstallPreferences? = nil
    ) async -> Bool {
        let prefs = installPreferences ?? InstallPreferences()
        guard prefs.showAppStorePopup else {
            return false
        }
        let bundleID: String
        let appID: Int
        switch app {
        case .base(let base):
            bundleID = base.info.bundleIdentifier
            guard Shell.isValidBundleIdentifier(bundleID) else {
                return false
            }
            var components = URLComponents(string: "https://itunes.apple.com/lookup")
            components?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
            guard let urlString = components?.url?.absoluteString else {
                return false
            }
            let itunes: ITunesResponse? = await getITunesData(urlString)
            appID = itunes?.results.first?.trackId ?? 0
        case .store(let store):
            bundleID = store.bundleID
            let appLookup = store.itunesLookup
            let stringArray = appLookup.components(separatedBy: CharacterSet.decimalDigits.inverted)
            appID = Int(stringArray.last ?? "0") ?? 0
        }
        let supportMacOS: Bool = await Self.checkMacOSCompatibility(appID: appID)
        if supportMacOS {
            let presenter = alertPresenter ?? AlertPresenter()
            let response = await presenter.present(
                PlayCoverAlertRequest(
                    title: NSLocalizedString("alert.appstore", comment: ""),
                    message: String(format: NSLocalizedString("macos.version", comment: "")),
                    style: .informational,
                    buttons: [
                        PlayCoverAlertButton(title: NSLocalizedString("alert.install.anyway", comment: "")),
                        PlayCoverAlertButton(title: NSLocalizedString("alert.open.appstore", comment: "")),
                        PlayCoverAlertButton(title: NSLocalizedString("button.Cancel", comment: ""), isCancel: true)
                    ],
                    suppressionTitle: NSLocalizedString("alert.supression", comment: "String"),
                    defaultCancelIndex: 2
                )
            )
            switch response.buttonIndex {
            case 0:
                if response.suppressionChecked {
                    prefs.showAppStorePopup = false
                }
                return false
            case 1:
                if appID != 0 {
                    guard let urlApp = URL(string: "itms-apps://apps.apple.com/app/id\(appID)") else {
                        return true
                    }
                    _ = NSWorkspace.shared.open(urlApp)
                }
                return true
            default:
                return true
            }
        }
        return false
    }
}
